package com.tokenburners.nova

import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Native side of on-device LLM inference — llama.cpp Android bindings, primary
 * model Qwen2.5-3B-Instruct (GGUF Q4_K_M), fallback Llama-3.2-1B.
 *
 * JNI not linked yet. [generate] throws so `LlmService` stays on its keyword
 * fallback until `libllama.so` is wired via [nativeLoad] / [nativeGenerate].
 * The model-path selection, prompt pass-through and threading are real.
 */
class LlamaBridge : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "NovaLlama"
    }

    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var ready = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> {
                val path = call.argument<String>("modelPath")
                val nCtx = call.argument<Int>("contextSize") ?: 2048
                io.execute {
                    val ok = loadModel(path, nCtx)
                    mainSuccess(result, ok)
                }
            }
            "generate" -> {
                val prompt = call.argument<String>("prompt").orEmpty()
                val maxTokens = call.argument<Int>("maxTokens") ?: 256
                io.execute {
                    try {
                        mainSuccess(result, generate(prompt, maxTokens))
                    } catch (e: Throwable) {
                        mainError(result, "generate_failed", e.message)
                    }
                }
            }
            "isReady" -> result.success(ready)
            "unload" -> {
                ready = false
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun loadModel(path: String?, nCtx: Int): Boolean {
        if (path == null || !File(path).exists()) {
            Log.w(TAG, "model missing at $path")
            return false
        }
        // TODO(nova): ready = nativeLoad(path, nCtx)
        ready = false
        Log.i(TAG, "model registered at $path ctx=$nCtx (native llama not linked yet)")
        return ready
    }

    private fun generate(prompt: String, maxTokens: Int): String {
        if (!ready) throw IllegalStateException("model not loaded")
        // TODO(nova): return nativeGenerate(prompt, maxTokens)
        throw UnsupportedOperationException("native llama not linked")
    }

    private fun mainSuccess(result: MethodChannel.Result, value: Any?) =
        android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(value) }

    private fun mainError(result: MethodChannel.Result, code: String, msg: String?) =
        android.os.Handler(android.os.Looper.getMainLooper()).post { result.error(code, msg, null) }

    // external fun nativeLoad(modelPath: String, nCtx: Int): Boolean
    // external fun nativeGenerate(prompt: String, maxTokens: Int): String
}
