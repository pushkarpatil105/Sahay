import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:nari_shakti/models/route_model.dart';
import 'package:nari_shakti/models/route_with_score.dart';

class DemoRouteScorer {
  // DEMO MODE - In production, this will call the AI backend service.
  static List<RouteWithScore> scoreRoutes(List<SafeRoute> rawRoutes) {
    final sorted = [...rawRoutes]
      ..sort((a, b) => a.distanceM.compareTo(b.distanceM));

    final dedupeResult = _dedupeOverlappingRoutes(sorted);
    final maxRoutes = dedupeResult.hadOverlap ? 2 : 3;
    final visibleRoutes = dedupeResult.routes.take(maxRoutes).toList();

    final demoScores = [8.4, 6.1, 2.9];
    final colors = [
      const Color(0xFF10B981),
      const Color(0xFFF59E0B),
      const Color(0xFFEF4444),
    ];
    final labels = ['Safest Route', 'Moderate Route', 'Risky Route'];

    return [
      for (var index = 0; index < visibleRoutes.length; index++)
        RouteWithScore(
          route: visibleRoutes[index],
          score: demoScores[_demoIndex(index, demoScores.length)],
          color: colors[_demoIndex(index, colors.length)],
          label: labels[_demoIndex(index, labels.length)],
        ),
    ];
  }

  static int _demoIndex(int index, int length) {
    if (index < length) return index;
    return length - 1;
  }

  // DEMO MODE - Keeps existing route screens working while showing judge-ready scores.
  static List<SafeRoute> scoreSafeRoutesForUi(List<SafeRoute> rawRoutes) {
    final scored = scoreRoutes(rawRoutes);
    return [
      for (var index = 0; index < scored.length; index++)
        scored[index].toSafeRoute(rank: index + 1),
    ];
  }

  static _DedupedRoutes _dedupeOverlappingRoutes(List<SafeRoute> routes) {
    final distinctRoutes = <SafeRoute>[];
    final fingerprints = <_RouteFingerprint>[];
    var hadOverlap = false;

    for (final route in routes) {
      final fingerprint = _RouteFingerprint.fromRoute(route);
      final hasOverlap = fingerprints.any(
        (existing) => fingerprint.overlapsWith(existing),
      );

      if (hasOverlap) {
        hadOverlap = true;
      }

      if (!hasOverlap) {
        distinctRoutes.add(route);
        fingerprints.add(fingerprint);
      }
    }

    return _DedupedRoutes(routes: distinctRoutes, hadOverlap: hadOverlap);
  }
}

class _DedupedRoutes {
  final List<SafeRoute> routes;
  final bool hadOverlap;

  const _DedupedRoutes({required this.routes, required this.hadOverlap});
}

class _RouteFingerprint {
  static const double _cellPrecision = 3;
  static const double _duplicateOverlapThreshold = 0.6;

  final Set<String> cells;

  const _RouteFingerprint(this.cells);

  factory _RouteFingerprint.fromRoute(SafeRoute route) {
    final cells = <String>{};

    try {
      final decoded = PolylinePoints.decodePolyline(route.polylineEncoded);
      if (decoded.isNotEmpty) {
        final samples = _samplePoints(decoded);
        for (final point in samples) {
          cells.add(
            '${_quantize(point.latitude, _cellPrecision)},${_quantize(point.longitude, _cellPrecision)}',
          );
        }
      }
    } catch (_) {
      // Fallback to a coarse signature if the polyline cannot be decoded.
      cells.add('distance:${(route.distanceM / 250).round()}');
      cells.add('duration:${(route.durationS / 120).round()}');
    }

    if (cells.isEmpty) {
      cells.add('route:${route.id}');
    }

    return _RouteFingerprint(cells);
  }

  bool overlapsWith(_RouteFingerprint other) {
    if (cells.isEmpty || other.cells.isEmpty) return false;

    final intersectionSize = cells.intersection(other.cells).length;
    final smallerSize = math.min(cells.length, other.cells.length);
    final unionSize = cells.union(other.cells).length;

    if (smallerSize == 0 || unionSize == 0) return false;

    final overlapRatio = intersectionSize / smallerSize;
    final jaccardSimilarity = intersectionSize / unionSize;

    return overlapRatio >= _duplicateOverlapThreshold ||
        jaccardSimilarity >= 0.5;
  }

  static List<PointLatLng> _samplePoints(List<PointLatLng> decoded) {
    if (decoded.length <= 6) {
      return decoded;
    }

    final samples = <PointLatLng>{
      decoded.first,
      decoded[decoded.length ~/ 2],
      decoded.last,
    };

    final step = (decoded.length / 8).ceil().clamp(1, decoded.length - 1);
    for (var index = 0; index < decoded.length; index += step) {
      samples.add(decoded[index]);
    }

    return samples.toList();
  }

  static double _quantize(double value, double precision) {
    final factor = math.pow(10, precision).toDouble();
    return (value * factor).round() / factor;
  }
}
