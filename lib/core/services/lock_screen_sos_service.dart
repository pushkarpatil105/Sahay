// lib/core/services/lock_screen_sos_service.dart
//
// Uses the existing native Kotlin MethodChannel for notifications
// instead of flutter_local_notifications (which has AGP conflicts).
// Channel: com.sahay.app/notifications â€” already set up in MainActivity.kt

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sahay/main.dart';
import 'sos_service.dart';
import 'sos_countdown_service.dart';

class LockScreenSosService {
  static final LockScreenSosService _instance =
      LockScreenSosService._internal();
  factory LockScreenSosService() => _instance;
  LockScreenSosService._internal();

  static const MethodChannel _channel = MethodChannel(
    'com.sahay.app/notifications',
  );

  bool _isShowing = false;
  bool get isShowing => _isShowing;

  // â”€â”€ Init â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

  // â”€â”€ Handle native shake SOS detection (from ShakeDetectionForegroundService) â”€â”€
  void _onNativeShakeDetected() {
    print(
      'ðŸ”” Native shake SOS detected â€” Native UI already counted down 5s. Triggering immediate SOS background',
    );
    // The native Activity already provided a 5-second lock-screen countdown.
    // So we don't start the Dart countdown again, we trigger SOS background immediately!
    SosService().triggerSOSBackground('shake').then((_) {
      // Update persistent notification
      updateNotificationText(
        'ðŸ†˜ SOS ACTIVE',
        'Recording in progress â€¢ Tap to open app',
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

  // â”€â”€ Force the app to the foreground â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> bringAppToForeground() async {
    try {
      await _channel.invokeMethod('bringAppToForeground');
      print('App brought to foreground via native intent');
    } catch (e) {
      print('bringAppToForeground error: $e');
    }
  }

  // â”€â”€ Show permanent lock screen notification â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> showPermanentNotification() async {
    if (_isShowing) return;
    try {
      await _channel.invokeMethod('showSosNotification', {
        'title': 'Sahay Active',
        'body': 'Shake or voice to trigger SOS â€¢ Tap button for instant SOS',
        'ongoing': true,
        'showSosButton': true,
      });
      _isShowing = true;
      print('Lock screen SOS notification shown');
    } catch (e) {
      print('showPermanentNotification error: $e');
    }
  }

  // â”€â”€ Show countdown notification â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

  // â”€â”€ Update notification text â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

  // â”€â”€ Cancel countdown notification only (keeps persistent notification) â”€â”€â”€â”€â”€â”€
  Future<void> cancelCountdownNotification() async {
    try {
      await _channel.invokeMethod('cancelCountdownNotification');
    } catch (e) {
      print('cancelCountdownNotification error: $e');
    }
  }

  // â”€â”€ Dismiss ALL notifications (persistent + countdown) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> dismiss() async {
    try {
      await _channel.invokeMethod('cancelSosNotification');
      _isShowing = false;
      print('Lock screen SOS notification dismissed');
    } catch (e) {
      print('dismiss error: $e');
    }
  }

  // â”€â”€ Launch the native full-screen SosCountdownActivity (over lock screen)
  Future<void> launchNativeCountdown(int seconds) async {
    try {
      await _channel.invokeMethod('launchNativeSosCountdown', {
        'seconds': seconds,
      });
    } catch (e) {
      print('launchNativeCountdown error: $e');
    }
  }

  // â”€â”€ SOS button tapped â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

  // â”€â”€ Violent SOS Vibration â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> vibrateSOS() async {
    try {
      await _channel.invokeMethod('vibrateSOS');
    } catch (e) {
      print('vibrateSOS error: $e');
    }
  }

  // â”€â”€ SOS Double Vibration â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> vibrateSOSDouble() async {
    try {
      await _channel.invokeMethod('vibrateSOSDouble');
    } catch (e) {
      print('vibrateSOSDouble error: $e');
    }
  }

  // â”€â”€ Warning Vibration â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> vibrateSOSWarning() async {
    try {
      await _channel.invokeMethod('vibrateSOSWarning');
    } catch (e) {
      print('vibrateSOSWarning error: $e');
    }
  }
}
