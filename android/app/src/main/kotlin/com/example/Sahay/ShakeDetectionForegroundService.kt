package com.example.Sahay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Native Android foreground service that detects shake gestures even when the
 * device screen is locked. Uses hardware accelerometer with a partial WakeLock
 * so the CPU stays awake to process sensor events.
 *
 * Shake algorithm: 5 shakes above 15 m/s² within 3 seconds, with 300ms debounce.
 * Matches the Dart ProtectionTaskHandler constants exactly.
 */
class ShakeDetectionForegroundService : Service(), SensorEventListener {

    companion object {
        private const val TAG = "ShakeDetectionService"
        private const val CHANNEL_ID = "shake_protection_high"
        private const val NOTIF_ID = 900

        // Shake detection parameters — same as Dart ProtectionTaskHandler
        private const val SHAKE_COUNT_THRESHOLD = 5
        private const val SHAKE_FORCE_THRESHOLD = 15.0
        private const val SHAKE_WINDOW_MS = 3000
        private const val DEBOUNCE_MS = 300
    }

    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private var shakeCount = 0
    private var firstShakeTime: Long = 0
    private var lastShakeTime: Long = 0

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "Service starting")

        // Create notification channel (safe to call multiple times)
        createNotificationChannel()

        // Start as foreground service with persistent notification
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID, 
                notification, 
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }

        // Acquire partial WakeLock to keep CPU alive while screen is off
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "NariShakti::ShakeDetectionWakeLock"
        ).apply {
            acquire() // Released in onDestroy
        }

        // Register accelerometer sensor listener
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (accelerometer != null) {
            sensorManager?.registerListener(
                this,
                accelerometer,
                SensorManager.SENSOR_DELAY_UI // ~60ms, good balance of accuracy vs battery
            )
            Log.d(TAG, "Accelerometer registered successfully")
        } else {
            Log.e(TAG, "No accelerometer sensor found on this device")
        }

        return START_STICKY // Restart if killed by system
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_ACCELEROMETER) return

        val x = event.values[0].toDouble()
        val y = event.values[1].toDouble()
        val z = event.values[2].toDouble()

        val magnitude = sqrt(x * x + y * y + z * z)
        val acceleration = abs(magnitude - 9.8)

        if (acceleration > SHAKE_FORCE_THRESHOLD) {
            val now = System.currentTimeMillis()

            // Debounce: prevent double-counting the same shake
            if (lastShakeTime > 0 && (now - lastShakeTime) < DEBOUNCE_MS) {
                return
            }
            lastShakeTime = now

            // Start new window on first shake
            if (firstShakeTime == 0L) {
                firstShakeTime = now
                shakeCount = 1
                Log.d(TAG, "Shake #1 detected — window started")
                return
            }

            val elapsed = now - firstShakeTime

            if (elapsed <= SHAKE_WINDOW_MS) {
                shakeCount++
                Log.d(TAG, "Shake #$shakeCount detected (${elapsed}ms elapsed)")

                if (shakeCount >= SHAKE_COUNT_THRESHOLD) {
                    shakeCount = 0
                    firstShakeTime = 0
                    lastShakeTime = 0
                    onShakeDetected()
                }
            } else {
                // Reset window
                firstShakeTime = now
                shakeCount = 1
                Log.d(TAG, "Shake window expired — reset, Shake #1")
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // Not needed
    }

    private fun onShakeDetected() {
        Log.i(TAG, "🔔 SHAKE SOS DETECTED — launching via Full-Screen Intent")

        // Wake the screen first — critical for lock screen on Xiaomi/MIUI
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = pm.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "NariShakti::ShakeWakeScreen"
            )
            wakeLock.acquire(5_000L) // Brief wake to get the activity started
        } catch (e: Exception) {
            Log.w(TAG, "Failed to wake screen: $e")
        }

        // On Android 10+ (API 29+), starting an activity from a background service is blocked.
        // If we have SYSTEM_ALERT_WINDOW (canDrawOverlays), we can bypass this and force launch aggressively!
        val fullScreenIntent = Intent(this, SosCountdownActivity::class.java).apply {
            putExtra(SosCountdownActivity.EXTRA_COUNTDOWN_SECONDS, 5)
            // Use NEW_TASK and CLEAR_TASK so it pops cleanly
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }

        // ALWAYS fire the Full-Screen Intent Notification to guarantee delivery.
        // On lock screens, this safely wakes the device. On unlocked screens without overlay permission, it shows a Heads-Up.
        val fullScreenPendingIntent = PendingIntent.getActivity(
            this,
            1234,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notificationBuilder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("SOS Triggered")
            .setContentText("SOS Countdown started...")
            .setPriority(NotificationCompat.PRIORITY_MAX) // MAX priority required
            .setCategory(NotificationCompat.CATEGORY_ALARM) // ALARM category allows bypassing lock screen
            .setFullScreenIntent(fullScreenPendingIntent, true) // TRUE forces high-priority launch
            .setAutoCancel(true)
            .setOngoing(false)

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(7777, notificationBuilder.build())

        // IF they have explicit overlay permission, ALSO try to aggressively start the Activity directly!
        // This attempts to forcefully bypass the Heads-Up Notification on unlocked screens!
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M && 
            android.provider.Settings.canDrawOverlays(this)) {
            Log.i(TAG, "Has Overlay permission — forcing startActivity bypass")
            try {
                startActivity(fullScreenIntent)
            } catch (e: Exception) {
                Log.e(TAG, "startActivity bypass failed: $e")
            }
        }
    }


    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Nari Shakti Protection",
                NotificationManager.IMPORTANCE_HIGH  // HIGH so it shows on lock screen
            ).apply {
                description = "SOS protection — shake detection active"
                setSound(null, null)     // No sound for ongoing notification
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setShowBadge(true)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, NOTIF_ID, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("🛡️ Nari Shakti Protection Active")
            .setContentText("Shake to trigger SOS — active even when locked")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setShowWhen(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    override fun onDestroy() {
        Log.d(TAG, "Service stopping")

        // Unregister sensor listener
        sensorManager?.unregisterListener(this)

        // Release WakeLock
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        wakeLock = null

        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
