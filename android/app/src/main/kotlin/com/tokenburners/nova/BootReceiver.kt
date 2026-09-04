package com.tokenburners.nova

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Re-arms the wake-word listener after a reboot so Nova comes back on its own.
 * Note: Android 12+ blocks starting a mic-typed foreground service directly
 * from BOOT_COMPLETED, so the service starts in the "sleeping" state and only
 * opens the mic once the user next unlocks the device.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            WakeWordForegroundService.start(context)
        }
    }
}
