
class IncidentAnalytics {
  /// Total incidents detected along the route corridor
  final int incidentCount;

  /// Incidents per kilometer of route (0-5+)
  final double incidentDensity;

  /// Crime Severity Index: 0-100 scale
  /// Higher values indicate more serious crimes in the area
  final double maxCrimeIndex;

  /// Average CSI across all sampled points
  final double avgCrimeIndex;

  /// Proportion of route passing through high-risk zones (0-1)
  final double redzoneOverlapRatio;

  /// Average severity of matched incidents (1-5 scale)
  final double avgIncidentSeverity;

  /// Time-decay weighted severity score
  /// Recent high-severity incidents weighted more heavily
  final double temporalRiskFactor;

  /// Number of route corridor points queried
  final int queriedPoints;

  /// Last update timestamp
  final DateTime lastUpdated;

  IncidentAnalytics({
    required this.incidentCount,
    required this.incidentDensity,
    required this.maxCrimeIndex,
    required this.avgCrimeIndex,
    required this.redzoneOverlapRatio,
    required this.avgIncidentSeverity,
    required this.temporalRiskFactor,
    required this.queriedPoints,
    required this.lastUpdated,
  });

  /// Parse incident analytics from route scoring response
  factory IncidentAnalytics.fromRoute(Map<String, dynamic> routeJson) {
    return IncidentAnalytics(
      incidentCount:
          (routeJson['crimeometer_incident_count'] as num?)?.toInt() ?? 0,
      incidentDensity: (routeJson['incident_density'] as num?)?.toDouble() ?? 0,
      maxCrimeIndex:
          (routeJson['crimeometer_max_csi'] as num?)?.toDouble() ?? 0,
      avgCrimeIndex:
          (routeJson['crimeometer_avg_csi'] as num?)?.toDouble() ?? 0,
      redzoneOverlapRatio:
          (routeJson['redzone_overlap_score'] as num?)?.toDouble() ?? 0,
      avgIncidentSeverity:
          (routeJson['avg_incident_severity'] as num?)?.toDouble() ?? 0,
      temporalRiskFactor:
          (routeJson['temporal_risk_score'] as num?)?.toDouble() ?? 0,
      queriedPoints:
          (routeJson['crimeometer_query_points'] as num?)?.toInt() ?? 0,
      lastUpdated: DateTime.now(),
    );
  }

  /// Human-readable summary of incident analysis
  String getSummary() {
    if (incidentCount == 0) {
      return 'No incidents detected on this route';
    }

    final List<String> factors = [];

    if (maxCrimeIndex > 60) {
      factors.add('High crime index detected');
    } else if (maxCrimeIndex > 40) {
      factors.add('Moderate crime activity');
    }

    if (redzoneOverlapRatio > 0.5) {
      factors.add(
        '${(redzoneOverlapRatio * 100).toStringAsFixed(0)}% overlaps high-risk zones',
      );
    }

    if (incidentDensity > 3.0) {
      factors.add(
        'High incident density (${incidentDensity.toStringAsFixed(1)}/km)',
      );
    }

    return factors.isNotEmpty
        ? factors.join('; ')
        : '$incidentCount incidents on record';
  }

  /// Risk rating based on incident data (0-100)
  int getRiskRating() {
    int rating = 0;

    // Incident count contribution (max 30 points)
    rating += ((incidentCount / 5).clamp(0, 30)).toInt();

    // Crime index contribution (max 40 points)
    rating += ((maxCrimeIndex / 2.5).clamp(0, 40)).toInt();

    // Redzone overlap contribution (max 30 points)
    rating += ((redzoneOverlapRatio * 30).clamp(0, 30)).toInt();

    return rating.clamp(0, 100);
  }
}

class IncidentReport {
  /// Unique incident identifier
  final String incidentId;

  /// Offense description
  final String offense;

  /// Type of crime (person, property, society, etc.)
  final String crimeAgainstType;

  /// Severity rating (1-5, where 5 is most severe)
  final double severity;

  /// Incident timestamp
  final DateTime timestamp;

  /// Incident location (latitude)
  final double latitude;

  /// Incident location (longitude)
  final double longitude;

  IncidentReport({
    required this.incidentId,
    required this.offense,
    required this.crimeAgainstType,
    required this.severity,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
  });

  /// Parse from API response
  factory IncidentReport.fromJson(Map<String, dynamic> json) {
    return IncidentReport(
      incidentId: json['incident_id']?.toString() ?? '',
      offense: json['offense']?.toString() ?? 'Unknown',
      crimeAgainstType: json['crime_against']?.toString() ?? 'Unknown',
      severity: (json['severity'] as num?)?.toDouble() ?? 0,
      timestamp: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['timestamp'] as num).toInt() * 1000,
            )
          : DateTime.now(),
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Get severity label for UI display
  String getSeverityLabel() {
    if (severity >= 5.0) return 'Homicide';
    if (severity >= 4.5) return 'Aggravated Assault';
    if (severity >= 4.0) return 'Assault';
    if (severity >= 3.2) return 'Theft';
    if (severity >= 2.0) return 'Minor Crime';
    return 'Other';
  }

  /// Age of incident in hours
  int getHoursAgo() {
    return DateTime.now().difference(timestamp).inHours;
  }
}

class IncidentCluster {
  /// Geographic center of cluster (latitude)
  final double centerLat;

  /// Geographic center of cluster (longitude)
  final double centerLng;

  /// Number of incidents in cluster
  final int incidentCount;

  /// Average severity in cluster
  final double avgSeverity;

  /// Max severity in cluster
  final double maxSeverity;

  /// Cluster radius in meters
  final double radiusMeters;

  /// Most recent incident in cluster
  final DateTime mostRecentIncident;

  IncidentCluster({
    required this.centerLat,
    required this.centerLng,
    required this.incidentCount,
    required this.avgSeverity,
    required this.maxSeverity,
    required this.radiusMeters,
    required this.mostRecentIncident,
  });

  /// Risk level of cluster (LOW, MEDIUM, HIGH, CRITICAL)
  String getRiskLevel() {
    if (maxSeverity >= 4.5) return 'CRITICAL';
    if (maxSeverity >= 4.0) return 'HIGH';
    if (avgSeverity >= 3.0) return 'MEDIUM';
    return 'LOW';
  }
}


