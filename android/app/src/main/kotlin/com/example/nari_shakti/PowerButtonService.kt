package com.example.nari_shakti

// Bridge to communicate SOS events from native services to Flutter
object PowerButtonBridge {
    var onSOSTriggered: ((String) -> Unit)? = null
}
