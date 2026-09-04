package com.tokenburners.nova

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Thin fan-out from the native services to the Dart layer over
 * [NovaChannels.EVENTS]. The services (which have no view of the Flutter
 * engine) call the static [emit*] helpers; [MainActivity] owns the actual
 * [EventChannel] sink and registers it here.
 */
object NovaEventBridge : EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun send(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    fun emitWakeWord(audioPath: String? = null) = send(
        mapOf(
            "type" to "wakeWord",
            "ts" to System.currentTimeMillis(),
            "path" to audioPath,
        )
    )

    fun emitServiceState(running: Boolean) =
        send(mapOf("type" to "serviceState", "running" to running))

    fun emitAccessibilityState(connected: Boolean) =
        send(mapOf("type" to "accessibilityState", "connected" to connected))

    /** state: "off" (screen off) | "present" (unlocked). Drives idle sleep. */
    fun emitScreenState(state: String) =
        send(mapOf("type" to "screenState", "state" to state))

    /** cmd: "pause" | "resume" | "test" from the notification action buttons. */
    fun emitControl(cmd: String) =
        send(mapOf("type" to "control", "cmd" to cmd))

    fun hasSink(): Boolean = sink != null
}
