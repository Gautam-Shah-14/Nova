package com.tokenburners.nova

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Exposes [AccessibilityBridge]'s primitives to Dart. Every "operate another
 * app" skill (Gmail, WhatsApp, generic app control) goes through here — no
 * per-app native code.
 *
 * Returns a `connected:false` marker when the user hasn't enabled the service
 * yet, so skills can prompt for it instead of silently failing.
 */
class A11yBridge : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val svc = AccessibilityBridge.instance
        if (svc == null && call.method != "isConnected") {
            result.success(mapOf("connected" to false))
            return
        }

        when (call.method) {
            "isConnected" -> result.success(mapOf("connected" to (svc != null)))

            "findText" -> {
                val q = call.argument<String>("text").orEmpty()
                result.success(mapOf("connected" to true, "found" to (svc!!.findByText(q) != null)))
            }

            "tapText" -> {
                val q = call.argument<String>("text").orEmpty()
                val node = svc!!.findByText(q)
                result.success(mapOf("connected" to true, "ok" to svc.tap(node)))
            }

            "tapViewId" -> {
                val id = call.argument<String>("viewId").orEmpty()
                val node = svc!!.findByViewId(id)
                result.success(mapOf("connected" to true, "ok" to svc.tap(node)))
            }

            "typeInto" -> {
                val target = call.argument<String>("target")
                val text = call.argument<String>("text").orEmpty()
                val node = if (target != null) svc!!.findByText(target) else svc!!.focusedEditable()
                result.success(mapOf("connected" to true, "ok" to svc.typeText(node, text)))
            }

            "back" -> result.success(mapOf("connected" to true, "ok" to svc!!.back()))
            "home" -> result.success(mapOf("connected" to true, "ok" to svc!!.home()))

            else -> result.notImplemented()
        }
    }
}
