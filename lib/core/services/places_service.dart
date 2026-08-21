import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:sahay/core/services/api_key_service.dart';

class PlaceLocation {
  final String description;
  final String placeId;
  final double latitude;
  final double longitude;

  const PlaceLocation({
    required this.description,
    required this.placeId,
    required this.latitude,
    required this.longitude,
  });
}

class PlacesService {
  static const _base =
      'https://maps.googleapis.com/maps/api/place/autocomplete/json';
  static const _detailsBase =
      'https://maps.googleapis.com/maps/api/place/details/json';

  Future<List<Map<String, String>>> getAutocomplete(String input) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    if (input.trim().isEmpty) return [];
    final url = Uri.parse(
      '$_base?input=${Uri.encodeComponent(input)}&key=$apiKey',
    );
    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final status = data['status'] as String?;
      if (status != null && status != 'OK' && status != 'ZERO_RESULTS') {
        return [];
      }
      final preds = (data['predictions'] as List?) ?? [];
      return preds.map<Map<String, String>>((p) {
        return {
          'description': p['description'] as String? ?? '',
          'place_id': p['place_id'] as String? ?? '',
        };
      }).toList();
    } catch (e) {
      return [];
    }
  }

  Future<PlaceLocation?> getPlaceDetails({
    required String placeId,
    required String description,
  }) async {
    if (placeId.trim().isEmpty) return null;

    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final url = Uri.parse(
      '$_detailsBase?place_id=${Uri.encodeComponent(placeId)}&fields=geometry,name,formatted_address&key=$apiKey',
    );

    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;

      final data = json.decode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return null;

      final result = data['result'] as Map<String, dynamic>?;
      final location =
          result?['geometry']?['location'] as Map<String, dynamic>?;
      final lat = (location?['lat'] as num?)?.toDouble();
      final lng = (location?['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;

      return PlaceLocation(
        description: result?['formatted_address']?.toString() ?? description,
        placeId: placeId,
        latitude: lat,
        longitude: lng,
      );
    } catch (e) {
      return null;
    }
  }
}



