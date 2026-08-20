import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'sos_service.dart';

class ShakeDetectionService {
  static final ShakeDetectionService _instance =
      ShakeDetectionService._internal();
  factory ShakeDetectionService() => _instance;
  ShakeDetectionService._internal();

  StreamSubscription? _subscription;
  BuildContext? _context;

  // Shake detection config
  static const int _shakeCountThreshold = 5;
  static const double _shakeThreshold = 15.0;
  static const int _shakeWindowMs = 3000; // 5 shakes within 3 seconds

  int _shakeCount = 0;
  DateTime? _firstShakeTime;
  DateTime? _lastShakeTime;
  bool _isActive = false;

  void start(BuildContext context) {
    if (_isActive) return;
    _context = context;
    _isActive = true;
    _shakeCount = 0;
    _firstShakeTime = null;

    _subscription = accelerometerEventStream().listen((event) {
      _onAccelerometerEvent(event);
    });
  }

  void stop() {
    _isActive = false;
    _subscription?.cancel();
    _subscription = null;
    _shakeCount = 0;
    _firstShakeTime = null;
  }

  void updateContext(BuildContext context) {
    _context = context;
  }

  void _onAccelerometerEvent(AccelerometerEvent event) {
    final magnitude = sqrt(
      event.x * event.x +
      event.y * event.y +
      event.z * event.z,
    );

    // Subtract gravity (~9.8)
    final acceleration = (magnitude - 9.8).abs();

    if (acceleration > _shakeThreshold) {
      final now = DateTime.now();

      // Prevent double counting same shake
      if (_lastShakeTime != null &&
          now.difference(_lastShakeTime!).inMilliseconds < 300) {
        return;
      }

      _lastShakeTime = now;

      // Start window on first shake
      if (_firstShakeTime == null) {
        _firstShakeTime = now;
        _shakeCount = 1;
        return;
      }

      // Check if within time window
      final elapsed =
          now.difference(_firstShakeTime!).inMilliseconds;

      if (elapsed <= _shakeWindowMs) {
        _shakeCount++;

        if (_shakeCount >= _shakeCountThreshold) {
          _shakeCount = 0;
          _firstShakeTime = null;
          _triggerSOS();
        }
      } else {
        // Reset window
        _firstShakeTime = now;
        _shakeCount = 1;
      }
    }
  }

  void _triggerSOS() {
    if (_context != null && _context!.mounted) {
      stop();
      if (_context != null && _context!.mounted) {
        SosService().triggerSOS(_context!, 'shake');}
    }
  }
}