package com.tokenburners.nova

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.File
import kotlin.math.sqrt

/**
 * The one process Android is not allowed to kill while Nova is armed. It owns
 * the single mic stream: every frame is fed to a [WakeWordDetector], and on a
 * hit (or a `simulateWake` request) it captures the following utterance to a
 * 16 kHz mono WAV and emits its path up the events channel for STT.
 *
 * The mandatory foreground notification doubles as one of the two status-icon
 * render targets (the other is [OverlayService]'s floating dot).
 */
class WakeWordForegroundService : Service() {

    companion object {
        private const val TAG = "NovaWakeWord"
        private const val CHANNEL_ID = "nova_status"
        private const val NOTIFICATION_ID = 1001

        /** When true, the service runs its own mic capture + wake-word loop.
         *  Off while Dart's SpeechRecognizer owns the mic. */
        private const val NATIVE_CAPTURE = false

        // Capture format — matches whisper.cpp's expected input.
        private const val SAMPLE_RATE = 16_000
        private const val FRAME_SAMPLES = 1_600            // 100 ms
        private const val UTTERANCE_MAX_MS = 6_000
        private const val TRAILING_SILENCE_MS = 800
        private const val SILENCE_RMS = 550.0              // rough; tune on-device

        const val ACTION_START = "com.tokenburners.nova.START_LISTENING"
        const val ACTION_STOP = "com.tokenburners.nova.STOP_LISTENING"
        const val ACTION_SET_STATUS = "com.tokenburners.nova.SET_STATUS"
        const val ACTION_SIMULATE_WAKE = "com.tokenburners.nova.SIMULATE_WAKE"
        const val ACTION_CONTROL = "com.tokenburners.nova.CONTROL"
        const val EXTRA_STATUS = "status" // "available" | "working" | "sleeping"
        const val EXTRA_CONTROL = "cmd"  // "pause" | "resume" | "test"

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, WakeWordForegroundService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, WakeWordForegroundService::class.java).setAction(ACTION_STOP)
            )
        }

        fun simulateWake(context: Context) {
            context.startService(
                Intent(context, WakeWordForegroundService::class.java).setAction(ACTION_SIMULATE_WAKE)
            )
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var status: String = "available"

    private val detector: WakeWordDetector = NoopWakeWordDetector()
    private var captureThread: Thread? = null

    @Volatile private var listening = false
    @Volatile private var captureRequested = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> NovaEventBridge.emitScreenState("off")
                Intent.ACTION_USER_PRESENT -> NovaEventBridge.emitScreenState("present")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        registerReceiver(
            screenReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
            }
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return try {
            handleCommand(intent)
        } catch (e: Exception) {
            Log.e(TAG, "onStartCommand failed", e)
            runCatching { notifyForeground() }
            START_STICKY
        }
    }

    private fun handleCommand(intent: Intent?): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopListeningInternal()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SET_STATUS -> {
                status = intent.getStringExtra(EXTRA_STATUS) ?: status
                notifyForeground()
                return START_STICKY
            }
            ACTION_SIMULATE_WAKE -> {
                captureRequested = true
                if (!isRunning) startListeningInternal()
                return START_STICKY
            }
            ACTION_CONTROL -> {
                val cmd = intent.getStringExtra(EXTRA_CONTROL) ?: return START_STICKY
                NovaEventBridge.emitControl(cmd)
                if (cmd == "pause") { status = "sleeping"; notifyForeground() }
                if (cmd == "resume") { status = "available"; notifyForeground() }
                return START_STICKY
            }
            else -> startListeningInternal()
        }
        return START_STICKY
    }

    private fun startListeningInternal() {
        notifyForeground()
        if (isRunning) return
        acquireWakeLock()
        isRunning = true
        // NATIVE_CAPTURE mode (openWakeWord + whisper on a captured WAV) is off:
        // wake word + STT currently run in Dart via SpeechRecognizer, which must
        // own the mic. Flip this on only when the native models are linked.
        if (NATIVE_CAPTURE) {
            listening = true
            captureThread = Thread(::captureLoop, "nova-mic").also { it.start() }
        }
    }

    private fun stopListeningInternal() {
        listening = false
        captureThread?.join(1_500)
        captureThread = null
        detector.release()
        isRunning = false
        releaseWakeLock()
    }

    // ── Single mic stream ──────────────────────────────────────────────────
    private fun captureLoop() {
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuf <= 0) {
            Log.e(TAG, "AudioRecord unavailable (minBuf=$minBuf)")
            return
        }

        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, FRAME_SAMPLES * 2 * 4)
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "RECORD_AUDIO not granted", e)
            return
        }

        if (record.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialise")
            record.release()
            return
        }

        record.startRecording()
        val frame = ShortArray(FRAME_SAMPLES)
        try {
            while (listening) {
                val n = record.read(frame, 0, frame.size)
                if (n <= 0) continue
                val slice = if (n == frame.size) frame else frame.copyOf(n)

                val hit = try {
                    detector.accept(slice)
                } catch (e: Throwable) {
                    Log.w(TAG, "detector threw", e); false
                }

                if (hit || captureRequested) {
                    captureRequested = false
                    detector.reset()
                    val path = captureUtterance(record)
                    NovaEventBridge.emitWakeWord(path)
                }
            }
        } finally {
            try { record.stop() } catch (_: Throwable) {}
            record.release()
        }
    }

    /** Collect frames until max length or trailing silence after some speech. */
    private fun captureUtterance(record: AudioRecord): String? {
        val samples = ArrayList<Short>(SAMPLE_RATE * UTTERANCE_MAX_MS / 1000)
        val frame = ShortArray(FRAME_SAMPLES)
        val maxFrames = UTTERANCE_MAX_MS / 100
        val silenceFramesToStop = TRAILING_SILENCE_MS / 100
        var framesRead = 0
        var silentRun = 0
        var heardSpeech = false

        while (listening && framesRead < maxFrames) {
            val n = record.read(frame, 0, frame.size)
            if (n <= 0) break
            for (i in 0 until n) samples.add(frame[i])
            framesRead++

            if (rms(frame, n) < SILENCE_RMS) {
                silentRun++
                if (heardSpeech && silentRun >= silenceFramesToStop) break
            } else {
                heardSpeech = true
                silentRun = 0
            }
        }

        if (samples.isEmpty()) return null
        return try {
            val out = File(File(filesDir, "utterances"), "${System.currentTimeMillis()}.wav")
            WavWriter.write(out, samples.toShortArray(), SAMPLE_RATE)
            Log.i(TAG, "captured ${samples.size} samples -> ${out.absolutePath}")
            out.absolutePath
        } catch (e: Throwable) {
            Log.e(TAG, "WAV write failed", e)
            null
        }
    }

    private fun rms(buf: ShortArray, len: Int): Double {
        var sum = 0.0
        for (i in 0 until len) {
            val v = buf[i].toDouble()
            sum += v * v
        }
        return sqrt(sum / len.coerceAtLeast(1))
    }

    // ── Wake lock ─────────────────────────────────────────────────────────
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nova::wakeword").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // ── Notification (status-icon render target #1) ───────────────────────
    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Nova status",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows whether Nova is available, working, or sleeping."
            setShowBadge(false)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun controlPending(cmd: String): android.app.PendingIntent {
        val intent = Intent(this, WakeWordForegroundService::class.java)
            .setAction(ACTION_CONTROL)
            .putExtra(EXTRA_CONTROL, cmd)
        val flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT or
            android.app.PendingIntent.FLAG_IMMUTABLE
        return android.app.PendingIntent.getService(this, cmd.hashCode(), intent, flags)
    }

    private fun buildNotification(): Notification {
        val (text, icon) = when (status) {
            "working" -> "Working…" to android.R.drawable.presence_away
            "sleeping" -> "Sleeping" to android.R.drawable.presence_busy
            else -> "Listening for \"Nova\"" to android.R.drawable.presence_online
        }
        val toggle = if (status == "sleeping") {
            NotificationCompat.Action(0, "Resume", controlPending("resume"))
        } else {
            NotificationCompat.Action(0, "Pause", controlPending("pause"))
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Nova")
            .setContentText(text)
            .setSmallIcon(icon)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(NotificationCompat.Action(0, "Talk", controlPending("talk")))
            .addAction(toggle)
            .addAction(NotificationCompat.Action(0, "Test", controlPending("test")))
            .build()
    }

    private fun hasMicPermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun notifyForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            runCatching { startForeground(NOTIFICATION_ID, notification) }
            return
        }
        // Only claim the microphone FGS type once RECORD_AUDIO is actually
        // granted — otherwise startForeground throws and crashes the app.
        val type = if (hasMicPermission()) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        }
        try {
            startForeground(NOTIFICATION_ID, notification, type)
        } catch (e: Exception) {
            Log.e(TAG, "typed startForeground failed, retrying plain", e)
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (e2: Exception) {
                Log.e(TAG, "startForeground failed entirely", e2)
            }
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(screenReceiver) }
        stopListeningInternal()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
