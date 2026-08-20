import 'package:flutter/material.dart';
import 'package:nari_shakti/models/route_model.dart';

class RouteWithScore {
  // DEMO MODE - In production, this will be populated by the AI backend service.
  final SafeRoute route;
  final double score;
  final Color color;
  final String label;

  const RouteWithScore({
    required this.route,
    required this.score,
    required this.color,
    required this.label,
  });

  String get riskBucket {
    if (score >= 8.0) return 'SAFE';
    if (score >= 5.0) return 'MODERATE';
    return 'DANGEROUS';
  }

  String get explanation {
    return '$label: demo safety score based on route distance, public activity, nearby help points, and visibility factors.';
  }

  SafeRoute toSafeRoute({required int rank}) {
    return SafeRoute(
      id: route.id,
      rank: rank,
      riskProbability: (10.0 - score) / 10.0,
      safetyScore: score,
      riskBucket: riskBucket,
      explanation: explanation,
      distanceM: route.distanceM,
      durationS: route.durationS,
      polylineEncoded: route.polylineEncoded,
      incidentDensity: route.incidentDensity,
      redzoneOverlapScore: route.redzoneOverlapScore,
      avgIncidentSeverity: route.avgIncidentSeverity,
      temporalRiskScore: route.temporalRiskScore,
    );
  }
}
