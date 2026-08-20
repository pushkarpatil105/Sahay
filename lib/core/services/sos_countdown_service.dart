import 'dart:async';
import 'package:nari_shakti/core/services/sos_service.dart';
import 'package:nari_shakti/core/services/lock_screen_sos_service.dart';
import 'package:nari_shakti/core/services/ble_service.dart';
import 'package:nari_shakti/main.dart';

class SosCountdownService {
  static final SosCountdownService _instance = SosCountdownService._internal();
  factory SosCountdownService() => _instance;
  SosCountdownService._internal();

  Timer? _timer;
  int _secondsLeft = 10;
  bool _isCountingDown = false;

  bool get isCountingDown => _isCountingDown;

  void startCountdown(String triggeredBy) {
    if (_isCountingDown) return;
    _isCountingDown = true;
    _secondsLeft = 10;

    BleService().sendCommand('VIB_S');

    LockScreenSosService().showCountdownNotification(_secondsLeft);

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _secondsLeft--;

      if (_secondsLeft <= 0) {
        _cancelTimer();
        // Timer callback must be sync — run async work in a fire-and-forget IIFE
        () async {
          await SosService().triggerSOSBackground(triggeredBy);
          await BleService().sendCommand('VIB_L');
          await LockScreenSosService().updateNotificationText(
            '🆘 SOS ACTIVE',
            'Recording in progress • Tap to open app',
          );
          // Navigate to SOS active screen from background (no BuildContext needed)
          final sosId = SosService().activeSosId;
          navigatorKey.currentState?.pushNamedAndRemoveUntil(
            '/sos_active',
            (route) => route.settings.name == '/home',
            arguments: <String, dynamic>{
              'sosId': sosId ?? '',
              'triggeredBy': triggeredBy,
            },
          );

          await LockScreenSosService().bringAppToForeground();
        }();
      } else {
        LockScreenSosService().showCountdownNotification(_secondsLeft);
      }
    });
  }

  void cancelCountdown() {
    _cancelTimer();
    LockScreenSosService().cancelCountdownNotification();
    BleService().sendCommand('VIB_STOP');
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _isCountingDown = false;
  }
}
