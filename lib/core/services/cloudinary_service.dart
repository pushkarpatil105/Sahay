import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

class CloudinaryService {
  static final CloudinaryService _instance = CloudinaryService._internal();
  factory CloudinaryService() => _instance;
  CloudinaryService._internal();

  static const String _cloudName = 'dgacqctuu';
  static const String _uploadPreset = 'nari_shakti_preset';

  // ── Generic upload ─────────────────────────────────────────────────────────

  Future<String?> uploadFile(
    String filePath, {
    String? resourceType,
    String? publicId, // use this instead of folder — works on free plan
  }) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        print('File not found: $filePath');
        return null;
      }

      final detectedType = resourceType ?? _detectResourceType(filePath);

      final uri = Uri.parse(
          'https://api.cloudinary.com/v1_1/$_cloudName/$detectedType/upload');

      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = _uploadPreset
        ..files.add(await http.MultipartFile.fromPath('file', filePath));

      // public_id controls the path in Cloudinary — works on free unsigned preset
      // e.g. nari_shakti/sos_123456/chunks/chunk_001
      if (publicId != null) {
        request.fields['public_id'] = publicId;
      }

      final response = await request.send().timeout(
            const Duration(seconds: 60),
          );

      final body = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final json = jsonDecode(body);
        final url = json['secure_url'] as String?;
        print('Uploaded: $url');
        return url;
      } else {
        print('Cloudinary upload failed: ${response.statusCode} — $body');
        return null;
      }
    } catch (e) {
      print('Cloudinary error: $e');
      return null;
    }
  }

  // ── ZIP upload ─────────────────────────────────────────────────────────────
  // Path in Cloudinary: nari_shakti/{sosId}/evidence

  Future<String?> uploadZip(String zipPath, String sosId) async {
    final cleanId = _cleanId(sosId);
    print('Uploading ZIP for sosId=$sosId');
    return await uploadFile(
      zipPath,
      resourceType: 'raw',
      publicId: 'nari_shakti/$cleanId/evidence',
    );
  }

  // ── Video chunk upload ─────────────────────────────────────────────────────
  // Path in Cloudinary: nari_shakti/{sosId}/chunks/chunk_001

  Future<String?> uploadVideoChunk(
      String chunkPath, String sosId, int chunkNum) async {
    final cleanId = _cleanId(sosId);
    final chunkName = 'chunk_${chunkNum.toString().padLeft(3, '0')}';
    print('Uploading chunk $chunkNum for sosId=$sosId');
    return await uploadFile(
      chunkPath,
      resourceType: 'video',
      publicId: 'nari_shakti/$cleanId/chunks/$chunkName',
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  // Cloudinary public_id cannot have special chars — sanitize sosId
  String _cleanId(String sosId) {
    return sosId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  }

  String _detectResourceType(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        return 'video';
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return 'image';
      default:
        return 'raw'; // zip, aac, json etc
    }
  }
}