import 'dart:convert';

import 'package:http/http.dart' as http;

class FaceCloudinaryUploader {
  static Future<String> upload(
    List<int> imageBytes, {
    required String sosId,
    required int faceIndex,
  }) async {
    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/dgacqctuu/image/upload',
    );

    final request = http.MultipartRequest('POST', uri)
      ..fields['upload_preset'] = 'nari_shakti_preset'
      ..fields['folder'] = 'faces/$sosId'
      ..fields['public_id'] = 'face_${faceIndex.toString().padLeft(3, '0')}'
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: 'face_$faceIndex.jpg',
        ),
      );

    final response = await request.send();
    final body = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      throw Exception('Cloudinary upload failed: ${response.statusCode} $body');
    }

    final decoded = jsonDecode(body) as Map<String, dynamic>;
    return decoded['secure_url'] as String;
  }
}
