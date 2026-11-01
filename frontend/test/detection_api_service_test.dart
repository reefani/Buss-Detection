import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/detection_api_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('guidance parses independently of route recognition', () {
    final result = DetectionResult.fromJson({
      'detected': false,
      'route_number': '',
      'confidence': 0,
      'bus_in_guidance_zone': true,
    });
    expect(result.detected, isFalse);
    expect(result.busInGuidanceZone, isTrue);
    expect(result.routeNumber, isEmpty);
    expect(result.confidence, 0.0);
    expect(DetectionResult.fromJson({}).busInGuidanceZone, isFalse);
    expect(
      DetectionResult.fromJson({'bus_in_guidance_zone': 'true'})
          .busInGuidanceZone,
      isFalse,
    );
  });

  test('uploads a JPEG and preserves route and guidance fields', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/detect');
      expect(request.headers['content-type'], contains('multipart/form-data'));
      expect(utf8.decode(request.bodyBytes), contains('frame.jpg'));
      return http.Response(
        jsonEncode({
          'detected': true,
          'route_number': '730',
          'confidence': 0.0,
          'bus_in_guidance_zone': true,
        }),
        200,
      );
    });
    final api = DetectionApiService(clientFactory: () => client);
    final result = await api.processFrameBytes(Uint8List.fromList([1, 2]));
    expect(result?.routeNumber, '730');
    expect(result?.detected, isTrue);
    expect(result?.busInGuidanceZone, isTrue);
    api.dispose();
  });

  test('HTTP failure, invalid JSON and network failure return null', () async {
    for (final handler in <Future<http.Response> Function(http.Request)>[
      (_) async => http.Response('unavailable', 503),
      (_) async => http.Response('not JSON', 200),
      (_) async => throw http.ClientException('offline'),
    ]) {
      final api = DetectionApiService(clientFactory: () => MockClient(handler));
      expect(await api.processFrameBytes(Uint8List(0)), isNull);
      api.dispose();
    }
  });

  test('timeout includes a stalled response body and closes client', () async {
    final body = StreamController<List<int>>();
    final client = _TrackedClient(
      (_) async => http.StreamedResponse(body.stream, 200),
    );
    final api = DetectionApiService(
      clientFactory: () => client,
      requestTimeout: const Duration(milliseconds: 10),
    );
    expect(await api.processFrameBytes(Uint8List(0)), isNull);
    expect(client.closed, isTrue);
    await body.close();
    api.dispose();
  });

  test(
    'cancelled and disposed requests cannot return delayed results',
    () async {
      final pending = Completer<http.StreamedResponse>();
      final client = _TrackedClient((_) => pending.future);
      final api = DetectionApiService(clientFactory: () => client);
      final result = api.processFrameBytes(Uint8List(0));
      api.cancelPending();
      expect(client.closed, isTrue);
      pending.complete(
        http.StreamedResponse(
          Stream.value(utf8.encode('{"bus_in_guidance_zone":true}')),
          200,
        ),
      );
      expect(await result, isNull);
      api.dispose();
      expect(await api.processFrameBytes(Uint8List(0)), isNull);
    },
  );
}

class _TrackedClient extends http.BaseClient {
  _TrackedClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);

  @override
  void close() => closed = true;
}
