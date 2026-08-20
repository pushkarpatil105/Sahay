import 'dart:async';
import 'twilio_api_service.dart';

class EscalationService {
  static final EscalationService _instance = EscalationService._internal();
  factory EscalationService() => _instance;
  EscalationService._internal();

  Timer? _escalationTimer;
  int _secondsRemaining = 30; // Wait time before Twilio blasts calls
  bool _isEscalationActive = false;

  final _streamController = StreamController<int>.broadcast();
  Stream<int> get countdownStream => _streamController.stream;

  void startSequence(List<dynamic> contacts, String userName) {
    if (_isEscalationActive) return;
    _isEscalationActive = true;
    _secondsRemaining = 30;
    _streamController.add(_secondsRemaining);

    _escalationTimer?.cancel();
    _escalationTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      _secondsRemaining--;
      _streamController.add(_secondsRemaining);

      if (_secondsRemaining <= 0) {
        timer.cancel();
        _isEscalationActive = false;
        
        // -----------------------------------------------------
        // ESCALATION THRESHOLD MET: BLAST EMERGENCY CALLS
        // -----------------------------------------------------
        final phoneNumbers = contacts.map((c) => c['phone'] as String).toList();
        await TwilioApiService().massCallContacts(phoneNumbers, userName);
      }
    });
  }

  void cancelSequence() {
    _escalationTimer?.cancel();
    _isEscalationActive = false;
    _secondsRemaining = 30;
    _streamController.add(_secondsRemaining);
  }
}
