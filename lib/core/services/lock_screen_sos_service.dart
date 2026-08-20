// lib/core/services/lock_screen_sos_service.dart
//
// Uses the existing native Kotlin MethodChannel for notifications
// instead of flutter_local_notifications (which has AGP conflicts).
// Channel: com.narishakti.app/notifications — already set up in MainActivity.kt

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nari_shakti/main.dart';
import 'sos_service.dart';
import 'sos_countdown_service.dart';

class LockScreenSosService {
  static final LockScreenSosService _instance =
      LockScreenSosService._internal();
  factory LockScreenSosService() => _instance;
  LockScreenSosService._internal();

  static const MethodChannel _channel = MethodChannel(
    'com.narishakti.app/notifications',
  );

  bool _isShowing = false;
  bool get isShowing => _isShowing;

  // ── Init ───────────────────────────────────────────────────────────────────
  // Call once in main.dart after Firebase.initializeApp()
  Future<void> init() async {
    // Listen for SOS button tap and shake SOS sent back from native side
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSosNotificationTapped') {
        _onSosButtonTapped();
      } else if (call.method == 'onSosCountdownCancelled') {
        SosCountdownService().cancelCountdown();
      } else if (call.method == 'onShakeSosDetected') {
        _onNativeShakeDetected();
      }
    });
  }

  // ── Handle native shake SOS detection (from ShakeDetectionForegroundService) ──
  void _onNativeShakeDetected() {
    print(
      '🔔 Native shake SOS detected — Native UI already counted down 5s. Triggering immediate SOS background',
    );
    // The native Activity already provided a 5-second lock-screen countdown.
    // So we don't start the Dart countdown again, we trigger SOS background immediately!
    SosService().triggerSOSBackground('shake').then((_) {
      // Update persistent notification
      updateNotificationText(
        '🆘 SOS ACTIVE',
        'Recording in progress • Tap to open app',
      );

      // Navigate to the SOS Active screen directly since the timer is over
      final sosId = SosService().activeSosId;
      if (navigatorKey.currentState != null) {
        navigatorKey.currentState!.pushNamedAndRemoveUntil(
          '/sos_active',
          (route) => route.settings.name == '/home',
          arguments: <String, dynamic>{
            'sosId': sosId ?? '',
            'triggeredBy': 'shake',
          },
        );
      }
      bringAppToForeground();
    });
  }

  // ── Force the app to the foreground ─────────────────────────────────────────
  Future<void> bringAppToForeground() async {
    try {
      await _channel.invokeMethod('bringAppToForeground');
      print('App brought to foreground via native intent');
    } catch (e) {
      print('bringAppToForeground error: $e');
    }
  }

  // ── Show permanent lock screen notification ────────────────────────────────
  Future<void> showPermanentNotification() async {
    if (_isShowing) return;
    try {
      await _channel.invokeMethod('showSosNotification', {
        'title': 'Nari Shakti Active',
        'body': 'Shake or voice to trigger SOS • Tap button for instant SOS',
        'ongoing': true,
        'showSosButton': true,
      });
      _isShowing = true;
      print('Lock screen SOS notification shown');
    } catch (e) {
      print('showPermanentNotification error: $e');
    }
  }

  // ── Show countdown notification ──────────────────────────────────────────────
  Future<void> showCountdownNotification(int secondsLeft) async {
    try {
      await _channel.invokeMethod('showCountdownNotification', {
        'secondsLeft': secondsLeft,
        'showCancelButton': true,
      });
    } catch (e) {
      print('showCountdownNotification error: $e');
    }
  }

  // ── Update notification text ───────────────────────────────────────────────
  Future<void> updateNotificationText(String title, String body) async {
    try {
      await _channel.invokeMethod('showSosNotification', {
        'title': title,
        'body': body,
        'ongoing': true,
        'showSosButton': true,
      });
    } catch (e) {
      print('updateNotificationText error: $e');
    }
  }

  // ── Cancel countdown notification only (keeps persistent notification) ──────
  Future<void> cancelCountdownNotification() async {
    try {
      await _channel.invokeMethod('cancelCountdownNotification');
    } catch (e) {
      print('cancelCountdownNotification error: $e');
    }
  }

  // ── Dismiss ALL notifications (persistent + countdown) ─────────────────────
  Future<void> dismiss() async {
    try {
      await _channel.invokeMethod('cancelSosNotification');
      _isShowing = false;
      print('Lock screen SOS notification dismissed');
    } catch (e) {
      print('dismiss error: $e');
    }
  }

  // ── Launch the native full-screen SosCountdownActivity (over lock screen)
  Future<void> launchNativeCountdown(int seconds) async {
    try {
      await _channel.invokeMethod('launchNativeSosCountdown', {
        'seconds': seconds,
      });
    } catch (e) {
      print('launchNativeCountdown error: $e');
    }
  }

  // ── SOS button tapped ──────────────────────────────────────────────────────
  void _onSosButtonTapped() {
    SosService().triggerSOSBackground('lock_screen_button');

    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      Navigator.pushNamed(
        ctx,
        '/sos_active',
        arguments: <String, dynamic>{'triggeredBy': 'lock_screen_button'},
      );
    }
  }

  // ── Violent SOS Vibration ──────────────────────────────────────────────────
  Future<void> vibrateSOS() async {
    try {
      await _channel.invokeMethod('vibrateSOS');
    } catch (e) {
      print('vibrateSOS error: $e');
    }
  }

  // ── SOS Double Vibration ────────────────────────────────────────────────
  Future<void> vibrateSOSDouble() async {
    try {
      await _channel.invokeMethod('vibrateSOSDouble');
    } catch (e) {
      print('vibrateSOSDouble error: $e');
    }
  }

  // ── Warning Vibration ────────────────────────────────────────────────────
  Future<void> vibrateSOSWarning() async {
    try {
      await _channel.invokeMethod('vibrateSOSWarning');
    } catch (e) {
      print('vibrateSOSWarning error: $e');
    }
  }
}
