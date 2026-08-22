import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

enum DemoServiceType { ambulance, towing }

extension on DemoServiceType {
  String get firestoreValue => name;
  String get label => this == DemoServiceType.ambulance ? 'Ambulance' : 'Tow truck';
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

  Future<String> createDemoRequest({
    required DemoServiceType serviceType,
    required double latitude,
    required double longitude,
  }) async {
    final user = _auth.currentUser;
    final requestId = 'req_${const Uuid().v4()}';
    await _firestore.collection(_collection).doc(requestId).set({
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
