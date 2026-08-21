import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sahay/core/services/ble_service.dart';
import 'package:sahay/core/services/sos_service.dart';

class SosCountdownScreen extends StatefulWidget {
  const SosCountdownScreen({super.key});

  @override
  State<SosCountdownScreen> createState() => _SosCountdownScreenState();
}

class _SosCountdownScreenState extends State<SosCountdownScreen> {
  static const int _initialSeconds = 10;

  Timer? _timer;
  int _secondsLeft = _initialSeconds;
  bool _isTriggering = false;
  String _triggeredBy = 'iot_button';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final incoming = (args?['triggeredBy'] as String?)?.trim();
    if (incoming != null && incoming.isNotEmpty) {
      _triggeredBy = incoming;
    }

    if (_timer == null) {
      _startCountdown();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    BleService().sendCommand('VIB_S');
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _isTriggering) return;

      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() {
          _secondsLeft = 0;
          _isTriggering = true;
        });
        await SosService().triggerSOS(context, _triggeredBy);
        return;
      }

      setState(() {
        _secondsLeft -= 1;
      });
    });
  }

  Future<void> _cancelCountdown() async {
    _timer?.cancel();
    await BleService().sendCommand('VIB_STOP');
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => !_isTriggering,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 24),
                const Text(
                  'SOS Countdown',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Triggered by: $_triggeredBy',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const Spacer(),
                Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.red, width: 6),
                    color: Colors.red.withOpacity(0.15),
                  ),
                  child: Center(
                    child: Text(
                      '$_secondsLeft',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 88,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  'SOS will be triggered automatically when timer reaches zero.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isTriggering ? null : _cancelCountdown,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Cancel SOS',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}



