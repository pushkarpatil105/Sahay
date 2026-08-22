import 'dart:convert';
import 'dart:math' as math;
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

class HospitalPlace {
  const HospitalPlace({
    required this.placeId,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.distanceMeters,
    this.rating,
    this.ratingCount,
    this.phoneNumber,
    this.photoUrl,
  });

  final String placeId;
  final String name;
  final double latitude;
  final double longitude;
  final String address;
  final double distanceMeters;
  final double? rating;
  final int? ratingCount;
  final String? phoneNumber;
  final String? photoUrl;

  HospitalPlace copyWith({
    String? address,
    double? rating,
    int? ratingCount,
    String? phoneNumber,
    String? photoUrl,
  }) {
    return HospitalPlace(
      placeId: placeId,
      name: name,
      latitude: latitude,
      longitude: longitude,
      address: address ?? this.address,
      distanceMeters: distanceMeters,
      rating: rating ?? this.rating,
      ratingCount: ratingCount ?? this.ratingCount,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      photoUrl: photoUrl ?? this.photoUrl,
    );
  }
}

class PolicePlace {
  const PolicePlace({required this.placeId, required this.name, required this.latitude, required this.longitude, required this.address, required this.distanceMeters, this.phoneNumber});
  final String placeId;
  final String name;
  final double latitude;
  final double longitude;
  final String address;
  final double distanceMeters;
  final String? phoneNumber;

  PolicePlace copyWith({String? address, String? phoneNumber}) => PolicePlace(
    placeId: placeId, name: name, latitude: latitude, longitude: longitude,
    address: address ?? this.address, distanceMeters: distanceMeters,
    phoneNumber: phoneNumber ?? this.phoneNumber,
  );
}

class NearbyServicePlace {
  const NearbyServicePlace({required this.placeId, required this.name, required this.latitude, required this.longitude, required this.address, required this.distanceMeters, this.phoneNumber});
  final String placeId;
  final String name;
  final double latitude;
  final double longitude;
  final String address;
  final double distanceMeters;
  final String? phoneNumber;
  NearbyServicePlace copyWith({String? address, String? phoneNumber}) => NearbyServicePlace(placeId: placeId, name: name, latitude: latitude, longitude: longitude, address: address ?? this.address, distanceMeters: distanceMeters, phoneNumber: phoneNumber ?? this.phoneNumber);
}

class PlacesService {
  static const _base =
      'https://maps.googleapis.com/maps/api/place/autocomplete/json';
  static const _detailsBase =
      'https://maps.googleapis.com/maps/api/place/details/json';
  static const _nearbyBase =
      'https://maps.googleapis.com/maps/api/place/nearbysearch/json';
  static const _textSearchBase =
      'https://maps.googleapis.com/maps/api/place/textsearch/json';

  Future<List<HospitalPlace>> getNearbyHospitals({
    required double latitude,
    required double longitude,
  }) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final url = Uri.parse(
      '$_nearbyBase?location=$latitude,$longitude&type=hospital&rankby=distance&key=$apiKey',
    );
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') return [];

      final results = (data['results'] as List?) ?? [];
      final hospitals = <HospitalPlace>[];
      for (final result in results) {
        final place = result as Map<String, dynamic>;
        final location = place['geometry']?['location'] as Map<String, dynamic>?;
        final lat = (location?['lat'] as num?)?.toDouble();
        final lng = (location?['lng'] as num?)?.toDouble();
        final placeId = place['place_id']?.toString();
        if (lat == null || lng == null || placeId == null) continue;

        final photos = place['photos'] as List?;
        final photoReference = photos?.isNotEmpty == true
            ? (photos!.first as Map<String, dynamic>)['photo_reference']?.toString()
            : null;
        hospitals.add(
          HospitalPlace(
            placeId: placeId,
            name: place['name']?.toString() ?? 'Hospital',
            latitude: lat,
            longitude: lng,
            address: place['vicinity']?.toString() ?? 'Address unavailable',
            distanceMeters: _distanceMeters(latitude, longitude, lat, lng),
            rating: (place['rating'] as num?)?.toDouble(),
            ratingCount: (place['user_ratings_total'] as num?)?.toInt(),
            photoUrl: photoReference == null
                ? null
                : _photoUrl(photoReference, apiKey),
          ),
        );
      }
      hospitals.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      return hospitals;
    } catch (_) {
      return [];
    }
  }

  Future<List<PolicePlace>> getNearbyPoliceStations({
    required double latitude,
    required double longitude,
  }) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final url = Uri.parse('$_nearbyBase?location=$latitude,$longitude&type=police&rankby=distance&key=$apiKey');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') return [];
      final stations = <PolicePlace>[];
      for (final value in (data['results'] as List?) ?? []) {
        final place = value as Map<String, dynamic>;
        final location = place['geometry']?['location'] as Map<String, dynamic>?;
        final lat = (location?['lat'] as num?)?.toDouble();
        final lng = (location?['lng'] as num?)?.toDouble();
        final id = place['place_id']?.toString();
        if (lat == null || lng == null || id == null) continue;
        stations.add(PolicePlace(
          placeId: id, name: place['name']?.toString() ?? 'Police Station',
          latitude: lat, longitude: lng,
          address: place['vicinity']?.toString() ?? 'Address unavailable',
          distanceMeters: _distanceMeters(latitude, longitude, lat, lng),
        ));
      }
      stations.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      return stations;
    } catch (_) { return []; }
  }

  Future<List<NearbyServicePlace>> getNearbyServices({
    required double latitude,
    required double longitude,
    required String type,
    String? keyword,
  }) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final keywordPart = keyword == null ? '' : '&keyword=${Uri.encodeComponent(keyword)}';
    final url = Uri.parse('$_nearbyBase?location=$latitude,$longitude&type=$type&rankby=distance$keywordPart&key=$apiKey');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') return [];
      final places = <NearbyServicePlace>[];
      for (final value in (data['results'] as List?) ?? []) {
        final place = value as Map<String, dynamic>;
        final location = place['geometry']?['location'] as Map<String, dynamic>?;
        final lat = (location?['lat'] as num?)?.toDouble();
        final lng = (location?['lng'] as num?)?.toDouble();
        final id = place['place_id']?.toString();
        if (lat == null || lng == null || id == null) continue;
        places.add(NearbyServicePlace(placeId: id, name: place['name']?.toString() ?? 'Service location', latitude: lat, longitude: lng, address: place['vicinity']?.toString() ?? 'Address unavailable', distanceMeters: _distanceMeters(latitude, longitude, lat, lng)));
      }
      places.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      return places;
    } catch (_) { return []; }
  }

  /// Toll plazas do not have a dedicated Places type. Text Search is used so
  /// the map returns Google's toll-plaza results instead of an unrelated POI.
  Future<List<NearbyServicePlace>> getNearbyTollPlazas({
    required double latitude,
    required double longitude,
  }) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final query = Uri.encodeComponent('toll plaza near $latitude,$longitude');
    final url = Uri.parse('$_textSearchBase?query=$query&key=$apiKey');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') return [];
      final tolls = <NearbyServicePlace>[];
      for (final value in (data['results'] as List?) ?? []) {
        final place = value as Map<String, dynamic>;
        final location = place['geometry']?['location'] as Map<String, dynamic>?;
        final lat = (location?['lat'] as num?)?.toDouble();
        final lng = (location?['lng'] as num?)?.toDouble();
        final id = place['place_id']?.toString();
        if (lat == null || lng == null || id == null) continue;
        tolls.add(NearbyServicePlace(
          placeId: id,
          name: place['name']?.toString() ?? 'Toll plaza',
          latitude: lat,
          longitude: lng,
          address: place['formatted_address']?.toString() ??
              place['vicinity']?.toString() ??
              'Address unavailable',
          distanceMeters: _distanceMeters(latitude, longitude, lat, lng),
        ));
      }
      tolls.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      return tolls;
    } catch (_) {
      return [];
    }
  }

  Future<HospitalPlace> getHospitalDetails(HospitalPlace hospital) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final url = Uri.parse(
      '$_detailsBase?place_id=${Uri.encodeComponent(hospital.placeId)}&fields=name,formatted_address,formatted_phone_number,international_phone_number,rating,user_ratings_total,photos&key=$apiKey',
    );
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return hospital;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final result = data['result'] as Map<String, dynamic>?;
      if (data['status'] != 'OK' || result == null) return hospital;
      final photos = result['photos'] as List?;
      final photoReference = photos?.isNotEmpty == true
          ? (photos!.first as Map<String, dynamic>)['photo_reference']?.toString()
          : null;
      return hospital.copyWith(
        address: result['formatted_address']?.toString(),
        phoneNumber:
            result['international_phone_number']?.toString() ??
            result['formatted_phone_number']?.toString(),
        rating: (result['rating'] as num?)?.toDouble(),
        ratingCount: (result['user_ratings_total'] as num?)?.toInt(),
        photoUrl: photoReference == null ? null : _photoUrl(photoReference, apiKey),
      );
    } catch (_) {
      return hospital;
    }
  }

  Future<PolicePlace> getPoliceStationDetails(PolicePlace station) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final url = Uri.parse('$_detailsBase?place_id=${Uri.encodeComponent(station.placeId)}&fields=formatted_address,formatted_phone_number,international_phone_number&key=$apiKey');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return station;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final result = data['result'] as Map<String, dynamic>?;
      if (data['status'] != 'OK' || result == null) return station;
      return station.copyWith(address: result['formatted_address']?.toString(), phoneNumber: result['international_phone_number']?.toString() ?? result['formatted_phone_number']?.toString());
    } catch (_) { return station; }
  }

  Future<NearbyServicePlace> getServiceDetails(NearbyServicePlace place) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final url = Uri.parse('$_detailsBase?place_id=${Uri.encodeComponent(place.placeId)}&fields=formatted_address,formatted_phone_number,international_phone_number&key=$apiKey');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return place;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final result = data['result'] as Map<String, dynamic>?;
      if (data['status'] != 'OK' || result == null) return place;
      return place.copyWith(address: result['formatted_address']?.toString(), phoneNumber: result['international_phone_number']?.toString() ?? result['formatted_phone_number']?.toString());
    } catch (_) { return place; }
  }

  static String _photoUrl(String photoReference, String apiKey) =>
      'https://maps.googleapis.com/maps/api/place/photo?maxwidth=600&photo_reference=${Uri.encodeComponent(photoReference)}&key=$apiKey';

  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    const earthRadius = 6371000.0;
    final latDelta = _toRadians(latitude2 - latitude1);
    final lngDelta = _toRadians(longitude2 - longitude1);
    final a =
        math.sin(latDelta / 2) * math.sin(latDelta / 2) +
        math.cos(_toRadians(latitude1)) *
            math.cos(_toRadians(latitude2)) *
            math.sin(lngDelta / 2) *
            math.sin(lngDelta / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _toRadians(double degrees) => degrees * 3.141592653589793 / 180;

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



