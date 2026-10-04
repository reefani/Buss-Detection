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
  // Replace with your Mac's local IP address when testing on a physical device (e.g., http://192.168.1.X:8000)
  final String baseUrl;

  DetectionApiService({this.baseUrl = 'http://127.0.0.1:8000'});

  /// Sends captured image bytes (JPEG) to the FastAPI backend for detection
  Future<DetectionResult?> processFrame(Uint8List imageBytes) async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/detect');
      
      // Base64 encoding payload format
      final base64Image = base64Encode(imageBytes);
      
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'image': base64Image,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        return DetectionResult.fromJson(data);
      } else {
        return null;
      }
    } catch (e) {
      return null;
    }
  }
}