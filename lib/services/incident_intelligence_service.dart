/// Incident Intelligence Service
/// Fetches and manages real-time crime incident data for route analysis
/// Integrates with backend Incident Intelligence engine

import 'dart:async';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/incident_data_model.dart';
import '../models/route_model.dart';

/// Service for managing incident intelligence data
class IncidentIntelligenceService {
  static const String _logTag = '[IncidentIntelligenceService]';

  /// Cache of incident analytics per route
  final Map<String, IncidentAnalytics> _analyticsCache = {};

  /// Cache of incident reports
  final Map<String, List<IncidentReport>> _reportsCache = {};

  /// Cache validity duration
  static const Duration _cacheValidity = Duration(minutes: 15);

  /// Last update time per route
  final Map<String, DateTime> _lastUpdateTime = {};

  /// Singleton instance
  static final IncidentIntelligenceService _instance =
      IncidentIntelligenceService._internal();

  IncidentIntelligenceService._internal();

  factory IncidentIntelligenceService() {
    return _instance;
  }

  /// Extract incident analytics from a scored route
  IncidentAnalytics? extractIncidentAnalytics(SafeRoute route) {
    try {
      return IncidentAnalytics.fromRoute({
        'crimeometer_incident_count':
            route.extraData?['crimeometer_incident_count'] ?? 0,
        'incident_density': route.incidentDensity,
        'crimeometer_max_csi': route.extraData?['crimeometer_max_csi'] ?? 0,
        'crimeometer_avg_csi': route.extraData?['crimeometer_avg_csi'] ?? 0,
        'redzone_overlap_score': route.redzoneOverlapScore,
        'avg_incident_severity': route.avgIncidentSeverity,
        'temporal_risk_score': route.temporalRiskScore,
        'crimeometer_query_points':
            route.extraData?['crimeometer_query_points'] ?? 0,
      });
    } catch (e) {
      print('$_logTag Error extracting incident analytics: $e');
      return null;
    }
  }

  /// Get cached analytics for route
  IncidentAnalytics? getCachedAnalytics(String routeId) {
    final cached = _analyticsCache[routeId];
    final lastUpdate = _lastUpdateTime[routeId];

    if (cached != null && lastUpdate != null) {
      if (DateTime.now().difference(lastUpdate) < _cacheValidity) {
        print('$_logTag Returning cached analytics for route $routeId');
        return cached;
      }
    }
    return null;
  }

  /// Cache analytics for route
  void cacheAnalytics(String routeId, IncidentAnalytics analytics) {
    _analyticsCache[routeId] = analytics;
    _lastUpdateTime[routeId] = DateTime.now();
    print('$_logTag Cached incident analytics for route $routeId');
  }

  /// Get detailed incident reports for a route
  /// In production, this would fetch from backend
  /// For now, returns generated data for demo
  Future<List<IncidentReport>> fetchRouteIncidents(
    String routeId, {
    int limit = 10,
  }) async {
    try {
      // Check cache first
      if (_reportsCache.containsKey(routeId)) {
        return _reportsCache[routeId]!;
      }

      print('$_logTag Fetching incident reports for route $routeId');

      // Simulate API call with delay
      await Future.delayed(const Duration(milliseconds: 500));

      // Return empty list (real data would come from backend)
      // Backend provides this via the incident feature engine
      _reportsCache[routeId] = [];

      return [];
    } catch (e) {
      print('$_logTag Error fetching incidents: $e');
      return [];
    }
  }

  /// Get incident hotspots (clusters) along a route
  Future<List<IncidentCluster>> fetchIncidentHotspots(
    List<LatLng> routePoints, {
    double radiusMeters = 500,
  }) async {
    try {
      print(
        '$_logTag Analyzing ${routePoints.length} route points for incident clusters',
      );

      // In a full implementation, this would:
      // 1. Query backend for incidents along corridor
      // 2. Perform geospatial clustering
      // 3. Return cluster hotspots

      // For now, return empty list (backend clusters incidents automatically)
      return [];
    } catch (e) {
      print('$_logTag Error fetching hotspots: $e');
      return [];
    }
  }

  /// Clear all caches
  void clearCache() {
    _analyticsCache.clear();
    _reportsCache.clear();
    _lastUpdateTime.clear();
    print('$_logTag Cache cleared');
  }

  /// Get statistics across all cached routes
  Map<String, dynamic> getCacheStats() {
    return {
      'cached_routes': _analyticsCache.length,
      'total_cached_incidents': _reportsCache.values.fold(
        0,
        (sum, list) => sum + list.length,
      ),
      'cache_size': _analyticsCache.length + _reportsCache.length,
    };
  }
}

/// Extension to SafeRoute for incident data
extension IncidentDataExtension on SafeRoute {
  /// Get extracted incident analytics
  IncidentAnalytics? getIncidentAnalytics() {
    return IncidentIntelligenceService().extractIncidentAnalytics(this);
  }

  /// Get description of incident factors
  String getIncidentFactorsDescription() {
    final List<String> factors = [];

    if (incidentDensity > 3.0) {
      factors.add('High incident density');
    } else if (incidentDensity > 1.0) {
      factors.add('Moderate incident density');
    }

    if (redzoneOverlapScore > 0.5) {
      factors.add(
        '${(redzoneOverlapScore * 100).toStringAsFixed(0)}% redzone overlap',
      );
    }

    if (avgIncidentSeverity > 3.5) {
      factors.add('Serious incidents reported');
    } else if (avgIncidentSeverity > 2.0) {
      factors.add('Minor incidents on record');
    }

    if (temporalRiskScore > 5.0) {
      factors.add('Recent high-severity incidents');
    }

    return factors.isNotEmpty
        ? factors.join(', ')
        : 'No notable incident factors';
  }

  /// Get URL to incident map view (if implemented)
  String? getIncidentMapUrl() {
    // This could generate a URL to view incidents on a map
    // For now, return null as this is for demonstration
    return null;
  }

  /// Additional data placeholder for forward compatibility
  Map<String, dynamic>? get extraData => null;
}
