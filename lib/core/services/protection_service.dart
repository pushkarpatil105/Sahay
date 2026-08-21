import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'lock_screen_sos_service.dart';
import 'sos_countdown_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sahay/main.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ProtectionTaskHandler());
}

/// Foreground task handler â€” only voice detection runs here.
/// Shake detection is handled by native ShakeDetectionForegroundService
/// which launches SosCountdownActivity over the lock screen.
class ProtectionTaskHandler extends TaskHandler {
  final SpeechToText _speech = SpeechToText();

  final List<String> _keywords = [
    'help',
    'help me',
    'bachao',
    'bachaoo',
    'bachao mujhe',
    'help please',
    'somebody help',
    'halp',
    'hellp',
    'bacchao',
    'pachao',
    'heelp',
  ];

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Shake detection removed â€” handled by native ShakeDetectionForegroundService
    await _startVoiceDetection();
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    if (!_speech.isListening) {
      await _startVoiceDetection();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _speech.stop();
  }

  Future<void> _startVoiceDetection() async {
    try {
      final available = await _speech.initialize(
        onError: (_) {},
        onStatus: (_) {},
      );
      if (!available) return;

      await _speech.listen(
        onResult: (result) {
          final words = result.recognizedWords.toLowerCase().trim();
          for (final keyword in _keywords) {
            if (words.contains(keyword)) {
              FlutterForegroundTask.sendDataToMain('voice_sos');
              break;
            }
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
        localeId: 'en_IN',
        cancelOnError: false,
        partialResults: true,
      );
    } catch (e) {}
  }
}

class ProtectionService {
  static final ProtectionService _instance = ProtectionService._internal();
  factory ProtectionService() => _instance;
  ProtectionService._internal();

  static bool _isRunning = false;

  /// MethodChannel to start/stop the native ShakeDetectionForegroundService
  static const MethodChannel _shakeChannel = MethodChannel(
    'com.sahay.app/shake_service',
  );

  /// MethodChannel for notifications (used to receive native shake SOS events)
  static const MethodChannel _notifChannel = MethodChannel(
    'com.sahay.app/notifications',
  );

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sahay_protection',
        channelName: 'Sahay Protection',
        channelDescription: 'Active protection service',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: true,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> start(BuildContext context) async {
    if (_isRunning) return;
    _isRunning = true;

    // Request SYSTEM_ALERT_WINDOW (Display over other apps)
    // This is REQUIRED on Android 10+ to launch the SosCountdownActivity from the background
    if (!await Permission.systemAlertWindow.isGranted) {
      await Permission.systemAlertWindow.request();

      // Check for Xiaomi / Redmi / POCO devices and redirect them to allow background popups
      bool isXiaomi = false;
      try {
        isXiaomi =
            await const MethodChannel(
              'com.sahay.app/notifications',
            ).invokeMethod('isXiaomiDevice') ??
            false;
      } catch (e) {
        print('Error checking Xiaomi device: $e');
      }

      if (isXiaomi && context.mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Xiaomi/Redmi Device Detected'),
            content: const Text(
              'To ensure the SOS Timer pops up instantly during an emergency, you MUST enable "Display pop-up windows while running in the background" on the next screen.\n\nPlease find the setting and allow it.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('Enable Permission'),
              ),
            ],
          ),
        );

        try {
          await const MethodChannel(
            'com.sahay.app/notifications',
          ).invokeMethod('requestXiaomiPopUpPermission');
        } catch (e) {
          print('Xiaomi redirect failed: $e');
        }
      }
    }

    // Check for Accessibility Service permission (for the 5x Volume Down Hardware Trigger)
    bool isAccessibilityEnabled = false;
    try {
      isAccessibilityEnabled =
          await const MethodChannel(
            'com.sahay.app/notifications',
          ).invokeMethod('isAccessibilityServiceEnabled') ??
          false;
    } catch (e) {
      print('Error checking accessibility service: $e');
    }

    if (!isAccessibilityEnabled && context.mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Enable Hardware SOS Trigger'),
          content: const Text(
            'To trigger SOS rapidly by pressing the Volume Down button 5 times, Sahay requires Accessibility permissions.\n\nOn the next screen, find "Sahay" under "Downloaded Apps" or "Installed Services" and turn it ON to allow hardware button detection.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );

      try {
        await const MethodChannel(
          'com.sahay.app/notifications',
        ).invokeMethod('requestAccessibilityPermission');
      } catch (e) {
        print('Accessibility redirect failed: $e');
      }
    }

    _initForegroundTask();

    // Listen for voice SOS events from the flutter_foreground_task handler
    // (Shake events are handled by native ShakeDetectionForegroundService)
    FlutterForegroundTask.addTaskDataCallback((data) {
      if (data == 'voice_sos') {
        final ctx = navigatorKey.currentContext;
        if (ctx != null) {
          SosCountdownService().startCountdown('voice');
        }
      }
    });

    // Start the flutter_foreground_task service (voice + shake in Dart)
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Sahay Active',
      notificationText: 'Shake & voice detection running',
      callback: startCallback,
    );

    // Start the NATIVE shake detection foreground service (works when locked)
    try {
      await _shakeChannel.invokeMethod('startShakeService');
      print('ðŸ”” Native ShakeDetectionForegroundService started');
    } catch (e) {
      print('Failed to start native shake service: $e');
    }

    // Set up handler for native shake SOS events
    _setupNativeShakeHandler();

    // Show persistent lock screen SOS notification
    await LockScreenSosService().showPermanentNotification();
  }

  /// Listen for native shake SOS events broadcast from ShakeDetectionForegroundService
  void _setupNativeShakeHandler() {
    // The notification channel already has a MethodCallHandler set by
    // LockScreenSosService.init(). We need to add our shake handler there.
    // Instead, we use the existing handler in LockScreenSosService which
    // now also handles 'onShakeSosDetected'.
    // See lock_screen_sos_service.dart init() method.
  }

  void _showMiuiPermissionDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFFFF5722)),
            SizedBox(width: 8),
            Text(
              'Enable Protection',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Color(0xFF1A1A1A),
              ),
            ),
          ],
        ),
        content: const Text(
          'To enable shake & voice SOS detection, please allow background activity:\n\n'
          '1. Go to Settings\n'
          '2. Apps > Sahay\n'
          '3. Battery saver â†’ No restrictions\n'
          '4. Also enable "Autostart"\n\n'
          'Then reopen the app.',
          style: TextStyle(color: Colors.black54, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later', style: TextStyle(color: Colors.black45)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await openAppSettings();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF5722),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
            child: const Text(
              'Open Settings',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> stop() async {
    // Stop the native shake service
    try {
      await _shakeChannel.invokeMethod('stopShakeService');
      print('ðŸ”” Native ShakeDetectionForegroundService stopped');
    } catch (e) {
      print('Failed to stop native shake service: $e');
    }

    await FlutterForegroundTask.stopService();
    await LockScreenSosService().dismiss();
    _isRunning = false;
  }

  bool get isRunning => _isRunning;
}
