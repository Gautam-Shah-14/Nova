package com.tokenburners.nova

import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Native side of on-device STT — whisper.cpp mobile build (tiny/base GGUF).
 *
 * The JNI layer isn't linked yet: [nativeInit] / [nativeTranscribe] are where
 * the whisper.cpp `libwhisper.so` calls go. Until then [transcribe] returns an
 * empty string so the worker loop degrades to "didn't catch that" rather than
 * crashing. Everything around it — model-path handling, threading, the channel
 * contract — is real.
 */
class WhisperBridge : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "NovaWhisper"
    }

    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var modelPath: String? = null
    @Volatile private var ready = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> {
                val path = call.argument<String>("modelPath")
                io.execute {
                    val ok = loadModel(path)
                    result.postSuccess(ok)
                }
            }
            "transcribe" -> {
                val wav = call.argument<String>("wavPath")
                io.execute {
                    result.postSuccess(transcribe(wav))
                }
            }
            "isReady" -> result.success(ready)
            "unload" -> {
                ready = false
                modelPath = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun loadModel(path: String?): Boolean {
        if (path == null || !File(path).exists()) {
            Log.w(TAG, "model missing at $path")
            return false
        }
        modelPath = path
        // TODO(nova): ready = nativeInit(path)
        ready = false
        Log.i(TAG, "model registered at $path (native whisper not linked yet)")
        return ready
    }

    private fun transcribe(wavPath: String?): String {
        if (!ready || wavPath == null || !File(wavPath).exists()) return ""
        // TODO(nova): return nativeTranscribe(wavPath).trim()
        return ""
    }

    // external fun nativeInit(modelPath: String): Boolean
    // external fun nativeTranscribe(wavPath: String): String
}

private fun MethodChannel.Result.postSuccess(value: Any?) {
    android.os.Handler(android.os.Looper.getMainLooper()).post { success(value) }
}
