import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class TwilioApiService {
  static final TwilioApiService _instance = TwilioApiService._internal();
  factory TwilioApiService() => _instance;
  TwilioApiService._internal();

  String get _accountSid => dotenv.env['TWILIO_ACCOUNT_SID'] ?? '';
  String get _authToken => dotenv.env['TWILIO_AUTH_TOKEN'] ?? '';
  String get _twilioNumber => dotenv.env['TWILIO_PHONE_NUMBER'] ?? '';

  /// Blast calls to all provided phone numbers
  Future<void> massCallContacts(
    List<String> phoneNumbers,
    String victimName,
  ) async {
    if (_accountSid.isEmpty || _authToken.isEmpty) {
      print(
        'âš ï¸ Twilio keys not configured in .env. Skipping emergency calls.',
      );
      return;
    }

    // TwiML payload to play when they answer
    final twiml =
        '''
      <Response>
        <Say voice="alice" loop="3">
          Emergency alert! Sahay SOS has been activated for $victimName. 
          They are in potential danger. Please check your text messages immediately for their exact live GPS location and evidence links. 
          Respond rapidly.
        </Say>
      </Response>
    ''';

    for (String number in phoneNumbers) {
      await _initiateCall(number, twiml);
    }
  }

  Future<void> _initiateCall(String to, String twiml) async {
    final url = Uri.parse(
      'https://api.twilio.com/2010-04-01/Accounts/$_accountSid/Calls.json',
    );
    final authHeader =
        'Basic ${base64Encode(utf8.encode('$_accountSid:$_authToken'))}';

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': authHeader,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {'To': to, 'From': _twilioNumber, 'Twiml': twiml},
      );

      if (response.statusCode == 201) {
        print('âœ… Twilio Call dispatched successfully to $to');
      } else {
        print('âŒ Twilio Call failed for $to: ${response.body}');
      }
    } catch (e) {
      print('âŒ Twilio HTTP Exception: $e');
    }
  }
}
