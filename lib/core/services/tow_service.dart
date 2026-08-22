import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class TowOperator {
  const TowOperator({
    required this.id,
    required this.name,
    required this.phone,
    required this.whatsapp,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.hasPhone,
    required this.coordinatesAreUsable,
    required this.hours,
    required this.vehicleTypes,
    this.rating,
  });

  final String id;
  final String name;
  final String phone;
  final String whatsapp;
  final String address;
  final double? latitude;
  final double? longitude;
  final bool hasPhone;
  final bool coordinatesAreUsable;
  final String? hours;
  final List<String> vehicleTypes;
  final double? rating;

  factory TowOperator.fromJson(Map<String, dynamic> json) {
    final location = json['location'] as Map<String, dynamic>? ?? const {};
    return TowOperator(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Towing service',
      phone: json['phone']?.toString() ?? '',
      whatsapp: json['whatsapp']?.toString() ?? '',
      address: json['address']?.toString() ?? 'Address unavailable',
      latitude: (location['lat'] as num?)?.toDouble(),
      longitude: (location['lng'] as num?)?.toDouble(),
      hasPhone: json['has_phone'] == true,
      coordinatesAreUsable: location['coord_source'] != 'dummy_placeholder',
      hours: json['hours']?.toString(),
      vehicleTypes: (json['vehicle_types'] as List? ?? const [])
          .map((type) => type.toString())
          .toList(),
      rating: (json['rating'] as num?)?.toDouble(),
    );
  }

  bool get canShowOnMap =>
      coordinatesAreUsable && latitude != null && longitude != null;
}

class TowService {
  static const _assetPath = 'assets/data/indore_services_data.json';

  Future<List<TowOperator>> getIndoreOperators() async {
    final raw = await rootBundle.loadString(_assetPath);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final operators = (data['towing_operators'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TowOperator.fromJson)
        .toList();
    operators.sort((a, b) => a.name.compareTo(b.name));
    return operators;
  }
}
