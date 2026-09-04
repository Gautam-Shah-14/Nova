package com.tokenburners.nova

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import kotlin.math.roundToInt

/**
 * Renders the floating status dot over every app via SYSTEM_ALERT_WINDOW.
 * This is the second of the two render targets driven by the single status
 * enum (available / working / sleeping); the first is the foreground-service
 * notification icon.
 *
 * If a custom icon was baked in at build time it should be drawn here instead
 * of the generated dot — resolved once, Dart-side, and passed in via
 * [EXTRA_STATUS] plus (later) an asset handle.
 */
class OverlayService : Service() {

    companion object {
        const val ACTION_SHOW = "com.tokenburners.nova.SHOW_OVERLAY"
        const val ACTION_HIDE = "com.tokenburners.nova.HIDE_OVERLAY"
        const val ACTION_SET_STATUS = "com.tokenburners.nova.OVERLAY_SET_STATUS"
        const val EXTRA_STATUS = "status"

        fun canDraw(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

        fun show(context: Context) {
            if (!canDraw(context)) return
            context.startService(
                Intent(context, OverlayService::class.java).setAction(ACTION_SHOW)
            )
        }

        fun hide(context: Context) {
            context.startService(
                Intent(context, OverlayService::class.java).setAction(ACTION_HIDE)
            )
        }
    }

    private var windowManager: WindowManager? = null
    private var dot: View? = null
    private var status: String = "available"

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> {
                removeDot()
                stopSelf()
            }
            ACTION_SET_STATUS -> {
                status = intent.getStringExtra(EXTRA_STATUS) ?: status
                applyColor()
            }
            else -> addDot()
        }
        return START_STICKY
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).roundToInt()

    private fun colorForStatus(): Int = when (status) {
        "working" -> Color.parseColor("#F5B301")   // yellow
        "sleeping" -> Color.parseColor("#E53935")  // red
        else -> Color.parseColor("#2E7D32")        // green
    }

    private fun addDot() {
        if (dot != null) {
            applyColor()
            return
        }
        if (!canDraw(this)) {
            stopSelf()
            return
        }
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = wm

        val view = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(colorForStatus())
                setStroke(dp(2), Color.argb(90, 0, 0, 0))
            }
        }

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            dp(16),
            dp(16),
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = dp(8)
            y = dp(120)
        }

        wm.addView(view, params)
        dot = view
    }

    private fun applyColor() {
        (dot?.background as? GradientDrawable)?.setColor(colorForStatus())
    }

    private fun removeDot() {
        dot?.let { windowManager?.removeView(it) }
        dot = null
    }

    override fun onDestroy() {
        removeDot()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
