package com.example.nari_shakti

import android.animation.ValueAnimator
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.CountDownTimer
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.widget.Button
import android.widget.TextView

/**
 * Full-screen native Activity that shows OVER THE LOCK SCREEN when shake SOS
 * is detected. Displays a 5-second countdown with "I AM SAFE" cancel button.
 *
 * Uses every possible method to ensure visibility on lock screen:
 * - PowerManager.ACQUIRE_CAUSES_WAKEUP to turn screen on
 * - Deprecated window flags for older devices + Xiaomi/MIUI
 * - New API27+ methods (setShowWhenLocked / setTurnScreenOn)
 * - KeyguardManager.requestDismissKeyguard
 */
class SosCountdownActivity : Activity() {

    companion object {
        private const val TAG = "SosCountdownActivity"
        const val EXTRA_COUNTDOWN_SECONDS = "countdown_seconds"
        private const val DEFAULT_COUNTDOWN = 5
    }

    private var countdownTimer: CountDownTimer? = null
    private var progressAnimator: ValueAnimator? = null
    private var screenWakeLock: PowerManager.WakeLock? = null
    private var cancelled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ── Force screen ON  ─────────────────────────────────────────────
        // Acquire a FULL wake lock to force the screen on immediately.
        // This is critical on Xiaomi/MIUI devices where other methods fail.
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            screenWakeLock = pm.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "NariShakti::SOSCountdownScreen"
            )
            screenWakeLock?.acquire(30_000L) // 30s max, released in onDestroy
            Log.d(TAG, "Screen wake lock acquired")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire wake lock: $e")
        }

        // Clean up the fallback notification
        try {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            notificationManager.cancel(7777)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to cancel notification: $e")
        }

        // ── Show over lock screen (ALL methods) ──────────────────────────
        // Use BOTH deprecated flags AND new API for maximum compatibility.
        // Xiaomi/MIUI often ignores the new API but respects the old flags.
        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
            WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
        )

        // Also use new API on 27+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            try {
                val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                keyguardManager.requestDismissKeyguard(this, null)
            } catch (e: Exception) {
                Log.w(TAG, "requestDismissKeyguard failed: $e")
            }
        }

        // Full screen immersive
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        )

        // Dark status/nav bars
        window.statusBarColor = 0xFF111111.toInt()
        window.navigationBarColor = 0xFF111111.toInt()

        setContentView(R.layout.activity_sos_countdown)

        val countdownSeconds = intent.getIntExtra(EXTRA_COUNTDOWN_SECONDS, DEFAULT_COUNTDOWN)

        val tvCountdown = findViewById<TextView>(R.id.tvCountdownSeconds)
        val tvStatus = findViewById<TextView>(R.id.tvStatus)
        val btnCancel = findViewById<Button>(R.id.btnCancel)
        val btnDial112 = findViewById<Button>(R.id.btnDial112)
        val circleView = findViewById<CountdownCircleView>(R.id.countdownCircle)

        // ── Style the cancel button programmatically ─────────────────────
        btnCancel.background = createCancelButtonBackground()

        // ── DIAL 112 Override ────────────────────────────────────────────
        btnDial112.setOnClickListener {
            Log.d(TAG, "User overrode with 112 Dial")
            cancelled = true
            countdownTimer?.cancel()
            progressAnimator?.cancel()
            stopVibration()
            
            // Bypass countdown and violently trigger SOS
            triggerSOS()
            
            // Spawn Native Dialer
            val dialIntent = Intent(Intent.ACTION_DIAL).apply {
                data = android.net.Uri.parse("tel:112")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(dialIntent)
            
            finish()
        }

        // ── Cancel button ────────────────────────────────────────────────
        btnCancel.setOnClickListener {
            Log.d(TAG, "User pressed I AM SAFE — cancelling countdown")
            cancelled = true
            countdownTimer?.cancel()
            progressAnimator?.cancel()
            stopVibration()
            finish()
        }

        // ── Animate the circle ───────────────────────────────────────────
        progressAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = countdownSeconds * 1000L
            interpolator = LinearInterpolator()
            addUpdateListener { animation ->
                circleView.progress = animation.animatedValue as Float
            }
            start()
        }

        // ── Countdown timer ──────────────────────────────────────────────
        countdownTimer = object : CountDownTimer(
            countdownSeconds * 1000L, 1000L
        ) {
            override fun onTick(millisUntilFinished: Long) {
                val secondsLeft = (millisUntilFinished / 1000).toInt() + 1
                tvCountdown.text = secondsLeft.toString()
                tvStatus.text = "SOS will trigger in ${secondsLeft}s..."
                vibrateTick()
            }

            override fun onFinish() {
                if (!cancelled) {
                    tvCountdown.text = "0"
                    tvStatus.text = "Triggering SOS..."
                    stopVibration()
                    vibrateDouble()
                    triggerSOS()
                    tvCountdown.postDelayed({ finish() }, 800)
                }
            }
        }

        countdownTimer?.start()
        Log.d(TAG, "Countdown started: ${countdownSeconds}s")
        vibrateTick()
    }

    private fun triggerSOS() {
        Log.i(TAG, "⚡ SOS TRIGGERED from countdown activity")

        val sosIntent = Intent("com.narishakti.SHAKE_SOS_DETECTED").apply {
            setPackage(packageName)
        }
        sendBroadcast(sosIntent)

        PowerButtonBridge.onSOSTriggered?.invoke("shake")
    }

    private fun getVibrator(): Vibrator {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            vm.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    private fun vibrateTick() {
        try {
            val v = getVibrator()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createOneShot(280, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(280)
            }
        } catch (e: Exception) { Log.w(TAG, "Vibration start error: $e") }
    }

    private fun stopVibration() {
        try {
            getVibrator().cancel()
        } catch (e: Exception) { Log.w(TAG, "Vibration cancel error: $e") }
    }

    private fun vibrateDouble() {
        try {
            val v = getVibrator()
            val pattern = longArrayOf(0, 350, 120, 350)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(pattern, -1)
            }
        } catch (e: Exception) { Log.w(TAG, "Vibration double error: $e") }
    }

    private fun createCancelButtonBackground(): android.graphics.drawable.GradientDrawable {
        return android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.RECTANGLE
            cornerRadius = 32f * resources.displayMetrics.density
            setColor(0xFF333333.toInt())
            setStroke(
                (2 * resources.displayMetrics.density).toInt(),
                0xFF555555.toInt()
            )
        }
    }

    @Deprecated("Use onBackPressedDispatcher")
    override fun onBackPressed() {
        cancelled = true
        countdownTimer?.cancel()
        progressAnimator?.cancel()
        stopVibration()
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    override fun onDestroy() {
        countdownTimer?.cancel()
        progressAnimator?.cancel()
        stopVibration()

        // Release the screen wake lock
        if (screenWakeLock?.isHeld == true) {
            screenWakeLock?.release()
            Log.d(TAG, "Screen wake lock released")
        }
        screenWakeLock = null

        super.onDestroy()
    }
}
