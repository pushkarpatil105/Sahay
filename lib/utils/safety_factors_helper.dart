import 'package:flutter/material.dart';
import 'package:nari_shakti/models/route_model.dart';

class SafetyFactor {
  final String title;
  final String value;
  final bool positive;

  const SafetyFactor({
    required this.title,
    required this.value,
    this.positive = true,
  });
}

class SafetyFactorsHelper {
  // DEMO MODE - In production, these factors will come from the AI backend service.
  static Color colorForScore(double score) {
    if (score >= 8.0) return const Color(0xFF10B981);
    if (score >= 5.0) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  static String labelForScore(double score) {
    if (score >= 8.0) return 'Safest Route';
    if (score >= 5.0) return 'Moderate Route';
    return 'Risky Route';
  }

  static String modalLabelForScore(double score) {
    if (score >= 8.0) return 'Safe Route';
    if (score >= 5.0) return 'Moderate Route';
    return 'Risky Route';
  }

  static List<SafetyFactor> factorsForRoute(SafeRoute route) {
    if (route.safetyScore >= 8.0) {
      return const [
        SafetyFactor(title: 'Well-lit roads', value: 'Good'),
        SafetyFactor(title: 'Police stations nearby', value: '3 within 1.2 km'),
        SafetyFactor(title: 'Low crime rate area', value: 'Good'),
        SafetyFactor(title: 'High public activity', value: 'Good'),
        SafetyFactor(title: 'CCTV coverage', value: 'Good'),
        SafetyFactor(title: 'Frequent patrolling', value: 'Good'),
        SafetyFactor(title: 'Good transport availability', value: 'Good'),
      ];
    }

    if (route.safetyScore >= 5.0) {
      return const [
        SafetyFactor(title: 'Well-lit roads', value: 'Average'),
        SafetyFactor(title: 'Police stations nearby', value: '1 within 1.8 km'),
        SafetyFactor(title: 'Crime rate area', value: 'Moderate'),
        SafetyFactor(title: 'Public activity', value: 'Medium'),
        SafetyFactor(title: 'CCTV coverage', value: 'Partial'),
        SafetyFactor(title: 'Patrolling frequency', value: 'Medium'),
        SafetyFactor(title: 'Transport availability', value: 'Available'),
      ];
    }

    return const [
      SafetyFactor(title: 'Poorly lit stretches', value: 'Risk'),
      SafetyFactor(title: 'Police stations nearby', value: 'None close'),
      SafetyFactor(title: 'Crime rate area', value: 'High'),
      SafetyFactor(title: 'Public activity', value: 'Low'),
      SafetyFactor(title: 'CCTV coverage', value: 'Limited'),
      SafetyFactor(title: 'Patrolling frequency', value: 'Low'),
      SafetyFactor(title: 'Transport availability', value: 'Sparse'),
    ];
  }
}
