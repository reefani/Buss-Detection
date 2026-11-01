import 'dart:async';
import 'dart:typed_data';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/detection_screen.dart';
import 'package:frontend/services/detection_api_service.dart';
import 'package:frontend/services/haptic_guidance_service.dart';
import 'package:frontend/services/tts_service.dart';

class _Camera extends CameraPlatform {
  final frames = <int, StreamController<CameraImageData>>{};
  final errors = <int, StreamController<CameraErrorEvent>>{};
  final disposed = <int>[];
  final streamStarts = <int>[];
  Completer<void>? initializationGate;
  int created = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
    CameraDescription(
      name: 'test back camera',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];

  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async {
    final id = ++created;
    frames[id] = StreamController<CameraImageData>.broadcast(sync: true);
    errors[id] = StreamController<CameraErrorEvent>.broadcast(sync: true);
    return id;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    await initializationGate?.future;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          640,
          480,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      errors[cameraId]!.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    streamStarts.add(cameraId);
    return frames[cameraId]!.stream;
  }

  @override
  Widget buildPreview(int cameraId) =>
      const ColoredBox(color: Colors.black, key: Key('fake camera preview'));

  @override
  Future<void> dispose(int cameraId) async {
    disposed.add(cameraId);
    // Finish CameraController's one-shot error subscription after disposal.
    errors[cameraId]!.add(CameraErrorEvent(cameraId, 'disposed'));
    await errors[cameraId]!.close();
    await frames[cameraId]!.close();
  }

  void emitFrame() {
    frames[created]!.add(
      CameraImageData(
        format: const CameraImageFormat(ImageFormatGroup.jpeg, raw: 256),
        planes: [
          CameraImagePlane(
            bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
            bytesPerRow: 4,
          ),
        ],
        height: 1,
        width: 1,
      ),
    );
  }
}

class _Api extends DetectionApiService {
  final requests = <Completer<DetectionResult?>>[];
  int cancellations = 0;
  bool closed = false;

  @override
  Future<DetectionResult?> processFrameBytes(Uint8List imageBytes) {
    final request = Completer<DetectionResult?>();
    requests.add(request);
    return request.future;
  }

  @override
  void cancelPending() => cancellations++;

  @override
  void dispose() => closed = true;
}

class _Tts extends TtsService {
  final routes = <String>[];
  final utterances = <Completer<bool>>[];
  int stops = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> speakRouteNumber(String routeNumber) {
    routes.add(routeNumber);
    final utterance = Completer<bool>();
    utterances.add(utterance);
    return utterance.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    // Keep speech pending so tests can deliver a late native completion.
  }
}

class _Motor implements GuidanceVibrationBackend {
  bool running = false;
  int starts = 0;
  int cancellations = 0;

  @override
  Future<bool> hasVibrator() async => true;

  @override
  Future<void> vibrate({
    required List<int> pattern,
    required int repeat,
  }) async {
    running = true;
    starts++;
  }

  @override
  Future<void> cancel() async {
    running = false;
    cancellations++;
  }
}

DetectionResult _result({bool guidance = true, String route = ''}) =>
    DetectionResult(
      detected: route.isNotEmpty,
      routeNumber: route,
      confidence: 0,
      busInGuidanceZone: guidance,
    );

class _Harness {
  _Harness(this.tester) {
    haptics = HapticGuidanceService(
      backend: motor,
      now: tester.binding.clock.now,
    );
  }

  final WidgetTester tester;
  final camera = _Camera();
  final api = _Api();
  final tts = _Tts();
  final motor = _Motor();
  final navigator = GlobalKey<NavigatorState>();
  late final HapticGuidanceService haptics;

  Future<void> open() async {
    CameraPlatform.instance = camera;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('home')),
        routes: {
          '/detection': (_) => DetectionScreen(
            apiService: api,
            ttsService: tts,
            hapticGuidanceService: haptics,
            now: tester.binding.clock.now,
          ),
        },
      ),
    );
    unawaited(navigator.currentState!.pushNamed('/detection'));
    await flush();
    await tester.pump(const Duration(milliseconds: 350));
    await flush();
  }

  Future<void> flush() async {
    // Camera stream cancellation may return a root-zone completion future.
    // Drain that event turn as well as Flutter's controlled microtasks.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (var attempt = 0; attempt < 4; attempt++) {
      await tester.pump();
    }
  }

  Future<Completer<DetectionResult?>> capture() async {
    // The screen deliberately limits frame requests to every 300 ms.
    await tester.pump(const Duration(milliseconds: 301));
    final before = api.requests.length;
    camera.emitFrame();
    await flush();
    expect(api.requests, hasLength(before + 1));
    return api.requests.last;
  }

  Future<void> frame(DetectionResult? result) async {
    final request = await capture();
    request.complete(result);
    await flush();
  }

  Future<void> cleanup() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush();
    for (final request in api.requests) {
      if (!request.isCompleted) request.complete(null);
    }
    for (final utterance in tts.utterances) {
      if (!utterance.isCompleted) utterance.complete(false);
    }
    await flush();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalCamera = CameraPlatform.instance;

  tearDown(() {
    CameraPlatform.instance = originalCamera;
  });

  testWidgets(
    'frames keep guidance current during speech and latch on completion',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();

      await harness.frame(_result(route: '42'));
      expect(harness.tts.routes, ['42']);
      expect(harness.motor.running, isTrue);
      expect(find.text('حافلة رقم: 42'), findsOneWidget);

      // Speech remains pending, but zone loss and return still get fresh frames.
      await harness.frame(_result(guidance: false, route: '42'));
      expect(harness.motor.running, isFalse);
      await harness.frame(_result(route: '42'));
      expect(harness.motor.running, isTrue);
      expect(harness.api.requests, hasLength(3));
      expect(harness.tts.utterances, hasLength(1));

      harness.tts.utterances.single.complete(true);
      await harness.flush();
      expect(harness.motor.running, isFalse);
      final starts = harness.motor.starts;
      await harness.frame(_result(route: '42'));
      expect(harness.motor.starts, starts);
      expect(harness.motor.running, isFalse);

      await harness.cleanup();
    },
  );

  testWidgets('failed speech does not permanently disable guidance', (
    tester,
  ) async {
    final harness = _Harness(tester);
    await harness.open();
    await harness.frame(_result(route: '42'));
    harness.tts.utterances.single.complete(false);
    await harness.flush();

    await harness.frame(_result(guidance: false));
    expect(harness.motor.running, isFalse);
    await harness.frame(_result());
    expect(harness.motor.running, isTrue);

    await harness.cleanup();
  });

  testWidgets(
    'backend failure immediately stops guidance and recovery resumes it',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result());
      expect(harness.motor.running, isTrue);

      await harness.frame(null);
      expect(harness.motor.running, isFalse);
      await harness.frame(_result());
      expect(harness.motor.running, isTrue);

      await harness.cleanup();
    },
  );

  testWidgets(
    'watchdog stops guidance and rejects a response captured too long ago',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result());
      final slowRequest = await harness.capture();
      await tester.pump(const Duration(seconds: 4));
      await harness.flush();
      expect(harness.motor.running, isFalse);

      final starts = harness.motor.starts;
      slowRequest.complete(_result(route: '42'));
      await harness.flush();
      expect(harness.motor.starts, starts);
      expect(harness.tts.routes, isEmpty);
      await harness.frame(_result());
      expect(harness.motor.running, isTrue);

      await harness.cleanup();
    },
  );

  testWidgets(
    'background cancels guidance and resume rejects previous responses',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result());
      final previousRequest = await harness.capture();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await harness.flush();
      expect(harness.motor.running, isFalse);
      expect(harness.api.cancellations, 1);
      expect(harness.camera.disposed, [1]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await harness.flush();
      expect(harness.camera.streamStarts, [1, 2]);
      previousRequest.complete(_result(route: 'obsolete'));
      await harness.flush();
      expect(harness.motor.running, isFalse);
      expect(harness.tts.routes, isEmpty);

      await harness.frame(_result());
      expect(harness.motor.running, isTrue);
      await harness.cleanup();
    },
  );

  testWidgets('speech completion remains latched after background and resume', (
    tester,
  ) async {
    final harness = _Harness(tester);
    await harness.open();
    await harness.frame(_result(route: '42'));
    harness.tts.utterances.single.complete(true);
    await harness.flush();
    final starts = harness.motor.starts;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await harness.flush();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await harness.flush();
    await harness.frame(_result());
    expect(harness.motor.running, isFalse);
    expect(harness.motor.starts, starts);

    await harness.cleanup();
  });

  for (final stopButton in [false, true]) {
    testWidgets(
      '${stopButton ? 'stop control' : 'screen pop'} blocks late results',
      (tester) async {
        final harness = _Harness(tester);
        await harness.open();
        await harness.frame(_result(route: '42'));
        final pending = await harness.capture();
        if (stopButton) {
          await tester.tap(find.byIcon(Icons.stop));
        } else {
          await harness.navigator.currentState!.maybePop();
        }
        await harness.flush();
        expect(harness.motor.running, isFalse);
        expect(harness.api.closed, isTrue);
        final starts = harness.motor.starts;
        pending.complete(_result(route: 'obsolete'));
        harness.tts.utterances.single.complete(true);
        await tester.pump(const Duration(milliseconds: 350));
        await harness.flush();
        expect(harness.motor.starts, starts);
        expect(harness.tts.routes, ['42']);
        expect(find.text('home'), findsOneWidget);
        expect(harness.camera.disposed, [1]);

        await harness.cleanup();
      },
    );
  }

  testWidgets(
    'a camera finishing initialization after exit never starts streaming',
    (tester) async {
      final harness = _Harness(tester);
      final gate = Completer<void>();
      harness.camera.initializationGate = gate;
      await harness.open();
      expect(harness.camera.created, 1);
      expect(harness.camera.streamStarts, isEmpty);

      await tester.tap(find.byIcon(Icons.stop));
      await harness.flush();
      gate.complete();
      await tester.pump(const Duration(milliseconds: 350));
      await harness.flush();
      expect(harness.camera.streamStarts, isEmpty);
      expect(harness.camera.disposed, [1]);
      expect(harness.api.requests, isEmpty);
      expect(harness.motor.starts, 0);

      await harness.cleanup();
    },
  );
}
