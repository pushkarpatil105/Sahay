import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

enum DemoServiceType { ambulance, towing }

extension on DemoServiceType {
  String get firestoreValue => name;
}

class DemoServiceRequest {
  const DemoServiceRequest({
    required this.id,
    required this.serviceType,
    required this.status,
    required this.providerName,
    required this.escalationCount,
  });

  final String id;
  final String serviceType;
  final String status;
  final String? providerName;
  final int escalationCount;

  factory DemoServiceRequest.fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    final data = snapshot.data()!;
    return DemoServiceRequest(
      id: snapshot.id,
      serviceType: data['service_type']?.toString() ?? '',
      status: data['status']?.toString() ?? 'pending',
      providerName: data['assigned_provider_name']?.toString(),
      escalationCount: (data['escalation_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// User-app side of SERVICE_REQUEST_INTEGRATION.md.
/// It only creates demo requests, observes one request, and cancels it.
class DemoServiceRequestService {
  DemoServiceRequestService({FirebaseFirestore? firestore, FirebaseAuth? auth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  static const _collection = 'service_requests';
  static const _writeTimeout = Duration(seconds: 10);

  Future<String> createDemoRequest({
    required DemoServiceType serviceType,
    required double latitude,
    required double longitude,
  }) async {
    final user = _auth.currentUser;
    final requestId = 'req_${const Uuid().v4()}';
    await _writeRequest(requestId, {
      'request_id': requestId,
      'user_id': user?.uid ?? 'anonymous',
      'user_name': user?.displayName?.trim().isNotEmpty == true
          ? user!.displayName!.trim()
          : 'Sahay User',
      'service_type': serviceType.firestoreValue,
      'status': 'pending',
      'location': {'lat': latitude, 'lng': longitude},
      'assigned_provider_id': null,
      'assigned_provider_name': null,
      'is_demo': true,
      'escalation_count': 0,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    });
    return requestId;
  }

  /// Creates the hospital-specific ambulance request used by the live Google
  /// Places hospital flow. The provider ID is deliberately fixed for the
  /// hackathon demo so every request reaches the demo admin account.
  Future<String> createHospitalAmbulanceRequest({
    required double userLatitude,
    required double userLongitude,
    required String hospitalName,
    required String hospitalPlaceId,
    required double hospitalLatitude,
    required double hospitalLongitude,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Sign in before requesting an ambulance.');
    }

    final requestId = 'req_${const Uuid().v4()}';
    await _writeRequest(requestId, {
      'request_id': requestId,
      'user_id': user.uid,
      'service_type': 'ambulance',
      'status': 'pending',
      'location': {'lat': userLatitude, 'lng': userLongitude},
      'requested_hospital_name': hospitalName,
      'requested_hospital_place_id': hospitalPlaceId,
      'requested_hospital_location': {
        'lat': hospitalLatitude,
        'lng': hospitalLongitude,
      },
      // Intentional demo routing; do not derive this from Google Places.
      'assigned_provider_id': 'provider_001',
      'assigned_provider_name': null,
      'is_demo': true,
      'escalation_count': 0,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    });
    return requestId;
  }

  Future<void> _writeRequest(String requestId, Map<String, dynamic> data) async {
    try {
      await _firestore
          .collection(_collection)
          .doc(requestId)
          .set(data)
          .timeout(_writeTimeout);
    } on FirebaseException catch (error) {
      if (error.code == 'permission-denied') {
        throw Exception(
          'Request blocked by Firestore rules. Sign in and allow authenticated users to create service_requests.',
        );
      }
      if (error.code == 'unavailable') {
        throw Exception(
          'Unable to reach Firestore. Check your internet connection and try again.',
        );
      }
      throw Exception('Unable to send request: ${error.message ?? error.code}');
    } on TimeoutException {
      throw Exception('Sending timed out. Check your internet connection and try again.');
    }
  }

  Stream<DemoServiceRequest?> watchRequest(String requestId) => _firestore
      .collection(_collection)
      .doc(requestId)
      .snapshots()
      .map((snapshot) => snapshot.exists ? DemoServiceRequest.fromSnapshot(snapshot) : null);

  Future<void> cancelRequest(String requestId) => _firestore
      .collection(_collection)
      .doc(requestId)
      .update({
        'status': 'cancelled',
        'updated_at': FieldValue.serverTimestamp(),
      });
}
