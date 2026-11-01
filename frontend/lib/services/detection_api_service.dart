import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class DetectionResult {
  final String routeNumber;
  final double confidence;
  final bool detected;
  final bool busInGuidanceZone;

  DetectionResult({
    required this.routeNumber,
    required this.confidence,
    required this.detected,
    this.busInGuidanceZone = false,
  });

  factory DetectionResult.fromJson(Map<String, dynamic> json) {
    return DetectionResult(
      routeNumber: json['route_number'] ?? '',
      confidence: (json['confidence'] ?? 0.0).toDouble(),
      detected: json['detected'] ?? false,
      busInGuidanceZone: json['bus_in_guidance_zone'] == true,
    );
  }
}

class DetectionApiService {
  final String baseUrl;
  final Duration requestTimeout;
  final http.Client Function() _clientFactory;
  final Set<http.Client> _pendingClients = {};
  bool _closed = false;

  DetectionApiService({
    this.baseUrl = 'https://buss-detection-api.lemondune-fdb5e830.polandcentral.azurecontainerapps.io',
    this.requestTimeout = const Duration(seconds: 30),
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  Future<DetectionResult?> processFrameBytes(Uint8List imageBytes) async {
    if (_closed) return null;
    final client = _clientFactory();
    _pendingClients.add(client);
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

      // Bound the entire response, including its body, and close the client on
      // timeout so a lost connection cannot leave a frame request hanging.
      final response = await (() async {
        final streamedResponse = await client.send(request);
        return http.Response.fromStream(streamedResponse);
      })().timeout(requestTimeout);

      if (_closed || !_pendingClients.contains(client)) return null;

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);

        return DetectionResult.fromJson(data);
      }

      return null;
    } catch (e) {
      return null;
    } finally {
      _pendingClients.remove(client);
      client.close();
    }
  }

  void cancelPending() {
    final clients = _pendingClients.toList();
    _pendingClients.clear();
    for (final client in clients) {
      client.close();
    }
  }

  void dispose() {
    _closed = true;
    cancelPending();
  }
}
