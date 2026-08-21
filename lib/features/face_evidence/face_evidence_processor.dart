import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'face_cloudinary_uploader.dart';
import 'face_evidence_repository.dart';

class FaceEvidenceProcessor {
  static const double _identityMatchThreshold = 0.67;
  static const int _maxEmbeddingsPerIdentity = 5;

  late FaceDetector _faceDetector;
  late Interpreter _faceNetInterpreter;
  final List<List<List<double>>> _identityEmbeddings = [];

  Future<void> init() async {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate),
    );
    _faceNetInterpreter = await Interpreter.fromAsset(
      'assets/models/facenet.tflite',
    );
  }

  Future<void> processChunk(String videoPath, String sosId) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final frameFiles = <File>[];

      // Extract frame at every second â€” loop up to max chunk duration (10s) + buffer
      // VideoRecordingService creates 10s chunks, so this covers full chunk
      // Last chunk may be shorter, so we try up to 15 seconds to be safe
      var consecutiveNulls = 0;
      for (var second = 0; second < 15; second++) {
        final thumbData = await VideoThumbnail.thumbnailData(
          video: videoPath,
          timeMs: second * 1000,
          imageFormat: ImageFormat.JPEG,
          quality: 90,
        );

        if (thumbData == null) {
          consecutiveNulls++;
          if (consecutiveNulls >= 3) break;
          continue;
        }

        consecutiveNulls = 0;

        final frameFile = File(
          '${tempDir.path}/frame_${DateTime.now().millisecondsSinceEpoch}_$second.jpg',
        );
        await frameFile.writeAsBytes(thumbData, flush: true);
        if (await frameFile.exists()) {
          frameFiles.add(frameFile);
        }
      }

      print('Extracted ${frameFiles.length} frames from chunk');

      for (final frameFile in frameFiles) {
        await _processFrame(frameFile, sosId);
      }
    } catch (e) {
      print('FaceEvidenceProcessor.processChunk error: $e');
    }
  }

  Future<void> _processFrame(File frameFile, String sosId) async {
    try {
      if (!await frameFile.exists()) {
        print('Frame file missing, skipping: ${frameFile.path}');
        return;
      }

      final inputImage = InputImage.fromFilePath(frameFile.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        if (await frameFile.exists()) {
          await frameFile.delete();
        }
        return;
      }

      final imageBytes = await frameFile.readAsBytes();

      for (var faceIndex = 0; faceIndex < faces.length; faceIndex++) {
        final face = faces[faceIndex];
        final faceBytes = _cropFace(imageBytes, face.boundingBox);

        if (faceBytes == null) {
          continue;
        }

        final embedding = _getEmbedding(faceBytes);
        final identityResult = _matchOrCreateIdentity(embedding);
        if (!identityResult.isNewIdentity) {
          continue;
        }

        final cumulativeFaceIndex = identityResult.identityIndex + 1;

        await _writeFaceFile(faceBytes, sosId, cumulativeFaceIndex);
        final cloudUrl = await FaceCloudinaryUploader.upload(
          faceBytes,
          sosId: sosId,
          faceIndex: cumulativeFaceIndex,
        );

        await FaceEvidenceRepository.save(
          sosId: sosId,
          faceUrl: cloudUrl,
          embedding: embedding,
          detectedAt: DateTime.now(),
        );
      }
    } catch (e) {
      print('FaceEvidenceProcessor._processFrame error: $e');
    } finally {
      if (await frameFile.exists()) {
        await frameFile.delete();
      }
    }
  }

  List<int>? _cropFace(List<int> imageBytes, Rect boundingBox) {
    final decoded = img.decodeImage(Uint8List.fromList(imageBytes));
    if (decoded == null) {
      return null;
    }

    final left = max(0, boundingBox.left.floor());
    final top = max(0, boundingBox.top.floor());
    final right = min(decoded.width, boundingBox.right.ceil());
    final bottom = min(decoded.height, boundingBox.bottom.ceil());

    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) {
      return null;
    }

    final cropped = img.copyCrop(
      decoded,
      x: left,
      y: top,
      width: width,
      height: height,
    );
    return img.encodeJpg(cropped);
  }

  List<double> _getEmbedding(List<int> faceBytes) {
    final decoded = img.decodeImage(Uint8List.fromList(faceBytes));
    if (decoded == null) {
      return List<double>.filled(128, 0.0);
    }

    final resized = img.copyResize(decoded, width: 160, height: 160);

    final input = List.generate(
      1,
      (_) => List.generate(
        160,
        (y) => List.generate(160, (x) {
          final pixel = resized.getPixelSafe(x, y);
          final red = (pixel.r.toDouble() - 128.0) / 128.0;
          final green = (pixel.g.toDouble() - 128.0) / 128.0;
          final blue = (pixel.b.toDouble() - 128.0) / 128.0;
          return <double>[red, green, blue];
        }),
      ),
    );

    final output = List.generate(1, (_) => List<double>.filled(128, 0.0));
    _faceNetInterpreter.run(input, output);

    return output.first.map((value) => value.toDouble()).toList();
  }

  _IdentityMatchResult _matchOrCreateIdentity(List<double> embedding) {
    if (_identityEmbeddings.isEmpty) {
      _identityEmbeddings.add([embedding]);
      return const _IdentityMatchResult(identityIndex: 0, isNewIdentity: true);
    }

    var bestIdentityIndex = -1;
    var bestSimilarity = -1.0;

    for (
      var identityIndex = 0;
      identityIndex < _identityEmbeddings.length;
      identityIndex++
    ) {
      final prototypes = _identityEmbeddings[identityIndex];
      for (final storedEmbedding in prototypes) {
        final similarity = _cosineSimilarity(embedding, storedEmbedding);
        if (similarity > bestSimilarity) {
          bestSimilarity = similarity;
          bestIdentityIndex = identityIndex;
        }
      }
    }

    if (bestIdentityIndex != -1 && bestSimilarity >= _identityMatchThreshold) {
      final prototypes = _identityEmbeddings[bestIdentityIndex];
      prototypes.add(embedding);
      if (prototypes.length > _maxEmbeddingsPerIdentity) {
        prototypes.removeAt(0);
      }
      return _IdentityMatchResult(
        identityIndex: bestIdentityIndex,
        isNewIdentity: false,
      );
    }

    _identityEmbeddings.add([embedding]);
    return _IdentityMatchResult(
      identityIndex: _identityEmbeddings.length - 1,
      isNewIdentity: true,
    );
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) {
      return 0.0;
    }

    var dot = 0.0;
    var magnitudeA = 0.0;
    var magnitudeB = 0.0;

    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      magnitudeA += a[i] * a[i];
      magnitudeB += b[i] * b[i];
    }

    final denominator = sqrt(magnitudeA) * sqrt(magnitudeB);
    if (denominator == 0) {
      return 0.0;
    }

    return dot / denominator;
  }

  Future<File> _writeFaceFile(
    List<int> faceBytes,
    String sosId,
    int faceIndex,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final fileName =
        'face_${_sanitizeForFileName(sosId)}_${DateTime.now().millisecondsSinceEpoch}_$faceIndex.jpg';
    final faceFile = File('${tempDir.path}/$fileName');
    await faceFile.writeAsBytes(faceBytes, flush: true);
    return faceFile;
  }

  String _sanitizeForFileName(String value) {
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  }

  void dispose() {
    _faceDetector.close();
    _faceNetInterpreter.close();
    _identityEmbeddings.clear();
  }
}

class _IdentityMatchResult {
  final int identityIndex;
  final bool isNewIdentity;

  const _IdentityMatchResult({
    required this.identityIndex,
    required this.isNewIdentity,
  });
}


