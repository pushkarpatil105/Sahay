import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:nari_shakti/models/route_model.dart';
import 'package:nari_shakti/core/services/api_key_service.dart';

class DirectionsService {
  static const _base = 'https://maps.googleapis.com/maps/api/directions/json';

  Future<RouteModel?> getRoute(
    LatLng origin,
    String destinationPlaceId,
    String destinationName,
  ) async {
    // ApiKeyService currently exposes Places API key; use it for Directions too
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final originParam = '${origin.latitude},${origin.longitude}';
    final destParam = 'place_id:$destinationPlaceId';
    final url = Uri.parse(
      '$_base?origin=$originParam&destination=$destParam&key=$apiKey&mode=driving',
    );
    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final routes = (data['routes'] as List?) ?? [];
      if (routes.isEmpty) return null;
      final first = routes.first as Map<String, dynamic>;
      final overview = first['overview_polyline']?['points'] as String?;
      final legs = (first['legs'] as List?) ?? [];
      String distance = '';
      String duration = '';
      if (legs.isNotEmpty) {
        final leg = legs.first as Map<String, dynamic>;
        distance = leg['distance']?['text'] as String? ?? '';
        duration = leg['duration']?['text'] as String? ?? '';
      }

      final polylinePoints = <LatLng>[];
      if (overview != null && overview.isNotEmpty) {
        // Decode using the package static API (one positional argument).
        final decoded = PolylinePoints.decodePolyline(overview);
        for (final p in decoded) {
          polylinePoints.add(LatLng(p.latitude, p.longitude));
        }
      }

      return RouteModel(
        polylinePoints: polylinePoints,
        distance: distance,
        duration: duration,
        destinationName: destinationName,
        destinationPlaceId: destinationPlaceId,
      );
    } catch (e) {
      return null;
    }
  }

  Future<RouteModel?> getRouteBetweenCoords(
    LatLng origin,
    LatLng destination,
  ) async {
    final apiKey = ApiKeyService.getGooglePlacesApiKey();
    final originParam = '${origin.latitude},${origin.longitude}';
    final destParam = '${destination.latitude},${destination.longitude}';
    final url = Uri.parse(
      '$_base?origin=$originParam&destination=$destParam&key=$apiKey&mode=driving',
    );

    try {
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final routes = (data['routes'] as List?) ?? [];
      if (routes.isEmpty) return null;
      final first = routes.first as Map<String, dynamic>;
      final overview = first['overview_polyline']?['points'] as String?;
      final legs = (first['legs'] as List?) ?? [];
      String distance = '';
      String duration = '';
      List<NavigationStep> steps = [];
      if (legs.isNotEmpty) {
        final leg = legs.first as Map<String, dynamic>;
        distance = leg['distance']?['text'] as String? ?? '';
        duration = leg['duration']?['text'] as String? ?? '';

        final rawSteps = (leg['steps'] as List?) ?? [];
        for (final s in rawSteps) {
          final step = s as Map<String, dynamic>;
          final instr = (step['html_instructions'] as String?) ?? '';
          final stripped = instr.replaceAll(RegExp(r'<[^>]*>'), '');
          final distText = (step['distance']?['text'] as String?) ?? '';
          final distVal = (step['distance']?['value'] as num?)?.toInt() ?? 0;
          final endLoc = step['end_location'] as Map<String, dynamic>?;
          final lat = (endLoc?['lat'] as num?)?.toDouble() ?? 0.0;
          final lng = (endLoc?['lng'] as num?)?.toDouble() ?? 0.0;
          steps.add(
            NavigationStep(
              instruction: stripped,
              distanceText: distText,
              distanceMeters: distVal,
              endLocation: LatLng(lat, lng),
            ),
          );
        }
      }

      final polylinePoints = <LatLng>[];
      if (overview != null && overview.isNotEmpty) {
        final decoded = PolylinePoints.decodePolyline(overview);
        for (final p in decoded) {
          polylinePoints.add(LatLng(p.latitude, p.longitude));
        }
      }

      return RouteModel(
        polylinePoints: polylinePoints,
        distance: distance,
        duration: duration,
        destinationName: destination.toString(),
        destinationPlaceId: '',
        steps: steps,
      );
    } catch (e) {
      return null;
    }
  }
}
