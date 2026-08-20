import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';

class LiveShareService {
  static final LiveShareService _instance = LiveShareService._internal();
  factory LiveShareService() => _instance;
  LiveShareService._internal();

  String? _shareId;
  String? _userId;
  Timer? _locationTimer;
  Timer? _expiryTimer;
  bool _isSharing = false;
  bool get isSharingNow => _isSharing; // sync getter for bubble init
  final StreamController<bool> _sharingController =
      StreamController<bool>.broadcast();

  Stream<bool> get isSharing => _sharingController.stream;

  Future<String?> startSharing(
    String sosId,
    String userName,
    List<Map<String, dynamic>> contacts,
  ) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return null;

      _userId = uid;

      final shareRef = FirebaseFirestore.instance
          .collection('live_shares')
          .doc();
      final expiresAt = DateTime.now().add(const Duration(hours: 24));
      _shareId = shareRef.id;

      await shareRef.set({
        'sosId': sosId,
        'userId': uid,
        'userName': userName,
        'active': true,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(expiresAt),
      });

      _sharingController.add(true);
      _isSharing = true;

      await _writeCurrentLocation(userName, expiresAt);

      _locationTimer?.cancel();
      _locationTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
        await _writeCurrentLocation(userName, expiresAt);
      });

      _expiryTimer?.cancel();
      _expiryTimer = Timer(const Duration(hours: 24), () {
        stopSharing();
      });

      return getShareUrl();
    } catch (e) {
      print('LiveShareService.startSharing error: $e');
      return null;
    }
  }

  Future<void> stopSharing() async {
    final shareId = _shareId;
    if (shareId == null) return;

    _locationTimer?.cancel();
    _expiryTimer?.cancel();
    _locationTimer = null;
    _expiryTimer = null;

    try {
      await FirebaseFirestore.instance
          .collection('live_shares')
          .doc(shareId)
          .set({'active': false}, SetOptions(merge: true));

      await FirebaseDatabase.instance
          .ref('live_location_share/$shareId')
          .update({'active': false, 'userId': _userId});
    } catch (e) {
      print('LiveShareService.stopSharing error: $e');
    }

    _shareId = null;
    _userId = null;
    _sharingController.add(false);
    _isSharing = false;
  }

  Future<void> _writeCurrentLocation(
    String userName,
    DateTime expiresAt,
  ) async {
    final shareId = _shareId;
    if (shareId == null) return;

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      await FirebaseDatabase.instance.ref('live_location_share/$shareId').set({
        'lat': position.latitude,
        'lng': position.longitude,
        'accuracy': position.accuracy,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'userName': userName,
        'userId': _userId,
        'expiresAt': expiresAt.millisecondsSinceEpoch,
        'active': true,
      });
    } catch (e) {
      print('LiveShareService._writeCurrentLocation error: $e');
    }
  }

  String? getShareId() => _shareId;

  String? getShareUrl() {
    final shareId = _shareId;
    if (shareId == null) return null;
    return 'https://nari-shakti-hacksagon.web.app/track/$shareId';
  }

  void dispose() {
    _locationTimer?.cancel();
    _expiryTimer?.cancel();
    _sharingController.close();
  }
}
