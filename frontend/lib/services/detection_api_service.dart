import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Data model to represent the response coming from FastAPI
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

/// Service class handling network requests to the AI backend
class DetectionApiService {
  // Replace with your Mac's local IP address when testing on a physical iPhone
  final String baseUrl;

  DetectionApiService({this.baseUrl = 'http://192.168.100.244:8000'});

  /// Sends raw frame bytes to FastAPI and returns detection results
  Future<DetectionResult?> processFrameBytes(Uint8List imageBytes) async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/detect');
      final base64Image = base64Encode(imageBytes);

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'image': base64Image,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      ).timeout(const Duration(milliseconds: 1500));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        return DetectionResult.fromJson(data);
      }
      return null;
    } catch (e) {
      // Handles network timeouts or connection issues gracefully
      return null;
    }
  }
}