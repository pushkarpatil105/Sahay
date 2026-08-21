import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A normal Google Directions route used for turn-by-turn navigation.
class NavigationRoute {
  final List<LatLng> polylinePoints;
  final String distance;
  final String duration;
  final List<NavigationStep> steps;

  const NavigationRoute({
    required this.polylinePoints,
    required this.distance,
    required this.duration,
    required this.steps,
  });
}

class NavigationStep {
  final String instruction;
  final String distanceText;
  final int distanceMeters;
  final LatLng endLocation;

  const NavigationStep({
    required this.instruction,
    required this.distanceText,
    required this.distanceMeters,
    required this.endLocation,
  });
}
