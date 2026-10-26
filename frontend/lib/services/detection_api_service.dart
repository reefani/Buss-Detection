import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class DetectionResult {
  final String routeNumber;
  final double confidence;
  final bool detected;

  DetectionResult({
    required this.routeNumber,
    required this.confidence,
    required this.detected,
  });

  factory DetectionResult.fromJson(Map<String, dynamic> json) {
    return DetectionResult(
      routeNumber: json['route_number'] ?? '',
      confidence: (json['confidence'] ?? 0.0).toDouble(),
      detected: json['detected'] ?? false,
    );
  }
}

class DetectionApiService {
  final String baseUrl;

  DetectionApiService({
    this.baseUrl = 'https://buss-detection-api.lemondune-fdb5e830.polandcentral.azurecontainerapps.io',
  });

  Future<DetectionResult?> processFrameBytes(Uint8List imageBytes) async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/detect');

      final request = http.MultipartRequest('POST', uri);

      request.files.add(
        http.MultipartFile.fromBytes(
          'image',
          imageBytes,
          filename: 'frame.jpg',
        ),
      );

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30),
      );

      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);

        return DetectionResult.fromJson(data);
      }

      return null;
    } catch (e) {
      return null;
    }
  }
}
