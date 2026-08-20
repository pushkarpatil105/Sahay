package com.example.nari_shakti

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.os.PowerManager
import android.content.Context

class VolumeButtonAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "VolumeAccessibility_SOS"
        private const val TARGET_PRESS_COUNT = 5
        private const val TIME_WINDOW_MS = 3000L
    }

    private var pressCount = 0
    private var firstPressTime = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.i(TAG, "VolumeButtonAccessibilityService connected!")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used for key events
    }

    override fun onInterrupt() {
        Log.i(TAG, "VolumeButtonAccessibilityService interrupted.")
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        // We only care about hardware VOLUME DOWN presses, and only the ACTION_DOWN part of the press
        if (event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN && event.action == KeyEvent.ACTION_DOWN) {
            val now = System.currentTimeMillis()

            if (pressCount == 0 || now - firstPressTime > TIME_WINDOW_MS) {
                // First press or window expired, reset
                firstPressTime = now
                pressCount = 1
                Log.d(TAG, "Volume Down #1 (Window Started)")
                return false // Don't consume it, let system change volume
            }

            pressCount++
            Log.d(TAG, "Volume Down #$pressCount (${now - firstPressTime}ms elapsed)")

            if (pressCount >= TARGET_PRESS_COUNT) {
                Log.i(TAG, "🔔 5x Volume Down SOS Detected!")
                triggerSOS()
                
                // Reset counter
                pressCount = 0
                firstPressTime = 0L
                
                // Since this was the final trigger, we can consume this event
                return true
            }

            // Return false strictly so the normal volume down UI still functions and we don't break the user's phone purely by counting!
            return false
        }
        
        return super.onKeyEvent(event)
    }

    private fun triggerSOS() {
        // EXACT SAME OVERRIDE LOGIC AS THE SHAKE SERVICE!
        
        // 1. Force the screen to wake up (Critical for lock screen execution!)
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = pm.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "NariShakti::VolumeWakeScreen"
            )
            wakeLock.acquire(5_000L) // Brief wake to allow the activity native jump
        } catch (e: Exception) {
            Log.w(TAG, "Failed to wake screen: $e")
        }

        // 2. Prep the SOS Countdown Activity Full-Screen intent
        val fullScreenIntent = Intent(this, SosCountdownActivity::class.java).apply {
            putExtra(SosCountdownActivity.EXTRA_COUNTDOWN_SECONDS, 5)
            // Use NEW_TASK and CLEAR_TASK so it pops cleanly
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }

        // 3. Immediately Broadcast the Native High-Priority FullScreenIntent Notification (Fallback safety net)
        val fullScreenPendingIntent = android.app.PendingIntent.getActivity(
            this,
            1235, // Different request code from Shake
            fullScreenIntent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )

        val notificationBuilder = androidx.core.app.NotificationCompat.Builder(this, "com.narishakti.app/shake_service")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("SOS Triggered")
            .setContentText("Hardware Volume Trigger matched!")
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_MAX)
            .setCategory(androidx.core.app.NotificationCompat.CATEGORY_ALARM)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setAutoCancel(true)
            .setOngoing(false)

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        notificationManager.notify(7777, notificationBuilder.build())

        // 4. Force bypass via direct startActivity if SYSTEM_ALERT_WINDOW is granted natively (Anti-Heads-Up)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M && 
            android.provider.Settings.canDrawOverlays(this)) {
            Log.i(TAG, "Has Overlay permission — forcing startActivity bypass on Volume")
            try {
                startActivity(fullScreenIntent)
            } catch (e: Exception) {
                Log.e(TAG, "startActivity bypass failed: $e")
            }
        }
    }
}
