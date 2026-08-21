import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FaceEvidenceRepository {
  static Future<void> save({
    required String sosId,
    required String faceUrl,
    required List<double> embedding,
    required DateTime detectedAt,
  }) async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final data = <String, dynamic>{
        'embedding': embedding,
        'face_url': faceUrl,
        'detected_at': Timestamp.fromDate(detectedAt),
      };

      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('sos_events')
          .doc(sosId)
          .collection('face_evidence')
          .add(data);
    } catch (e) {
      print('FaceEvidenceRepository.save error: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> getFaces(String sosId) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('sos_events')
        .doc(sosId)
        .collection('face_evidence')
        .orderBy('detected_at', descending: false)
        .get();

    return snapshot.docs.map((doc) => doc.data()).toList();
  }
}


