// lib/core/services/upload_queue_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloudinary_service.dart';
import 'upload_status.dart';

// ── Job model ──────────────────────────────────────────────────────────────

class _UploadJob {
  final String zipPath;
  final String sosId;
  final String evidenceDocId;
  int notifyCount;

  _UploadJob({
    required this.zipPath,
    required this.sosId,
    required this.evidenceDocId,
    this.notifyCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'zipPath': zipPath,
        'sosId': sosId,
        'evidenceDocId': evidenceDocId,
        'notifyCount': notifyCount,
      };

  factory _UploadJob.fromJson(Map<String, dynamic> j) => _UploadJob(
        zipPath: j['zipPath'] as String,
        sosId: j['sosId'] as String,
        evidenceDocId: j['evidenceDocId'] as String,
        notifyCount: (j['notifyCount'] as int?) ?? 0,
      );
}

// ── Service ────────────────────────────────────────────────────────────────

class UploadQueueService {
  static final UploadQueueService _instance = UploadQueueService._internal();
  factory UploadQueueService() => _instance;
  UploadQueueService._internal();

  static const String _prefsKey = 'pending_zip_uploads';
  static const Duration _retryDelay = Duration(minutes: 1);
  static const Duration _periodicInterval = Duration(minutes: 1);
  static const int _maxNotifyCount = 3;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _periodicTimer;
  bool _retryInProgress = false;

  final StreamController<UploadStatus> _statusController =
      StreamController<UploadStatus>.broadcast();

  Stream<UploadStatus> get statusStream => _statusController.stream;

  // ── Init ───────────────────────────────────────────────────────────────────

  Future<void> init() async {
    // Clear old stuck jobs from before notifyCount was added
    await _clearLegacyStuckJobs();

    _connectivitySub = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      final hasInternet = results.any((r) => r != ConnectivityResult.none);
      if (hasInternet) {
        print('Internet restored — flushing upload queue');
        _scheduleFlush();
      }
    });

    _periodicTimer = Timer.periodic(_periodicInterval, (_) async {
      final hasInternet = await _isOnline();
      if (hasInternet) {
        final jobs = await _loadFromPrefs();
        if (jobs.isNotEmpty) {
          print('Periodic retry — ${jobs.length} job(s) pending');
          _scheduleFlush();
        }
      }
    });

    _scheduleFlush();
  }

  void dispose() {
    _connectivitySub?.cancel();
    _periodicTimer?.cancel();
    _statusController.close();
  }

  // ── Enqueue ────────────────────────────────────────────────────────────────

  Future<void> enqueue({
    required String zipPath,
    required String sosId,
    required String evidenceDocId,
  }) async {
    final job = _UploadJob(
      zipPath: zipPath,
      sosId: sosId,
      evidenceDocId: evidenceDocId,
      notifyCount: 0,
    );
    await _addToPrefs(job);
    print('Enqueued upload: sosId=$sosId');

    _emitStatus(job, UploadStatus(
      sosId: sosId,
      state: UploadState.queued,
      message: 'Evidence saved locally — uploading to cloud...',
    ));

    Future.microtask(() => _processSingleJob(job));
  }

  // ── Flush ──────────────────────────────────────────────────────────────────

  void _scheduleFlush() {
    Future.microtask(_flushQueue);
  }

  Future<void> _flushQueue() async {
    if (_retryInProgress) {
      Future.delayed(_retryDelay, _scheduleFlush);
      return;
    }
    _retryInProgress = true;

    try {
      final jobs = await _loadFromPrefs();
      if (jobs.isEmpty) return;
      print('Flushing ${jobs.length} pending upload(s)');
      for (final job in List<_UploadJob>.from(jobs)) {
        await _processSingleJob(job);
      }
    } finally {
      _retryInProgress = false;
      final remaining = await _loadFromPrefs();
      if (remaining.isNotEmpty) {
        print('New jobs found after flush — scheduling retry');
        Future.delayed(_retryDelay, _scheduleFlush);
      }
    }
  }

  // ── Process one job ────────────────────────────────────────────────────────

  Future<void> _processSingleJob(_UploadJob job) async {
    final alreadyUploaded = await _isAlreadyUploaded(job);
    if (alreadyUploaded) {
      print('Already uploaded: sosId=${job.sosId} — removing');
      await _removeFromPrefs(job);
      _statusController.add(UploadStatus(
        sosId: job.sosId,
        state: UploadState.success,
        message: 'Evidence already saved to cloud.',
      ));
      return;
    }

    final online = await _isOnline();
    if (!online) {
      print('No internet — skipping ${job.sosId}');
      _emitStatus(job, UploadStatus(
        sosId: job.sosId,
        state: UploadState.queued,
        message: 'No internet — will retry automatically when connected.',
      ));
      return;
    }

    print('Attempting upload: sosId=${job.sosId}');

    try {
      final url = await CloudinaryService().uploadZip(job.zipPath, job.sosId);

      if (url != null) {
        await _markUploadedInFirestore(job, url);
        await _removeFromPrefs(job);
        print('Upload succeeded: ${job.sosId}');
        // Always show success
        _statusController.add(UploadStatus(
          sosId: job.sosId,
          state: UploadState.success,
          message: 'Evidence saved to cloud successfully',
        ));
      } else {
        await _saveErrorToFirestore(job, 'Cloudinary returned null URL');
        print('Upload returned null for ${job.sosId}');
        job.notifyCount++;
        await _updateNotifyCount(job);
        _emitStatus(job, UploadStatus(
          sosId: job.sosId,
          state: UploadState.failed,
          message: 'Upload failed: server rejected file. Retrying...',
        ));
        await Future.delayed(_retryDelay);
      }
    } catch (e) {
      final reason = _friendlyError(e);
      await _saveErrorToFirestore(job, e.toString());
      print('Upload exception for ${job.sosId}: $e');
      job.notifyCount++;
      await _updateNotifyCount(job);
      _emitStatus(job, UploadStatus(
        sosId: job.sosId,
        state: UploadState.failed,
        message: 'Upload failed: $reason. Retrying...',
      ));
      await Future.delayed(_retryDelay);
    }
  }

  // Only show snackbar up to _maxNotifyCount times — then retry silently
  void _emitStatus(_UploadJob job, UploadStatus status) {
    if (status.state == UploadState.success) {
      _statusController.add(status);
      return;
    }
    if (job.notifyCount <= _maxNotifyCount) {
      _statusController.add(status);
    } else {
      print('Silent retry for ${job.sosId} (already notified ${job.notifyCount} times)');
    }
  }

  // ── Legacy cleanup ─────────────────────────────────────────────────────────

  Future<void> _clearLegacyStuckJobs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? [];
      if (raw.isEmpty) return;

      final cleaned = raw.where((s) {
        try {
          final m = jsonDecode(s) as Map<String, dynamic>;
          // No notifyCount = old format job = remove it
          // Over limit = exhausted retries = remove it
          final count = m['notifyCount'] as int?;
          if (count == null) return false;
          return count <= _maxNotifyCount;
        } catch (_) {
          return false;
        }
      }).toList();

      if (cleaned.length != raw.length) {
        print('Cleared ${raw.length - cleaned.length} legacy stuck job(s)');
        await prefs.setStringList(_prefsKey, cleaned);
      }
    } catch (e) {
      print('_clearLegacyStuckJobs error: $e');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<bool> _isOnline() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  String _friendlyError(dynamic e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('socketexception') || msg.contains('network')) {
      return 'No internet connection';
    } else if (msg.contains('timeout')) {
      return 'Connection timed out';
    } else if (msg.contains('permission') || msg.contains('access')) {
      return 'File permission denied';
    } else if (msg.contains('nosuchfile') || msg.contains('not found')) {
      return 'ZIP file missing on device';
    } else {
      return e.toString().length > 60
          ? e.toString().substring(0, 60)
          : e.toString();
    }
  }

  // ── Firestore ──────────────────────────────────────────────────────────────

  Future<bool> _isAlreadyUploaded(_UploadJob job) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return false;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('evidence')
          .doc(job.evidenceDocId)
          .get();
      return doc.data()?['uploaded_to_cloud'] == true;
    } catch (e) {
      print('_isAlreadyUploaded error: $e');
      return false;
    }
  }

  Future<void> _markUploadedInFirestore(_UploadJob job, String url) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('evidence')
          .doc(job.evidenceDocId)
          .update({
        'zip_url': url,
        'uploaded_to_cloud': true,
        'uploaded_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('_markUploadedInFirestore error: $e');
    }
  }

  Future<void> _saveErrorToFirestore(_UploadJob job, String error) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('evidence')
          .doc(job.evidenceDocId)
          .update({
        'last_upload_error': error,
        'last_upload_attempt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  // ── SharedPreferences ──────────────────────────────────────────────────────

  Future<List<_UploadJob>> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? [];
      return raw
          .map((s) =>
              _UploadJob.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('_loadFromPrefs error: $e');
      return [];
    }
  }

  Future<void> _addToPrefs(_UploadJob job) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? [];
      final already = raw.any((s) {
        final m = jsonDecode(s) as Map<String, dynamic>;
        return m['sosId'] == job.sosId;
      });
      if (already) {
        print('sosId=${job.sosId} already in queue — skipping');
        return;
      }
      raw.add(jsonEncode(job.toJson()));
      await prefs.setStringList(_prefsKey, raw);
    } catch (e) {
      print('_addToPrefs error: $e');
    }
  }

  Future<void> _updateNotifyCount(_UploadJob job) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? [];
      final updated = raw.map((s) {
        final m = jsonDecode(s) as Map<String, dynamic>;
        if (m['sosId'] == job.sosId) {
          m['notifyCount'] = job.notifyCount;
          return jsonEncode(m);
        }
        return s;
      }).toList();
      await prefs.setStringList(_prefsKey, updated);
    } catch (e) {
      print('_updateNotifyCount error: $e');
    }
  }

  Future<void> _removeFromPrefs(_UploadJob job) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? [];
      raw.removeWhere((s) {
        final m = jsonDecode(s) as Map<String, dynamic>;
        return m['sosId'] == job.sosId;
      });
      await prefs.setStringList(_prefsKey, raw);
    } catch (e) {
      print('_removeFromPrefs error: $e');
    }
  }
}