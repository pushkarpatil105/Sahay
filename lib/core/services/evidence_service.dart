import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'video_recording_service.dart';
import 'upload_queue_service.dart';

class EvidenceService {
  static final EvidenceService _instance = EvidenceService._internal();
  factory EvidenceService() => _instance;
  EvidenceService._internal();

  FlutterSoundRecorder? _recorder;
  bool _isRecording = false;
  String? _currentSosId;
  String? _currentEvidenceDir;
  final List<Map<String, dynamic>> _locationLog = [];
  bool _isLoggingLocation = false;

  // Contacts to notify when evidence is ready â€” set by SosService
  List<Map<String, dynamic>> _emergencyContacts = [];
  String _userName = 'User';
  Position? _lastPosition;

  void setContactsForNotification(
    List<Map<String, dynamic>> contacts,
    String name,
    Position? position,
  ) {
    _emergencyContacts = contacts;
    _userName = name;
    _lastPosition = position;
  }

  List<Map<String, dynamic>> getEmergencyContacts() => _emergencyContacts;
  String getUserName() => _userName;
  Position? getLastPosition() => _lastPosition;

  // â”€â”€ Start evidence â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> startEvidence(String sosId, Position position) async {
    _currentSosId = sosId;
    _locationLog.clear();
    _lastPosition = position;

    final appDir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _currentEvidenceDir = '${appDir.path}/evidence/sos_$timestamp';
    await Directory(_currentEvidenceDir!).create(recursive: true);
    print('Evidence dir: $_currentEvidenceDir');

    _logLocation(position);
    _startLocationLogging();

    final canRecord = await _ensureRecordingPermissions();
    if (!canRecord) {
      print('Camera/microphone permission not granted');
      return;
    }
    // Prewarm camera for faster recording start
    VideoRecordingService().onMaxDurationReached = _onMaxDurationReached;
    try {
      await VideoRecordingService().prewarmCamera();
    } catch (e) {
      print('Camera prewarm failed: $e');
    }
    await VideoRecordingService().startRecording(
      _currentEvidenceDir!,
      sosId: sosId,
    );
    print('Video+audio recording started');
  }

  Future<void> startEvidenceWithoutLocation(String sosId) async {
    _currentSosId = sosId;
    _locationLog.clear();

    final appDir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _currentEvidenceDir = '${appDir.path}/evidence/sos_$timestamp';
    await Directory(_currentEvidenceDir!).create(recursive: true);
    print('Evidence dir (no location): $_currentEvidenceDir');

    final canRecord = await _ensureRecordingPermissions();
    if (!canRecord) {
      print('Camera/microphone permission not granted');
      return;
    }

    VideoRecordingService().onMaxDurationReached = _onMaxDurationReached;
    try {
      await VideoRecordingService().prewarmCamera();
    } catch (e) {
      print('Camera prewarm failed: $e');
    }
    await VideoRecordingService().startRecording(
      _currentEvidenceDir!,
      sosId: sosId,
    );
    print('Video+audio recording started');

    // Unawaited background future for location
    Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high)
        .timeout(const Duration(seconds: 5))
        .then((position) {
          _logLocation(position);
          _lastPosition = position;
          _startLocationLogging();
        })
        .catchError((e) {
          print('Location unavailable: $e');
        });
  }

  // Called automatically when 5 min recording limit is hit
  // User never needed to press Im Safe â€” evidence is already uploading
  void _onMaxDurationReached() {
    print('Auto-stop triggered â€” saving and queuing evidence');
    stopEvidence()
        .then((_) {
          // Send follow-up SMS with cloud evidence links
          _sendEvidenceLinksToContacts();
        })
        .catchError((e) {
          print('Auto-stop evidence error: $e');
        });
  }

  // â”€â”€ Stop evidence â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<String?> stopEvidence() async {
    if (_currentEvidenceDir == null) {
      print('stopEvidence: no evidence dir');
      return null;
    }

    final sosId = _currentSosId;

    _isLoggingLocation = false;

    // Stop recording â€” final chunk saved and uploaded
    await VideoRecordingService().stopRecording();
    print('Video recording stopped');

    await _saveLocationLog();

    // ZIP all chunks + location log together
    final zipPath = await _createZip();
    print('ZIP created: $zipPath');

    final evidenceDocId = await saveEvidenceMetadata(zipPath, null);
    print('Evidence metadata saved: docId=$evidenceDocId');

    if (zipPath != null && evidenceDocId != null) {
      await UploadQueueService().enqueue(
        zipPath: zipPath,
        sosId: sosId ?? 'unknown',
        evidenceDocId: evidenceDocId,
      );
    }

    // Reset state after successful stop
    _currentEvidenceDir = null;
    _currentSosId = null;

    return zipPath;
  }

  // Send SMS with cloud video links to emergency contacts
  Future<void> _sendEvidenceLinksToContacts() async {
    if (_emergencyContacts.isEmpty) return;

    final uploadedUrls = VideoRecordingService().uploadedChunkUrls;
    if (uploadedUrls.isEmpty) {
      print('No uploaded chunk URLs to share');
      return;
    }

    String message = 'EVIDENCE UPDATE â€” $_userName SOS Evidence:\n';
    message += 'Video chunks uploaded to cloud:\n';
    for (int i = 0; i < uploadedUrls.length; i++) {
      message += 'Clip ${i + 1}: ${uploadedUrls[i]}\n';
    }
    message += 'Time: ${DateTime.now().toString().substring(0, 16)}';

    const platform = MethodChannel('com.sahay.app/sms');

    for (final contact in _emergencyContacts) {
      final phone = contact['phone'] as String?;
      if (phone == null) continue;
      try {
        await platform.invokeMethod('sendSMS', {
          'phone': phone,
          'message': message,
        });
        print('Evidence links sent to $phone');
      } catch (e) {
        print('SMS send error: $e');
      }
    }
  }

  // â”€â”€ Location â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  void _logLocation(Position position) {
    _locationLog.add({
      'lat': position.latitude,
      'lng': position.longitude,
      'timestamp': DateTime.now().toIso8601String(),
      'accuracy': position.accuracy,
      'maps_link':
          'https://maps.google.com/?q=${position.latitude},${position.longitude}',
    });
  }

  void _startLocationLogging() {
    _isLoggingLocation = true;
    Future.doWhile(() async {
      if (!_isLoggingLocation) return false;
      await Future.delayed(const Duration(seconds: 30));
      if (!_isLoggingLocation) return false;
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        _logLocation(position);
      } catch (e) {}
      return _isLoggingLocation;
    });
  }

  Future<bool> _ensureRecordingPermissions() async {
    final camera = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    return camera.isGranted && mic.isGranted;
  }

  // â”€â”€ Audio â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _startAudioRecording() async {
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) return;
      _recorder = FlutterSoundRecorder();
      await _recorder!.openRecorder();
      final audioPath = '$_currentEvidenceDir/audio.aac';
      await _recorder!.startRecorder(toFile: audioPath, codec: Codec.aacADTS);
      _isRecording = true;
    } catch (e) {
      _isRecording = false;
    }
  }

  Future<void> _stopAudioRecording() async {
    if (!_isRecording || _recorder == null) return;
    try {
      await _recorder!.stopRecorder();
      await _recorder!.closeRecorder();
      _isRecording = false;
      _recorder = null;
    } catch (e) {}
  }

  // â”€â”€ ZIP â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> _saveLocationLog() async {
    if (_currentEvidenceDir == null) return;
    try {
      final file = File('$_currentEvidenceDir/location_log.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'sos_id': _currentSosId,
          'generated_at': DateTime.now().toIso8601String(),
          'locations': _locationLog,
        }),
      );
    } catch (e) {}
  }

  Future<String?> _createZip() async {
    if (_currentEvidenceDir == null) return null;
    try {
      final encoder = ZipFileEncoder();
      final zipPath = '$_currentEvidenceDir.zip';
      encoder.create(zipPath);
      final dir = Directory(_currentEvidenceDir!);
      final files = await dir.list().toList();
      for (final file in files) {
        if (file is File) {
          encoder.addFile(file);
        }
      }
      encoder.close();
      return zipPath;
    } catch (e) {
      print('_createZip error: $e');
      return null;
    }
  }

  // â”€â”€ Firestore metadata â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<String?> saveEvidenceMetadata(String? zipPath, String? zipUrl) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return null;

      final location = _locationLog.isNotEmpty ? _locationLog.first : null;

      // Save chunk URLs that were already uploaded during SOS
      final uploadedChunkUrls = VideoRecordingService().uploadedChunkUrls;

      final docRef = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('evidence')
          .add({
            'sos_id': _currentSosId,
            'timestamp': FieldValue.serverTimestamp(),
            'location': location,
            'location_count': _locationLog.length,
            // audio is embedded in the recorded video chunks; no separate audio file
            'has_audio': false,
            'zip_path': zipPath,
            'dir_path': _currentEvidenceDir,
            'zip_url': null,
            'uploaded_to_cloud': false,
            'chunk_urls': uploadedChunkUrls, // already on cloud
            'chunk_count': uploadedChunkUrls.length,
          });

      return docRef.id;
    } catch (e) {
      print('saveEvidenceMetadata error: $e');
      return null;
    }
  }

  // â”€â”€ SMS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> sendSmsToContacts(
    List<Map<String, dynamic>> contacts,
    String name,
    Position? position, {
    String? zipUrl,
    String? liveShareUrl,
  }) async {
    final status = await Permission.sms.request();

    String message = 'SOS ALERT! $name needs help!\n';

    // Prefer live share link when available, otherwise fallback to static maps link
    if (liveShareUrl != null) {
      message += 'ðŸ“ Live Location (24 hrs):\n$liveShareUrl\n';
    } else if (position != null) {
      final mapsLink =
          'https://maps.google.com/?q=${position.latitude},${position.longitude}';
      message += 'Location: $mapsLink\n';
    }

    if (zipUrl != null) {
      message += 'ðŸ“¦ Full SOS Evidence (Zip File): $zipUrl\n';
      message +=
          '(This file contains video, audio, and location logs from this emergency.)\n';
    }

    message +=
        'Time: ${DateTime.now().toString().substring(0, 16)}\nPlease respond immediately!\n\nTo perfectly simulate override and dial 112 for the victim remotely, click: https://nari-shakti-hacksagon.web.app/escalate/$_currentSosId';

    const platform = MethodChannel('com.sahay.app/sms');

    for (final contact in contacts) {
      final phone = contact['phone'] as String?;
      if (phone == null) continue;

      if (status.isGranted) {
        try {
          await platform.invokeMethod('sendSMS', {
            'phone': phone,
            'message': message,
          });
          continue;
        } catch (e) {}
      }

      try {
        final uri = Uri.parse(
          'sms:$phone?body=${Uri.encodeComponent(message)}',
        );
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {}
    }
  }

  // â”€â”€ Share / export â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<void> shareEvidenceViaEmail(
    String zipPath,
    String email,
    String name,
  ) async {
    try {
      final file = XFile(zipPath);
      await Share.shareXFiles(
        [file],
        subject:
            'SOS Evidence - $name - ${DateTime.now().toString().substring(0, 16)}',
        text:
            'SOS Evidence package from Sahay app.\nUser: $name\nTime: ${DateTime.now()}',
      );
    } catch (e) {}
  }

  // â”€â”€ Fetch all evidence â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Future<List<Map<String, dynamic>>> getAllEvidence() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return [];
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('evidence')
          .orderBy('timestamp', descending: true)
          .get();
      return snap.docs.map((d) => {'id': d.id, ...d.data()}).toList();
    } catch (e) {
      return [];
    }
  }
}
