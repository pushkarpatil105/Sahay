import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'evidence_service.dart';
import 'escalation_service.dart';
import 'lock_screen_sos_service.dart';
import 'package:nari_shakti/core/services/cloudinary_service.dart';
import 'package:nari_shakti/core/services/upload_queue_service.dart';
import 'package:nari_shakti/core/services/ble_service.dart';
import 'package:nari_shakti/main.dart'; // for navigatorKey
import 'package:nari_shakti/core/services/live_share_service.dart';

class SosService {
  static final SosService _instance = SosService._internal();
  factory SosService() => _instance;
  SosService._internal();

  String? _activeSosId;
  bool _isActive = false;
  Timer? _autoCancelTimer;

  /// Public getter for the active SOS document ID
  String? get activeSosId => _activeSosId;

  /// Background SOS trigger — works without BuildContext (for lock screen / foreground service)
  Future<void> triggerSOSBackground(String triggeredBy) async {
    if (_isActive) return;
    _isActive = true;

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        _isActive = false;
        return;
      }

      // 1. INSTANTLY generate the SOS Document ID locally so we can proceed without any delay
      final sosRef = FirebaseFirestore.instance.collection('sos_events').doc();
      _activeSosId = sosRef.id;

      // Create the SOS record immediately so cancel/auto-cancel can always find it.
      await sosRef.set({
        'user_id': uid,
        'timestamp': FieldValue.serverTimestamp(),
        'location': null,
        'triggered_by': triggeredBy,
        'status': 'active',
        'contacts_notified': 0,
      });

      // 1.5 Trigger Violent Hardware Vibration
      if (triggeredBy != 'shake') {
        LockScreenSosService().vibrateSOSDouble();
      }
      await BleService().sendCommand('VIB_L');

      // Start 2-Minute Auto-Cancellation Safety Net
      _autoCancelTimer?.cancel();
      print('⏱️ Starting 2-minute SOS auto-termination safety net');
      _autoCancelTimer = Timer(const Duration(minutes: 2), () {
        _executeAutoCancel(_activeSosId);
      });

      // Start camera warm-up and evidence recording immediately so it runs in parallel
      unawaited(EvidenceService().startEvidenceWithoutLocation(_activeSosId!));

      // If the app UI is available, navigate to the active SOS screen so user sees the event
      if (navigatorKey.currentState != null) {
        try {
          navigatorKey.currentState!.pushNamed(
            '/sos_active',
            arguments: {'sosId': _activeSosId, 'triggeredBy': triggeredBy},
          );
        } catch (e) {
          print('Navigation from background SOS failed: $e');
        }
      }

      // 2. Process all the heavy lifting (GPS, DB updates, SMS) in the background
      () async {
        await _runSosPipeline(
          uid: uid,
          sosRef: sosRef,
          triggeredBy: triggeredBy,
        );
      }();
    } catch (e) {
      print('triggerSOSBackground block error: $e');
      _isActive = false;
    }
  }

  Future<void> triggerSOS(BuildContext context, String triggeredBy) async {
    if (_isActive) return;
    _isActive = true;

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        _isActive = false;
        return;
      }

      // 1. INSTANTLY generate the SOS Document ID locally so we can navigate without any delay
      final sosRef = FirebaseFirestore.instance.collection('sos_events').doc();
      _activeSosId = sosRef.id;

      // Create the SOS record immediately so cancel/auto-cancel can always find it.
      await sosRef.set({
        'user_id': uid,
        'timestamp': FieldValue.serverTimestamp(),
        'location': null,
        'triggered_by': triggeredBy,
        'status': 'active',
        'contacts_notified': 0,
      });

      // 1.5 Trigger Violent Hardware Vibration
      if (triggeredBy != 'shake') {
        LockScreenSosService().vibrateSOSDouble();
      }
      await BleService().sendCommand('VIB_L');

      // Start 2-Minute Auto-Cancellation Safety Net
      _autoCancelTimer?.cancel();
      _autoCancelTimer = Timer(const Duration(minutes: 2), () {
        _executeAutoCancel(_activeSosId);
      });

      // Start camera warm-up and evidence recording immediately so it runs in parallel
      unawaited(EvidenceService().startEvidenceWithoutLocation(_activeSosId!));

      // 2. Navigate immediately so the UI responds instantly!
      if (context.mounted) {
        Navigator.pushNamed(
          context,
          '/sos_active',
          arguments: {'sosId': _activeSosId, 'triggeredBy': triggeredBy},
        );
      }

      // 3. Process all the heavy lifting (GPS, DB updates, SMS) in the background without blocking
      () async {
        await _runSosPipeline(
          uid: uid,
          sosRef: sosRef,
          triggeredBy: triggeredBy,
        );
      }();
    } catch (e) {
      _isActive = false;
    }
  }

  Future<void> _runSosPipeline({
    required String uid,
    required DocumentReference<Map<String, dynamic>> sosRef,
    required String triggeredBy,
  }) async {
    Position? position;
    try {
      position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      try {
        position = await Geolocator.getLastKnownPosition();
      } catch (e2) {
        position = null;
      }
    }

    if (!_isActive) return;

    String userName = 'User';
    List<Map<String, dynamic>> contactMaps = [];

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final contacts = userDoc.data()?['emergency_contacts'] as List? ?? [];
      userName =
          userDoc.data()?['profile']?['name'] ??
          userDoc.data()?['medical_info']?['name'] ??
          'User';
      contactMaps = contacts.map((c) => Map<String, dynamic>.from(c)).toList();
    } catch (e) {
      print('User fetch error: $e');
    }

    try {
      await sosRef.set({
        'user_id': uid,
        'timestamp': FieldValue.serverTimestamp(),
        'location': position != null
            ? {'lat': position.latitude, 'lng': position.longitude}
            : null,
        'triggered_by': triggeredBy,
        'status': 'active',
        'contacts_notified': contactMaps.length,
      }, SetOptions(merge: true));
    } catch (e) {
      print('SOS update error: $e');
    }

    String? liveShareUrl;
    try {
      liveShareUrl = await LiveShareService().startSharing(
        _activeSosId!,
        userName,
        contactMaps,
      );
    } catch (e) {
      print('LiveShare start error: $e');
    }

    if (position != null) {
      try {
        await FirebaseDatabase.instance.ref('live_location/$uid').set({
          'lat': position.latitude,
          'lng': position.longitude,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'sos_id': _activeSosId,
        });
      } catch (e) {
        print('Legacy live location error: $e');
      }
    }

    EvidenceService().setContactsForNotification(
      contactMaps,
      userName,
      position,
    );

    if (contactMaps.isNotEmpty) {
      try {
        await EvidenceService().sendSmsToContacts(
          contactMaps,
          userName,
          position,
          liveShareUrl: liveShareUrl,
        );
      } catch (e) {
        print('SMS send error: $e');
      }
    }

    // Always start escalation countdown so the UI timer updates.
    EscalationService().startSequence(contactMaps, userName);

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .add({
            'type': 'sos',
            'title': 'SOS Activated',
            'body':
                'SOS was triggered via $triggeredBy at ${DateTime.now().toString().substring(0, 16)}',
            'timestamp': FieldValue.serverTimestamp(),
            'read': false,
          });
    } catch (e) {
      print('SOS notification add error: $e');
    }
  }

  Future<void> cancelSOS(String sosId) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      // 1. Immediately free the SOS lock so the user can trigger another emergency instantly!
      _isActive = false;
      _activeSosId = null;
      _autoCancelTimer?.cancel();

      // Ensure Twilio escalation is cancelled!
      EscalationService().cancelSequence();

      // 2. Stop evidence in background — don't await
      EvidenceService()
          .stopEvidence()
          .then((zipPath) async {
            if (zipPath != null) {
              final userDoc = await FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .get();
              final email = userDoc.data()?['profile']?['email'] ?? '';
              final name = userDoc.data()?['profile']?['name'] ?? 'User';
              // Don't auto-share — let user share manually from evidence screen
            }
          })
          .catchError((e) => print('Evidence stop error: $e'));

      // Update Firestore status immediately
      await FirebaseFirestore.instance.collection('sos_events').doc(sosId).set({
        'status': 'cancelled',
      }, SetOptions(merge: true));

      // Remove live location
      await FirebaseDatabase.instance.ref('live_location/$uid').remove();
      await BleService().sendCommand('VIB_STOP');
    } catch (e) {
      print('🔴 cancelSOS ERROR: $e');
      _isActive = false;
    }
  }

  Future<void> _executeAutoCancel(String? sosId) async {
    if (sosId == null || sosId != _activeSosId || !_isActive) return;

    print('⏱️ 2-MINUTE TIMEOUT REACHED — Auto-ending SOS & Zipping Evidence');

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final contacts = userDoc.data()?['emergency_contacts'] as List? ?? [];

      final zipPath = await EvidenceService().stopEvidence();
      print('ZIP created: $zipPath');

      final evidenceDocId = await EvidenceService().saveEvidenceMetadata(
        zipPath,
        null,
      );
      print('Evidence metadata saved: docId=$evidenceDocId');

      if (zipPath != null && evidenceDocId != null) {
        await UploadQueueService().enqueue(
          zipPath: zipPath,
          sosId: sosId ?? 'unknown',
          evidenceDocId: evidenceDocId,
        );
      }

      if (zipPath != null) {
        final url = await CloudinaryService().uploadZip(zipPath, sosId);
        if (url != null) {
          await EvidenceService().sendSmsToContacts(
            contacts.cast<Map<String, dynamic>>(),
            EvidenceService().getUserName(),
            EvidenceService().getLastPosition(),
            zipUrl: url,
          );
        }
      }

      await cancelSOS(sosId);
      await LockScreenSosService().dismiss();

      if (navigatorKey.currentState != null) {
        navigatorKey.currentState!.pushNamedAndRemoveUntil(
          '/home',
          (route) => false,
        );
      }
    } catch (e) {
      print('Auto-cancel execution error: $e');
    }
  }
}
