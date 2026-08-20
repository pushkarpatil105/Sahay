import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'sos_service.dart';

class VoiceDetectionService {
  static final VoiceDetectionService _instance =
      VoiceDetectionService._internal();
  factory VoiceDetectionService() => _instance;
  VoiceDetectionService._internal();

  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
  bool _isEnabled = false;
  bool _isInitialized = false;
  Timer? _restartTimer;
  BuildContext? _context;

  // Keywords to detect
  final List<String> _keywords = [
    'help',
    'help me',
    'bachao',
    'bachaoo',
    'bachao mujhe',
    'help please',
    'somebody help',
  ];

  bool get isListening => _isListening;
  bool get isEnabled => _isEnabled;

  Future<bool> initialize() async {
    if (_isInitialized) return true;
    try {
      _isInitialized = await _speech.initialize(
        onError: (error) {
          _isListening = false;
          if (_isEnabled) _scheduleRestart();
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _isListening = false;
            if (_isEnabled) _scheduleRestart();
          }
        },
      );
      return _isInitialized;
    } catch (e) {
      return false;
    }
  }

  Future<void> enable(BuildContext context) async {
    _context = context;
    _isEnabled = true;
    final initialized = await initialize();
    if (initialized) {
      await _startListening();
    }
  }

  Future<void> disable() async {
    _isEnabled = false;
    _restartTimer?.cancel();
    if (_isListening) {
      await _speech.stop();
      _isListening = false;
    }
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(seconds: 2), () {
      if (_isEnabled && !_isListening) {
        _startListening();
      }
    });
  }

  Future<void> _startListening() async {
    if (_isListening || !_isEnabled || !_isInitialized) return;
    try {
      _isListening = true;
      await _speech.listen(
        onResult: (result) {
          final words = result.recognizedWords.toLowerCase().trim();
          if (words.isNotEmpty) {
            _checkForKeywords(words);
          }
        },
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 5),
        localeId: 'en_IN',
        cancelOnError: false,
        partialResults: true,
      );
    } catch (e) {
      _isListening = false;
      _scheduleRestart();
    }
  }

  void _checkForKeywords(String words) {
    for (final keyword in _keywords) {
      if (words.contains(keyword)) {
        _triggerSOS();
        break;
      }
    }
  }

  void _triggerSOS() {
    if (_context != null && _context!.mounted) {
      disable();
      SosService().triggerSOS(_context!, 'voice');
    }
  }

  void updateContext(BuildContext context) {
    _context = context;
  }
}