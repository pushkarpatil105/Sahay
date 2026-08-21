package com.example.Sahay

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Intent
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

class VolumeButtonService : AccessibilityService() {

    private var pressCount = 0
    private var firstPressTime: Long = 0
    private var lastPressTime: Long = 0
    private val PRESS_WINDOW_MS = 3000L // 3 seconds window
    private val REQUIRED_PRESSES = 5
    private val DEBOUNCE_MS = 200L // Prevent double-counting

    override fun onServiceConnected() {
        super.onServiceConnected()
        val info = AccessibilityServiceInfo().apply {
            eventTypes = 0 // We don't need accessibility events, only key events
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
            notificationTimeout = 0
        }
        serviceInfo = info
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN &&
            event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {

            val now = System.currentTimeMillis()

            // Debounce
            if (lastPressTime > 0 && (now - lastPressTime) < DEBOUNCE_MS) {
                return false // Let the system handle it normally
            }
            lastPressTime = now

            if (firstPressTime == 0L) {
                firstPressTime = now
                pressCount = 1
                return false
            }

            val elapsed = now - firstPressTime

            if (elapsed <= PRESS_WINDOW_MS) {
                pressCount++
                if (pressCount >= REQUIRED_PRESSES) {
                    pressCount = 0
                    firstPressTime = 0
                    triggerSOS()
                }
            } else {
                // Reset window
                firstPressTime = now
                pressCount = 1
            }
        }

        return false // Don't consume the event, let volume still work
    }

    private fun triggerSOS() {
        // Send broadcast
        val sosIntent = Intent("com.sahay.VOLUME_BUTTON_SOS")
        sendBroadcast(sosIntent)

        // Use the bridge
        PowerButtonBridge.onSOSTriggered?.invoke("volume_button")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used — we only care about key events
    }

    override fun onInterrupt() {
        // Required override
    }
}
