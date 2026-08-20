import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiKeyService {
  /// Get the Google Places API key from environment
  static String getGooglePlacesApiKey() {
    final apiKey = dotenv.env['GOOGLE_PLACES_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception(
        '❌ GOOGLE_PLACES_API_KEY not found in .env file. '
        'Please check your .env file and ensure it contains the API key.',
      );
    }
    return apiKey;
  }
}
