// android/app/src/main/kotlin/com/example/nari_shakti/SosReceiver.kt

package com.example.Sahay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SosReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "com.narishakti.TRIGGER_SOS") {
            // Launch app and trigger SOS
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                action = "TRIGGER_SOS_FROM_NOTIFICATION"
                flags  = Intent.FLAG_ACTIVITY_NEW_TASK or
                         Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            context.startActivity(launchIntent)
        }
    }
}