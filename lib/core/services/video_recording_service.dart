import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:nari_shakti/features/face_evidence/face_evidence_processor.dart';
import 'cloudinary_service.dart';

class VideoRecordingService {
  static final VideoRecordingService _instance =
      VideoRecordingService._internal();
  factory VideoRecordingService() => _instance;
  VideoRecordingService._internal();

  CameraController? _controller;
  bool _isRecording = false;
  String? _evidenceDir;
  String? _currentSosId;
  int _chunkIndex = 0;
  Timer? _chunkTimer;
  Timer? _maxDurationTimer;
  final List<String> _savedChunks = [];
  final List<String> _uploadedChunkUrls = [];
  FaceEvidenceProcessor? _faceProcessor;
  Future<void>? _faceProcessorInitFuture;
  List<CameraDescription>? _cachedCameras;
  final List<_FaceChunkTask> _faceQueue = [];
  bool _isFaceWorkerRunning = false;
  Completer<void>? _faceQueueDrainCompleter;

  static const int _maxFaceQueueLength = 120;

  // Callback fired when recording auto-stops at 5 min
  // EvidenceService sets this so it can trigger stopEvidence()
  Function()? onMaxDurationReached;

  static const Duration _chunkDuration = Duration(seconds: 10);
  static const Duration _maxRecordingDuration = Duration(minutes: 5);

  bool get isRecording => _isRecording;
  List<String> get savedChunks => List.unmodifiable(_savedChunks);
  List<String> get uploadedChunkUrls => List.unmodifiable(_uploadedChunkUrls);

  // Returns a shareable summary URL — link to first chunk as proof of evidence
  // In a real app you'd generate a Cloudinary folder URL
  String? get evidenceSummaryUrl =>
      _uploadedChunkUrls.isNotEmpty ? _uploadedChunkUrls.first : null;

  // ── Start recording ────────────────────────────────────────────────────────

  /// Pre-initialize camera resources to reduce latency when starting recording.
  Future<void> prewarmCamera() async {
    try {
      if (_controller != null && _controller!.value.isInitialized) return;
      _cachedCameras ??= await availableCameras();
      if (_cachedCameras == null || _cachedCameras!.isEmpty) return;
      final camera = _cachedCameras!.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cachedCameras!.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.low,
        enableAudio: true,
      );
      final t = Stopwatch()..start();
      await _controller!.initialize();
      t.stop();
      print('prewarmCamera initialization took ${t.elapsedMilliseconds}ms');
      // Do not start recording here; just warm up the controller
    } catch (e) {
      print('prewarmCamera error: $e');
      // leave controller null on failure
    }
  }

  Future<void> startRecording(String evidenceDir, {String? sosId}) async {
    if (_isRecording) return;
    final startupTimer = Stopwatch()..start();
    _evidenceDir = evidenceDir;
    _currentSosId = sosId;
    _chunkIndex = 0;
    _savedChunks.clear();
    _uploadedChunkUrls.clear();

    try {
      // Use cached cameras when available; prewarmCamera() can populate this
      final cameraTimer = Stopwatch()..start();
      final cameras = _cachedCameras ?? await availableCameras();
      cameraTimer.stop();
      print('availableCameras took ${cameraTimer.elapsedMilliseconds}ms');
      if (cameras.isEmpty) {
        print('No cameras available');
        return;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      if (_controller == null || !_controller!.value.isInitialized) {
        _controller = CameraController(
          camera,
          ResolutionPreset.low,
          enableAudio: true,
        );

        final controllerInitTimer = Stopwatch()..start();
        await _controller!.initialize();
        controllerInitTimer.stop();
        print(
          'CameraController.initialize took ${controllerInitTimer.elapsedMilliseconds}ms',
        );
      }
      _isRecording = true;

      final firstChunkTimer = Stopwatch()..start();
      await _startChunk();
      firstChunkTimer.stop();
      print('First chunk start took ${firstChunkTimer.elapsedMilliseconds}ms');

      // Warm up face pipeline asynchronously so recording start is not blocked.
      Future.microtask(() => _ensureFaceProcessorReady());

      _chunkTimer = Timer.periodic(_chunkDuration, (_) async {
        if (_isRecording) await _rotateChunk();
      });

      // Auto stop at 5 minutes — fires onMaxDurationReached callback
      _maxDurationTimer = Timer(_maxRecordingDuration, () async {
        print('Max duration reached — auto stopping evidence');
        await stopRecording();
        onMaxDurationReached?.call();
      });

      print(
        'Recording started — ${_chunkDuration.inSeconds}s chunks, max ${_maxRecordingDuration.inMinutes} min',
      );
      startupTimer.stop();
      print(
        'Total recording startup took ${startupTimer.elapsedMilliseconds}ms',
      );
    } catch (e) {
      print('Video recording error: $e');
      _isRecording = false;
      _controller?.dispose();
      _controller = null;
    }
  }

  // ── Stop recording ─────────────────────────────────────────────────────────

  Future<List<String>> stopRecording() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    _maxDurationTimer?.cancel();
    _maxDurationTimer = null;

    if (!_isRecording || _controller == null) return _savedChunks;

    try {
      // Save the last chunk but do not start a new one
      await _saveAndUploadCurrentChunk(startNext: false);
    } catch (e) {
      print('Video stop error: $e');
    }

    // Ensure queued local chunks are processed for faces before disposing processor.
    try {
      await _waitForFaceQueueDrain();
    } catch (e) {
      print('Face queue drain error: $e');
    }

    // Dispose face processor after all chunks are done
    if (_faceProcessor != null) {
      try {
        _faceProcessor!.dispose();
      } catch (e) {
        print('Face processor dispose error: $e');
      }
      _faceProcessor = null;
    }
    _faceProcessorInitFuture = null;

    _controller?.dispose();
    _controller = null;
    _isRecording = false;

    print(
      'Recording stopped. Saved: ${_savedChunks.length}, uploaded: ${_uploadedChunkUrls.length}',
    );
    return _savedChunks;
  }

  // ── Chunk helpers ──────────────────────────────────────────────────────────

  Future<void> _startChunk() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      await _controller!.startVideoRecording();
      print('Started chunk ${_chunkIndex + 1}');
    } catch (e) {
      print('_startChunk error: $e');
    }
  }

  Future<void> _rotateChunk() async {
    if (_controller == null) return;
    try {
      // Stop current chunk, start next immediately to avoid audio/video gaps
      await _saveAndUploadCurrentChunk(startNext: true);
    } catch (e) {
      print('_rotateChunk error: $e');
    }
  }

  Future<void> _saveAndUploadCurrentChunk({bool startNext = true}) async {
    if (_controller == null || !_controller!.value.isRecordingVideo) return;
    try {
      final file = await _controller!.stopVideoRecording();
      _chunkIndex++;

      final chunkPath =
          '$_evidenceDir/chunk_${_chunkIndex.toString().padLeft(3, '0')}.mp4';
      await File(file.path).copy(chunkPath);
      _savedChunks.add(chunkPath);
      print('Saved chunk $_chunkIndex locally');

      final currentChunkIndex = _chunkIndex;
      final currentSosId = _currentSosId ?? 'unknown';

      _enqueueFaceChunk(
        _FaceChunkTask(
          chunkPath: chunkPath,
          sosId: currentSosId,
          chunkNum: currentChunkIndex,
        ),
      );

      // Start next recording immediately to minimize gaps
      if (startNext) {
        Future.microtask(() => _startChunk());
      }

      // Upload in background so recording isn't delayed.
      Future(() async {
        try {
          await _uploadChunkToCloud(chunkPath, currentChunkIndex);
        } catch (e) {
          print('Chunk $currentChunkIndex cloud error: $e');
        }
      });
    } catch (e) {
      print('_saveAndUploadCurrentChunk error: $e');
    }
  }

  void _enqueueFaceChunk(_FaceChunkTask task) {
    if (_faceQueue.length >= _maxFaceQueueLength) {
      print(
        'Face queue full (${_faceQueue.length}). Skipping chunk ${task.chunkNum} to protect recording performance.',
      );
      return;
    }

    _faceQueue.add(task);
    _faceQueueDrainCompleter ??= Completer<void>();
    Future.microtask(() => _runFaceWorker());
  }

  Future<void> _runFaceWorker() async {
    if (_isFaceWorkerRunning) {
      return;
    }

    _isFaceWorkerRunning = true;

    try {
      await _ensureFaceProcessorReady();

      while (_faceQueue.isNotEmpty) {
        final task = _faceQueue.removeAt(0);
        final chunkTimer = Stopwatch()..start();

        if (_faceProcessor != null) {
          try {
            await _faceProcessor!.processChunk(task.chunkPath, task.sosId);
          } catch (e) {
            print(
              'Face evidence processing error for chunk ${task.chunkNum}: $e',
            );
          }
        } else {
          print('Face processor unavailable for chunk ${task.chunkNum}');
        }

        chunkTimer.stop();
        print(
          'Face processing for chunk ${task.chunkNum} took ${chunkTimer.elapsedMilliseconds}ms',
        );
      }
    } finally {
      _isFaceWorkerRunning = false;

      if (_faceQueue.isEmpty) {
        if (_faceQueueDrainCompleter != null &&
            !_faceQueueDrainCompleter!.isCompleted) {
          _faceQueueDrainCompleter!.complete();
        }
        _faceQueueDrainCompleter = null;
      } else {
        // Safety retry if queue received new tasks while finalizing.
        Future.microtask(() => _runFaceWorker());
      }
    }
  }

  Future<void> _waitForFaceQueueDrain() async {
    if (_faceQueue.isEmpty && !_isFaceWorkerRunning) {
      return;
    }

    _faceQueueDrainCompleter ??= Completer<void>();
    await _faceQueueDrainCompleter!.future;
  }

  Future<void> _ensureFaceProcessorReady() async {
    if (_faceProcessor != null) return;
    if (_faceProcessorInitFuture != null) {
      await _faceProcessorInitFuture;
      return;
    }

    _faceProcessorInitFuture = _initializeFaceProcessor();
    await _faceProcessorInitFuture;
  }

  Future<void> _initializeFaceProcessor() async {
    try {
      final initTimer = Stopwatch()..start();
      final processor = FaceEvidenceProcessor();
      await processor.init();
      _faceProcessor = processor;
      initTimer.stop();
      print('Face processor init took ${initTimer.elapsedMilliseconds}ms');
    } catch (e) {
      print('Face processor init error: $e');
      _faceProcessor = null;
      rethrow;
    }
  }

  Future<void> _uploadChunkToCloud(String chunkPath, int chunkNum) async {
    try {
      final sosId = _currentSosId ?? 'unknown';
      final url = await CloudinaryService().uploadVideoChunk(
        chunkPath,
        sosId,
        chunkNum,
      );
      if (url != null) {
        _uploadedChunkUrls.add(url);
        print('Chunk $chunkNum uploaded: $url');
      }
    } catch (e) {
      print('_uploadChunkToCloud error for chunk $chunkNum: $e');
    }
  }

  void dispose() {
    _chunkTimer?.cancel();
    _maxDurationTimer?.cancel();
    if (_faceProcessor != null) {
      _faceProcessor!.dispose();
      _faceProcessor = null;
    }
    _faceProcessorInitFuture = null;
    _faceQueue.clear();
    _isFaceWorkerRunning = false;
    _faceQueueDrainCompleter = null;
    _controller?.dispose();
    _controller = null;
    _isRecording = false;
  }
}

class _FaceChunkTask {
  final String chunkPath;
  final String sosId;
  final int chunkNum;

  _FaceChunkTask({
    required this.chunkPath,
    required this.sosId,
    required this.chunkNum,
  });
}
