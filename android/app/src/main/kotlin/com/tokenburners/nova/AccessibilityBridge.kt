package com.tokenburners.nova

import android.accessibilityservice.AccessibilityService
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * The single generic driver behind every "operate another app" skill — Gmail,
 * WhatsApp, and any other installed app. It never hardcodes per-app logic:
 * skills describe *what* to find and tap/type, this class does it against the
 * live node tree of whatever app is in the foreground.
 *
 * The user enables it once, by hand, in Android Settings → Accessibility.
 * Send actions still route through the Dart reasoning engine's confirmation
 * step before any skill calls in here.
 */
class AccessibilityBridge : AccessibilityService() {

    companion object {
        @Volatile
        var instance: AccessibilityBridge? = null
            private set

        val isConnected: Boolean get() = instance != null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        NovaEventBridge.emitAccessibilityState(true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Nova drives the UI on demand rather than reacting to every event.
        // Window-change events are still useful as a "screen settled" signal
        // for skills that wait between steps; left as a hook for now.
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        NovaEventBridge.emitAccessibilityState(false)
        return super.onUnbind(intent)
    }

    // ── Primitive operations reused by every app_control-based skill ──────────

    /** First visible node whose text or content-description contains [query]. */
    fun findByText(query: String): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        return root.findAccessibilityNodeInfosByText(query)?.firstOrNull()
            ?: dfs(root) { node ->
                node.contentDescription?.toString()?.contains(query, ignoreCase = true) == true
            }
    }

    fun findByViewId(viewId: String): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        return root.findAccessibilityNodeInfosByViewId(viewId)?.firstOrNull()
    }

    /** The editable field that currently has input focus, if any. */
    fun focusedEditable(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focused != null && focused.isEditable) return focused
        return dfs(root) { it.isEditable && it.isFocused }
    }

    /** Tap [node], walking up to the nearest clickable ancestor if needed. */
    fun tap(node: AccessibilityNodeInfo?): Boolean {
        var current = node
        while (current != null) {
            if (current.isClickable) {
                return current.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            }
            current = current.parent
        }
        return false
    }

    fun typeText(node: AccessibilityNodeInfo?, text: String): Boolean {
        node ?: return false
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                text
            )
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    fun back(): Boolean = performGlobalAction(GLOBAL_ACTION_BACK)
    fun home(): Boolean = performGlobalAction(GLOBAL_ACTION_HOME)

    private fun dfs(
        node: AccessibilityNodeInfo,
        predicate: (AccessibilityNodeInfo) -> Boolean
    ): AccessibilityNodeInfo? {
        if (predicate(node)) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            dfs(child, predicate)?.let { return it }
        }
        return null
    }
}
