import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteModel {
  final List<LatLng> polylinePoints;
  final String distance;
  final String duration;
  final String destinationName;
  final String destinationPlaceId;
  final List<NavigationStep> steps;

  RouteModel({
    required this.polylinePoints,
    required this.distance,
    required this.duration,
    required this.destinationName,
    required this.destinationPlaceId,
    this.steps = const [],
  });
}

class NavigationStep {
  final String instruction;
  final String distanceText;
  final int distanceMeters;
  final LatLng endLocation;

  NavigationStep({
    required this.instruction,
    required this.distanceText,
    required this.distanceMeters,
    required this.endLocation,
  });
}

class ScoreRoutesResponse {
  final bool success;
  final List<SafeRoute> routes;
  final ScoreRoutesMeta meta;

  ScoreRoutesResponse({
    required this.success,
    required this.routes,
    required this.meta,
  });

  factory ScoreRoutesResponse.fromJson(Map<String, dynamic> json) {
    return ScoreRoutesResponse(
      success: json['success'] == true,
      routes: ((json['routes'] as List?) ?? [])
          .map((route) => SafeRoute.fromJson(route as Map<String, dynamic>))
          .toList(),
      meta: ScoreRoutesMeta.fromJson(
        (json['meta'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
      ),
    );
  }
}

class SafeRoute {
  final String id;
  final int rank;
  final double riskProbability;
  final double safetyScore;
  final String riskBucket;
  final String explanation;
  final double distanceM;
  final int durationS;
  final String polylineEncoded;
  final double incidentDensity;
  final double redzoneOverlapScore;
  final double avgIncidentSeverity;
  final double temporalRiskScore;

  SafeRoute({
    required this.id,
    required this.rank,
    required this.riskProbability,
    required this.safetyScore,
    required this.riskBucket,
    required this.explanation,
    required this.distanceM,
    required this.durationS,
    required this.polylineEncoded,
    required this.incidentDensity,
    required this.redzoneOverlapScore,
    required this.avgIncidentSeverity,
    required this.temporalRiskScore,
  });

  factory SafeRoute.fromJson(Map<String, dynamic> json) {
    final riskFactors =
        (json['risk_factors'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    return SafeRoute(
      id: json['id']?.toString() ?? '',
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      riskProbability: (json['risk_probability'] as num?)?.toDouble() ?? 0,
      safetyScore: (json['safety_score'] as num?)?.toDouble() ?? 0,
      riskBucket: json['risk_bucket']?.toString() ?? 'UNKNOWN',
      explanation: json['explanation']?.toString() ?? '',
      distanceM: (json['distance_m'] as num?)?.toDouble() ?? 0,
      durationS: (json['duration_s'] as num?)?.toInt() ?? 0,
      polylineEncoded: json['polyline_encoded']?.toString() ?? '',
      incidentDensity:
          (riskFactors['incident_density'] as num?)?.toDouble() ??
          (json['incident_density'] as num?)?.toDouble() ??
          0,
      redzoneOverlapScore:
          (riskFactors['redzone_overlap_score'] as num?)?.toDouble() ??
          (json['redzone_overlap_score'] as num?)?.toDouble() ??
          0,
      avgIncidentSeverity:
          (riskFactors['avg_incident_severity'] as num?)?.toDouble() ??
          (json['avg_incident_severity'] as num?)?.toDouble() ??
          0,
      temporalRiskScore:
          (riskFactors['temporal_risk_score'] as num?)?.toDouble() ??
          (json['temporal_risk_score'] as num?)?.toDouble() ??
          0,
    );
  }

  double get distanceKm => distanceM / 1000.0;

  double get durationMin => durationS / 60.0;
}

class ScoreRoutesMeta {
  final double elapsedSeconds;
  final int routesScored;
  final String? modelVersion;
  final double? topScoresDiff;
  final String? error;

  ScoreRoutesMeta({
    required this.elapsedSeconds,
    required this.routesScored,
    this.modelVersion,
    this.topScoresDiff,
    this.error,
  });

  factory ScoreRoutesMeta.fromJson(Map<String, dynamic> json) {
    return ScoreRoutesMeta(
      elapsedSeconds: (json['elapsed_seconds'] as num?)?.toDouble() ?? 0,
      routesScored: (json['routes_scored'] as num?)?.toInt() ?? 0,
      modelVersion: json['model_version']?.toString(),
      topScoresDiff: (json['top_scores_diff'] as num?)?.toDouble(),
      error: json['error']?.toString(),
    );
  }
}
