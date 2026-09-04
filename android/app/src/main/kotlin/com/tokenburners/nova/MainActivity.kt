package com.tokenburners.nova

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Nova has no user-facing screens. This activity exists only so Android has a
 * launchable entry point that can bootstrap the Flutter engine, bridge the Dart
 * layer to the native services, and then get out of the way. The persistent
 * work lives in [WakeWordForegroundService], [OverlayService] and
 * [AccessibilityBridge].
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, NovaChannels.EVENTS).setStreamHandler(NovaEventBridge)
        MethodChannel(messenger, NovaChannels.STT).setMethodCallHandler(WhisperBridge())
        MethodChannel(messenger, NovaChannels.LLM).setMethodCallHandler(LlamaBridge())
        MethodChannel(messenger, NovaChannels.A11Y).setMethodCallHandler(A11yBridge())

        MethodChannel(messenger, NovaChannels.BRIDGE).setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    WakeWordForegroundService.start(this)
                    result.success(null)
                }
                "stopListening" -> {
                    WakeWordForegroundService.stop(this)
                    result.success(null)
                }
                "serviceRunning" -> result.success(WakeWordForegroundService.isRunning)
                "simulateWake" -> {
                    WakeWordForegroundService.simulateWake(this)
                    result.success(null)
                }

                "setStatus" -> {
                    val status = call.argument<String>("status") ?: "available"
                    startService(
                        Intent(this, WakeWordForegroundService::class.java)
                            .setAction(WakeWordForegroundService.ACTION_SET_STATUS)
                            .putExtra(WakeWordForegroundService.EXTRA_STATUS, status)
                    )
                    startService(
                        Intent(this, OverlayService::class.java)
                            .setAction(OverlayService.ACTION_SET_STATUS)
                            .putExtra(OverlayService.EXTRA_STATUS, status)
                    )
                    result.success(null)
                }

                "showOverlay" -> {
                    OverlayService.show(this)
                    result.success(OverlayService.canDraw(this))
                }
                "hideOverlay" -> {
                    OverlayService.hide(this)
                    result.success(null)
                }
                "canDrawOverlays" -> result.success(OverlayService.canDraw(this))
                "openOverlaySettings" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }

                "isAccessibilityConnected" -> result.success(AccessibilityBridge.isConnected)
                "openAccessibilitySettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }

                "launchApp" -> {
                    val pkg = call.argument<String>("package")
                    val launch = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
                    if (launch == null) {
                        result.error("not_found", "No launchable activity for $pkg", null)
                    } else {
                        startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    }
                }
                "listLaunchableApps" -> result.success(launchableApps())

                "findContact" -> {
                    val query = call.argument<String>("query")
                    if (query.isNullOrBlank()) {
                        result.error("bad_args", "query required", null)
                    } else {
                        result.success(findContact(query))
                    }
                }
                "dialNumber" -> {
                    val number = call.argument<String>("number")
                    if (number.isNullOrBlank()) {
                        result.error("bad_args", "number required", null)
                    } else {
                        runCatching {
                            startActivity(
                                Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(number)}"))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }.fold({ result.success(true) }, { result.success(false) })
                    }
                }

                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "url required", null)
                    } else {
                        runCatching {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }.fold({ result.success(true) }, { result.success(false) })
                    }
                }

                "deviceRamMb" -> result.success(deviceRamMb())

                else -> result.notImplemented()
            }
        }
    }

    /** [{package, label}] for every app with a launcher entry — feeds the
     *  generic "open any app" skill so nothing is hardcoded. */
    private fun launchableApps(): List<Map<String, String>> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packageManager.queryIntentActivities(intent, 0).map {
            mapOf(
                "package" to it.activityInfo.packageName,
                "label" to it.loadLabel(packageManager).toString()
            )
        }.distinctBy { it["package"] }
    }

    /** Best phone-number match for a spoken contact name, via the same
     *  autocomplete index Android's own dialer/contacts UI uses. Null if
     *  READ_CONTACTS isn't granted or nothing matches. */
    private fun findContact(query: String): Map<String, String>? {
        if (checkSelfPermission(android.Manifest.permission.READ_CONTACTS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val uri = Uri.withAppendedPath(
            android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI,
            Uri.encode(query)
        )
        val projection = arrayOf(
            android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER
        )
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val name = cursor.getString(0) ?: query
                val number = cursor.getString(1) ?: return null
                return mapOf("name" to name, "number" to number)
            }
        }
        return null
    }

    /** Total device RAM in MB — drives primary vs fallback LLM selection. */
    private fun deviceRamMb(): Int {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return (info.totalMem / (1024L * 1024L)).toInt()
    }
}
