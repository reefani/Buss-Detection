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
  final instructionUtterances = <Completer<bool>>[];
  final events = <String>[];
  Completer<void>? initializeGate;
  Completer<bool>? startGate;
  int initializations = 0;
  int starts = 0;
  int replays = 0;
  int stops = 0;
  String? _lastRoute;

  @override
  Future<void> initialize() async {
    initializations++;
    await initializeGate?.future;
  }

  @override
  Future<bool> speakStartMessage() async {
    starts++;
    events.add('start');
    return await startGate?.future ?? true;
  }

  @override
  Future<bool> speakRouteNumber(String routeNumber) {
    routes.add(routeNumber);
    _lastRoute = routeNumber;
    events.add('route $routeNumber');
    final utterance = Completer<bool>();
    utterances.add(utterance);
    return utterance.future;
  }

  @override
  Future<bool> speakInstruction() {
    events.add('instructions');
    final utterance = Completer<bool>();
    instructionUtterances.add(utterance);
    return utterance.future;
  }

  @override
  Future<bool> replayLastRoute() {
    if (_lastRoute == null) return Future.value(false);
    replays++;
    events.add('replay $_lastRoute');
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
    for (final utterance in tts.instructionUtterances) {
      if (!utterance.isCompleted) utterance.complete(false);
    }
    final startGate = tts.startGate;
    if (startGate != null && !startGate.isCompleted) {
      startGate.complete(false);
    }
    final initializeGate = tts.initializeGate;
    if (initializeGate != null && !initializeGate.isCompleted) {
      initializeGate.complete();
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
    'delayed TTS setup across background and resume still speaks startup once before the route',
    (tester) async {
      final harness = _Harness(tester);
      harness.tts.initializeGate = Completer<void>();
      harness.tts.startGate = Completer<bool>();
      await harness.open();
      await harness.frame(_result(route: '42'));
      expect(harness.tts.initializations, 1);
      expect(harness.tts.starts, 0);
      expect(harness.tts.routes, isEmpty);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await harness.flush();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await harness.flush();
      await harness.frame(_result(route: '43'));
      expect(harness.camera.streamStarts, [1, 2]);
      expect(harness.motor.running, isTrue);
      expect(harness.tts.initializations, 1);
      expect(harness.tts.starts, 0);

      harness.tts.initializeGate!.complete();
      await harness.flush();
      expect(harness.tts.starts, 1);
      expect(harness.tts.events, ['start']);
      expect(harness.tts.routes, isEmpty);
      harness.tts.startGate!.complete(true);
      await harness.flush();
      expect(harness.tts.events, ['start', 'route 43']);
      expect(harness.tts.initializations, 1);
      expect(harness.tts.starts, 1);

      await harness.cleanup();
    },
  );

  testWidgets(
    'startup speech runs with the camera and only route completion latches guidance',
    (tester) async {
      final harness = _Harness(tester);
      harness.tts.startGate = Completer<bool>();
      await harness.open();
      expect(harness.tts.starts, 1);
      expect(harness.camera.streamStarts, [1]);

      await harness.frame(_result(route: '42'));
      expect(harness.tts.routes, isEmpty);
      expect(harness.motor.running, isTrue);
      expect(find.text('رقم وجهة الباص: 42'), findsOneWidget);
      await harness.frame(_result(guidance: false, route: '42'));
      expect(harness.motor.running, isFalse);
      await harness.frame(_result(route: '42'));
      expect(harness.motor.running, isTrue);

      harness.tts.startGate!.complete(true);
      await harness.flush();
      expect(harness.tts.events, ['start', 'route 42']);
      expect(harness.motor.running, isTrue);
      harness.tts.utterances.single.complete(true);
      await harness.flush();
      expect(harness.motor.running, isFalse);

      await harness.cleanup();
    },
  );

  testWidgets(
    'instructions start five seconds after route completion and play once',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      await tester.pump(const Duration(seconds: 6));
      await harness.flush();
      expect(harness.tts.instructionUtterances, isEmpty);

      harness.tts.utterances.single.complete(true);
      await harness.flush();
      await tester.pump(const Duration(milliseconds: 4999));
      expect(harness.tts.instructionUtterances, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));
      harness.tts.instructionUtterances.single.complete(true);
      await harness.flush();

      await harness.frame(_result(route: '42'));
      expect(harness.tts.routes, ['42']);
      await harness.frame(_result(route: '43'));
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 6));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.cleanup();
    },
  );

  testWidgets(
    'a different route postpones pending instructions until its speech completes',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      harness.tts.utterances.single.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 4));
      await harness.frame(_result(route: '43'));
      expect(harness.tts.routes, ['42', '43']);

      // Cross the original timer deadline while the newer route is speaking.
      await tester.pump(const Duration(seconds: 2));
      await harness.flush();
      expect(harness.tts.instructionUtterances, isEmpty);
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      await tester.pump(const Duration(milliseconds: 4999));
      expect(harness.tts.instructionUtterances, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.cleanup();
    },
  );

  testWidgets('replay is not interrupted by the instruction timer', (
    tester,
  ) async {
    final harness = _Harness(tester);
    await harness.open();
    await harness.frame(_result(route: '42'));
    harness.tts.utterances.single.complete(true);
    await harness.flush();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byIcon(Icons.volume_up));
    await harness.flush();
    expect(harness.tts.replays, 1);

    await tester.pump(const Duration(seconds: 2));
    await harness.flush();
    expect(harness.tts.instructionUtterances, isEmpty);
    harness.tts.utterances.last.complete(true);
    await harness.flush();
    await tester.pump(const Duration(milliseconds: 4999));
    expect(harness.tts.instructionUtterances, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await harness.flush();
    expect(harness.tts.instructionUtterances, hasLength(1));

    await harness.cleanup();
  });

  testWidgets(
    'replay supersedes current speech without accepting its late completion',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      await tester.tap(find.byIcon(Icons.volume_up));
      await harness.flush();
      expect(harness.tts.replays, 1);
      expect(harness.tts.utterances, hasLength(2));

      harness.tts.utterances.first.complete(true);
      await harness.flush();
      await harness.frame(_result(guidance: false));
      await harness.frame(_result());
      expect(harness.motor.running, isTrue);
      expect(harness.tts.instructionUtterances, isEmpty);

      harness.tts.utterances.last.complete(true);
      await harness.flush();
      expect(harness.motor.running, isFalse);
      await tester.pump(const Duration(seconds: 5));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.cleanup();
    },
  );

  testWidgets(
    'replay uses the spoken route and preserves a newer detected route in the queue',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      await harness.frame(_result(route: '44'));
      expect(find.text('رقم وجهة الباص: 44'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.volume_up));
      await harness.flush();
      expect(harness.tts.events, ['start', 'route 42', 'replay 42']);

      harness.tts.utterances.last.complete(true);
      await harness.flush();
      expect(harness.tts.routes, ['42', '44']);
      harness.tts.utterances.first.complete(true);
      await harness.flush();
      expect(harness.tts.instructionUtterances, isEmpty);
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 5));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.cleanup();
    },
  );

  testWidgets(
    'a previously announced route is queued when it reappears during a different route',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      harness.tts.utterances.single.complete(true);
      await harness.flush();
      await harness.frame(_result(route: '43'));
      await harness.frame(_result(route: '42'));
      expect(harness.tts.routes, ['42', '43']);

      harness.tts.utterances.last.complete(true);
      await harness.flush();
      expect(harness.tts.routes, ['42', '43', '42']);
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 5));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.cleanup();
    },
  );

  testWidgets('the newest recognized route is announced after current speech', (
    tester,
  ) async {
    final harness = _Harness(tester);
    await harness.open();
    await harness.frame(_result(route: '42'));
    await harness.frame(_result(route: '43'));
    await harness.frame(_result(guidance: false, route: '44'));
    expect(harness.tts.routes, ['42']);
    expect(harness.motor.running, isFalse);
    expect(find.text('رقم وجهة الباص: 44'), findsOneWidget);

    harness.tts.utterances.first.complete(true);
    await harness.flush();
    expect(harness.tts.routes, ['42', '44']);
    expect(harness.tts.instructionUtterances, isEmpty);
    harness.tts.utterances.last.complete(true);
    await harness.flush();
    await tester.pump(const Duration(seconds: 5));
    await harness.flush();
    expect(harness.tts.instructionUtterances, hasLength(1));

    await harness.cleanup();
  });

  testWidgets(
    'a newly recognized route supersedes instructions and ignores late instruction completion',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      harness.tts.utterances.single.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 5));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.frame(_result(route: '43'));
      expect(harness.tts.routes, ['42', '43']);
      harness.tts.instructionUtterances.single.complete(true);
      await harness.flush();
      await harness.frame(_result(route: '44'));
      expect(harness.tts.routes, ['42', '43']);
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      expect(harness.tts.routes, ['42', '43', '44']);
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 6));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.cleanup();
    },
  );

  testWidgets(
    'interrupted instructions do not replay on resume or disturb later route speech',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      harness.tts.utterances.single.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 5));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await harness.flush();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await harness.flush();
      await harness.frame(_result(route: '43'));
      harness.tts.instructionUtterances.single.complete(true);
      await harness.flush();
      await harness.frame(_result(route: '44'));
      expect(harness.tts.routes, ['42', '43']);
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      expect(harness.tts.routes, ['42', '43', '44']);
      harness.tts.utterances.last.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 6));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));
      expect(harness.tts.starts, 1);

      await harness.cleanup();
    },
  );

  testWidgets(
    'background pauses pending instructions and resumes the remaining delay',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      harness.tts.utterances.single.complete(true);
      await harness.flush();
      await tester.pump(const Duration(seconds: 2));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await harness.flush();
      await tester.pump(const Duration(seconds: 10));
      await harness.flush();
      expect(harness.tts.instructionUtterances, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await harness.flush();
      expect(harness.tts.starts, 1);
      await tester.pump(const Duration(milliseconds: 2999));
      expect(harness.tts.instructionUtterances, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await harness.flush();
      expect(harness.tts.instructionUtterances, hasLength(1));

      await harness.cleanup();
    },
  );

  testWidgets(
    'late background route completion cannot latch guidance or schedule instructions',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      await harness.frame(_result(route: '42'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await harness.flush();
      harness.tts.utterances.single.complete(true);
      await harness.flush();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await harness.flush();
      await harness.frame(_result());
      expect(harness.motor.running, isTrue);
      await tester.pump(const Duration(seconds: 6));
      await harness.flush();
      expect(harness.tts.instructionUtterances, isEmpty);

      await harness.frame(_result(route: '42'));
      expect(harness.tts.routes, ['42', '42']);
      await harness.cleanup();
    },
  );

  testWidgets('exit cancels pending instructions permanently', (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    await harness.frame(_result(route: '42'));
    harness.tts.utterances.single.complete(true);
    await harness.flush();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byIcon(Icons.stop));
    await harness.flush();
    await tester.pump(const Duration(seconds: 6));
    await harness.flush();
    expect(harness.tts.instructionUtterances, isEmpty);
    expect(find.text('home'), findsOneWidget);

    await harness.cleanup();
  });

  testWidgets('late startup completion after exit cannot start route speech', (
    tester,
  ) async {
    final harness = _Harness(tester);
    harness.tts.startGate = Completer<bool>();
    await harness.open();
    await harness.frame(_result(route: '42'));
    await tester.tap(find.byIcon(Icons.stop));
    await harness.flush();
    harness.tts.startGate!.complete(true);
    await tester.pump(const Duration(seconds: 6));
    await harness.flush();
    expect(harness.tts.routes, isEmpty);
    expect(harness.tts.instructionUtterances, isEmpty);
    expect(harness.motor.running, isFalse);

    await harness.cleanup();
  });

  testWidgets(
    'frames keep guidance current during speech and latch on completion',
    (tester) async {
      final harness = _Harness(tester);
      await harness.open();

      await harness.frame(_result(route: '42'));
      expect(harness.tts.routes, ['42']);
      expect(harness.motor.running, isTrue);
      expect(find.text('رقم وجهة الباص: 42'), findsOneWidget);

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
        await tester.pump(const Duration(seconds: 6));
        await harness.flush();
        expect(harness.motor.starts, starts);
        expect(harness.tts.routes, ['42']);
        expect(harness.tts.instructionUtterances, isEmpty);
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
