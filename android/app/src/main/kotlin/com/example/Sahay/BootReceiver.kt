package com.example.Sahay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED ||
            intent?.action == "android.intent.action.QUICKBOOT_POWERON") {
            // The flutter_foreground_task handles auto-restart on boot
            // via its autoRunOnBoot option. This receiver is kept as a
            // backup to ensure the app can restart its services.
        }
    }
}
