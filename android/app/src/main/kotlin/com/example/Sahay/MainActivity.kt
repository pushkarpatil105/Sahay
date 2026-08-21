package com.example.Sahay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.telephony.SmsManager
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }
    private val SMS_CHANNEL       = "com.sahay.app/sms"
    private val NOTIF_CHANNEL     = "com.sahay.app/notifications"
    private val SHAKE_CHANNEL     = "com.sahay.app/shake_service"
    private val DANGER_CHANNEL_ID = "danger_zone_channel"
    private val LOCK_SCREEN_CHANNEL_ID = "lock_screen_sos"
    private val LOCK_SCREEN_NOTIF_ID   = 777

    private var notifMethodChannel: MethodChannel? = null

    // BroadcastReceiver to catch the SOS button tap
    private val sosReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == "com.sahay.TRIGGER_SOS") {
                notifMethodChannel?.invokeMethod("onSosNotificationTapped", null)
            }
        }
    }

    // BroadcastReceiver for countdown cancel
    private val sosCancelReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == "com.sahay.CANCEL_COUNTDOWN") {
                notifMethodChannel?.invokeMethod("onSosCountdownCancelled", null)
            }
        }
    }

    // BroadcastReceiver for native shake SOS detection
    private val shakeSOSReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == "com.sahay.SHAKE_SOS_DETECTED") {
                notifMethodChannel?.invokeMethod("onShakeSosDetected", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createNotificationChannel()

        // Register receivers
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(sosReceiver, IntentFilter("com.sahay.TRIGGER_SOS"), RECEIVER_EXPORTED)
            registerReceiver(sosCancelReceiver, IntentFilter("com.sahay.CANCEL_COUNTDOWN"), RECEIVER_EXPORTED)
            registerReceiver(shakeSOSReceiver, IntentFilter("com.sahay.SHAKE_SOS_DETECTED"), RECEIVER_EXPORTED)
        } else {
            registerReceiver(sosReceiver, IntentFilter("com.sahay.TRIGGER_SOS"))
            registerReceiver(sosCancelReceiver, IntentFilter("com.sahay.CANCEL_COUNTDOWN"))
            registerReceiver(shakeSOSReceiver, IntentFilter("com.sahay.SHAKE_SOS_DETECTED"))
        }

        // ── SMS Channel ──────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "sendSMS") {
                    val phone   = call.argument<String>("phone")
                    val message = call.argument<String>("message")
                    try {
                        val smsManager = SmsManager.getDefault()
                        val parts      = smsManager.divideMessage(message)
                        smsManager.sendMultipartTextMessage(
                            phone, null, parts, null, null
                        )
                        result.success("sent")
                    } catch (e: Exception) {
                        result.error("SMS_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        // ── Notification Channel ─────────────────────────────────────────
        notifMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, NOTIF_CHANNEL
        )
        notifMethodChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "showDangerNotification" -> {
                    val title   = call.argument<String>("title")   ?: "⚠️ Danger Zone"
                    val message = call.argument<String>("message") ?: "Unsafe area nearby"
                    showDangerNotification(title, message)
                    result.success("shown")
                }
                "showSOSNotification" -> {
                    val title   = call.argument<String>("title")   ?: "🆘 SOS Triggered"
                    val message = call.argument<String>("message") ?: "Emergency alert sent"
                    showSOSNotification(title, message)
                    result.success("shown")
                }
                "showSosNotification" -> {
                    val title   = call.argument<String>("title")   ?: "Sahay Active"
                    val body    = call.argument<String>("body")    ?: "Tap for SOS"
                    val ongoing = call.argument<Boolean>("ongoing") ?: true
                    showLockScreenSosNotification(title, body, ongoing)
                    result.success("shown")
                }
                "showCountdownNotification" -> {
                    val secondsLeft = call.argument<Int>("secondsLeft") ?: 10
                    val showCancel = call.argument<Boolean>("showCancelButton") ?: true
                    showCountdownNotification(secondsLeft, showCancel)
                    result.success("shown")
                }
                "cancelCountdownNotification" -> {
                    val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    notifManager.cancel(778)
                    result.success("cancelled")
                }
                "vibrateSOS" -> {
                    try {
                        vibratePattern(longArrayOf(0, 400, 100, 400, 100, 800))
                        result.success("vibrated")
                    } catch (e: Exception) {
                        result.error("VIBRATOR_ERROR", e.message, null)
                    }
                }
                "vibrateSOSDouble" -> {
                    try {
                        vibratePattern(longArrayOf(0, 350, 120, 350))
                        result.success("vibrated")
                    } catch (e: Exception) {
                        result.error("VIBRATOR_ERROR", e.message, null)
                    }
                }
                "vibrateSOSWarning" -> {
                    try {
                        vibratePattern(longArrayOf(0, 180))
                        result.success("vibrated")
                    } catch (e: Exception) {
                        result.error("VIBRATOR_ERROR", e.message, null)
                    }
                }
                "cancelSosNotification" -> {
                    cancelLockScreenSosNotification()
                    result.success("cancelled")
                }
                "isXiaomiDevice" -> {
                    val manufacturer = android.os.Build.MANUFACTURER.lowercase()
                    val isXiaomi = manufacturer.contains("xiaomi") || manufacturer.contains("redmi") || manufacturer.contains("poco")
                    result.success(isXiaomi)
                }
                "requestXiaomiPopUpPermission" -> {
                    try {
                        val intent = Intent("miui.intent.action.APP_PERM_EDITOR")
                        intent.setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
                        intent.putExtra("extra_pkgname", packageName)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            val intent = Intent("miui.intent.action.APP_PERM_EDITOR")
                            intent.setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.AppPermissionsEditorActivity")
                            intent.putExtra("extra_pkgname", packageName)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            intent.data = android.net.Uri.parse("package:$packageName")
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(false)
                        }
                    }
                }
                "isAccessibilityServiceEnabled" -> {
                    val enabledServices = android.provider.Settings.Secure.getString(
                        contentResolver,
                        android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                    )
                    val isEnabled = enabledServices?.contains(packageName + "/.VolumeButtonAccessibilityService") == true
                    result.success(isEnabled)
                }
                "requestAccessibilityPermission" -> {
                    val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(true)
                }
                "bringAppToForeground" -> {
                    val intent = Intent(this@MainActivity, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        // If we have explicit permission to overlay, bypass the notification sandbox
                        if (android.provider.Settings.canDrawOverlays(this@MainActivity)) {
                            Log.d("Sahay", "Overlay permission active - forcing Flutter foreground launch")
                            startActivity(intent)
                        } else {
                            try {
                                val pendingIntent = PendingIntent.getActivity(
                                    this@MainActivity,
                                    9999,
                                    intent,
                                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                                )

                                val builder = NotificationCompat.Builder(this@MainActivity, LOCK_SCREEN_CHANNEL_ID)
                                    .setSmallIcon(android.R.drawable.ic_dialog_alert)
                                    .setContentTitle("SOS Active")
                                    .setContentText("Recording in progress...")
                                    .setPriority(NotificationCompat.PRIORITY_MAX)
                                    .setCategory(NotificationCompat.CATEGORY_ALARM)
                                    .setFullScreenIntent(pendingIntent, true)
                                    .setAutoCancel(true)

                                val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                                notifManager.notify(8888, builder.build())
                            } catch (e: Exception) {
                                startActivity(intent)
                            }
                        }
                    } else {
                        startActivity(intent)
                    }

                    result.success("brought_to_foreground")
                }
                "launchNativeSosCountdown" -> {
                    val seconds = call.argument<Int>("seconds") ?: 5
                    try {
                        val intent = Intent(this@MainActivity, SosCountdownActivity::class.java).apply {
                            putExtra(SosCountdownActivity.EXTRA_COUNTDOWN_SECONDS, seconds)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success("launched")
                    } catch (e: Exception) {
                        result.error("LAUNCH_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── Shake Service Channel ────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHAKE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startShakeService" -> {
                        val intent = Intent(this, ShakeDetectionForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success("started")
                    }
                    "stopShakeService" -> {
                        val intent = Intent(this, ShakeDetectionForegroundService::class.java)
                        stopService(intent)
                        result.success("stopped")
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(sosReceiver)
        unregisterReceiver(sosCancelReceiver)
        unregisterReceiver(shakeSOSReceiver)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val dangerChannel = NotificationChannel(
                DANGER_CHANNEL_ID, "Danger Zone Alerts", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alerts when entering unsafe areas"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 200, 500)
            }
            notifManager.createNotificationChannel(dangerChannel)

            val sosChannel = NotificationChannel(
                "sos_channel", "SOS Alerts", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "SOS trigger notifications"
            }
            notifManager.createNotificationChannel(sosChannel)

            // HIGH-importance channel for countdown & SOS active alerts (heads-up on lock screen)
            val countdownChannel = NotificationChannel(
                "sos_countdown_channel", "SOS Countdown", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Urgent SOS countdown and active indicators"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 300, 200, 300)
            }
            notifManager.createNotificationChannel(countdownChannel)

            // LOW-importance channel for the always-on persistent protection notification
            val persistentChannel = NotificationChannel(
                LOCK_SCREEN_CHANNEL_ID, "Lock Screen SOS", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Persistent SOS button on lock screen"
                setSound(null, null)
                enableVibration(false)
            }
            notifManager.createNotificationChannel(persistentChannel)

            // Channel for native shake detection foreground service
            val shakeServiceChannel = NotificationChannel(
                "shake_detection_channel", "Shake Detection", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shake detection running in background"
                setSound(null, null)
                enableVibration(false)
            }
            notifManager.createNotificationChannel(shakeServiceChannel)
        }
    }

    private fun showLockScreenSosNotification(title: String, body: String, ongoing: Boolean) {
        val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openAppPending = PendingIntent.getActivity(
            this, 777, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val sosIntent = Intent("com.sahay.TRIGGER_SOS").apply {
            setPackage(packageName)
        }
        val sosPending = PendingIntent.getBroadcast(
            this, 778, sosIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, LOCK_SCREEN_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(title)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openAppPending)
            .setOngoing(ongoing)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(android.R.drawable.ic_dialog_alert, "🆘 Trigger SOS", sosPending)
            .build()

        notifManager.notify(LOCK_SCREEN_NOTIF_ID, notification)
    }

    private fun showCountdownNotification(secondsLeft: Int, showCancel: Boolean) {
        val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val openAppPending = PendingIntent.getActivity(
            this, 777, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val cancelIntent = Intent("com.sahay.CANCEL_COUNTDOWN").apply {
            setPackage(packageName)
        }
        val cancelPending = PendingIntent.getBroadcast(
            this, 779, cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Use HIGH-importance channel so it pops up on lock screen as heads-up
        val builder = NotificationCompat.Builder(this, "sos_countdown_channel")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle("🆘 SOS in $secondsLeft seconds...")
            .setContentText("Shake detected — SOS will auto-send in ${secondsLeft}s")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setContentIntent(openAppPending)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        // Full-screen intent for Android 10+ lock screen
        builder.setFullScreenIntent(openAppPending, true)

        if (showCancel) {
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "✅ I AM SAFE", cancelPending)
        }

        // Use ID 778 (separate from persistent notification at 777)
        notifManager.notify(778, builder.build())
    }

    private fun cancelLockScreenSosNotification() {
        val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notifManager.cancel(LOCK_SCREEN_NOTIF_ID) // persistent notification (777)
        notifManager.cancel(778)                  // countdown notification (778)
    }

    private fun vibratePattern(pattern: LongArray) {
        val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vm.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }

        try {
            v.cancel()
        } catch (_: Exception) {
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            v.vibrate(VibrationEffect.createWaveform(pattern, -1))
        } else {
            @Suppress("DEPRECATION") v.vibrate(pattern, -1)
        }
    }

    private fun showDangerNotification(title: String, message: String) {
        val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val intent = Intent(this, MainActivity::class.java).apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }
        val pendingIntent = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, DANGER_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(title)
            .setContentText(message)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        notifManager.notify(1001, notification)
    }

    private fun showSOSNotification(title: String, message: String) {
        val notifManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val intent = Intent(this, MainActivity::class.java).apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }
        val pendingIntent = PendingIntent.getActivity(this, 1, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(this, "sos_channel")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(title)
            .setContentText(message)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        notifManager.notify(1002, notification)
    }
}