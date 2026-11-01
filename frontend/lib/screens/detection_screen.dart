import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/detection_api_service.dart';
import '../services/frame_encoder.dart';
import '../services/haptic_guidance_service.dart';
import '../services/tts_service.dart';

class DetectionScreen extends StatefulWidget {
  const DetectionScreen({
    super.key,
    this.apiService,
    this.ttsService,
    this.hapticGuidanceService,
    this.now,
  });

  final DetectionApiService? apiService;
  final TtsService? ttsService;
  final HapticGuidanceService? hapticGuidanceService;
  final DateTime Function()? now;

  @override
  State<DetectionScreen> createState() => _DetectionScreenState();
}

class _DetectionScreenState extends State<DetectionScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  late final DetectionApiService _apiService;
  late final TtsService _ttsService;
  late final HapticGuidanceService _haptics;
  late final Future<void> _ttsReady;
  late final int _sessionId;
  late final DateTime Function() _now;
  final FrameEncoder _frameEncoder = FrameEncoder();

  Future<void> _cameraWork = Future<void>.value();
  int _streamGeneration = 0;
  int? _busyGeneration;
  int _speechGeneration = 0;
  bool _foreground = true;
  bool _stopped = false;
  bool _isAnnouncing = false;
  bool _startupStarted = false;
  bool _startupFinished = false;
  bool _instructionsSpoken = false;
  Timer? _instructionsTimer;
  DateTime? _instructionsDeadline;
  Duration? _pausedInstructionDelay;
  String? _pendingRoute;
  DateTime? _pendingRouteCapturedAt;
  String? _activeRoute;
  String? _lastSpokenRoute;
  String? _lastAnnouncedRoute;
  DateTime? _lastFrameTime;
  String lastDetectedRoute = '';

  String busMessage = 'بانتظار قراءة رقم الباص...';

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? DetectionApiService();
    _ttsService = widget.ttsService ?? TtsService();
    _haptics = widget.hapticGuidanceService ?? HapticGuidanceService();
    _now = widget.now ?? DateTime.now;
    _sessionId = _haptics.startSession();
    _ttsReady = _initializeTts();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(_speakStartMessage());
      final generation = _streamGeneration;
      _queueCamera(() => _initializeCamera(generation));
    } else {
      _haptics.suspend();
    }
  }

  Future<void> _initializeTts() async {
    try {
      await _ttsService.initialize();
    } catch (e) {
      debugPrint('TTS initialization error: $e');
    }
  }

  Future<void> _speakStartMessage() async {
    if (_startupStarted) return;
    final generation = _streamGeneration;
    try {
      await _ttsReady;
      if (!_isCurrent(generation)) return;
      _startupStarted = true;
      await _ttsService.speakStartMessage();
    } catch (e) {
      debugPrint('TTS start message error: $e');
    } finally {
      if (_isCurrent(generation)) {
        _startupFinished = true;
        _drainPendingRoute();
      }
    }
  }

  void _cancelInstructions() {
    _instructionsTimer?.cancel();
    _instructionsTimer = null;
    _instructionsDeadline = null;
    _pausedInstructionDelay = null;
  }

  void _pauseInstructions() {
    final deadline = _instructionsDeadline;
    if (deadline != null) {
      final remaining = deadline.difference(_now());
      _pausedInstructionDelay = remaining > Duration.zero
          ? remaining
          : Duration.zero;
    }
    _instructionsTimer?.cancel();
    _instructionsTimer = null;
    _instructionsDeadline = null;
  }

  void _scheduleInstructions() {
    if (_stopped || _instructionsSpoken) return;
    _cancelInstructions();
    _pausedInstructionDelay = const Duration(seconds: 5);
    _resumeInstructions();
  }

  void _resumeInstructions() {
    final delay = _pausedInstructionDelay;
    if (delay == null ||
        _stopped ||
        !_foreground ||
        _instructionsSpoken ||
        _isAnnouncing) {
      return;
    }
    _pausedInstructionDelay = null;
    _instructionsDeadline = _now().add(delay);
    final generation = _streamGeneration;
    _instructionsTimer = Timer(delay, () {
      _instructionsTimer = null;
      _instructionsDeadline = null;
      if (!_isCurrent(generation) || _instructionsSpoken) return;
      // Match shahad's once-per-screen behavior: the prompt is consumed when
      // it starts. A route or replay may interrupt it without repeating it.
      _instructionsSpoken = true;
      unawaited(_speakInstructions());
    });
  }

  Future<void> _speakInstructions() async {
    final generation = ++_speechGeneration;
    try {
      await _ttsReady;
      if (_stopped || !_foreground || generation != _speechGeneration) return;
      await _ttsService.speakInstruction();
    } catch (e) {
      debugPrint('TTS instruction error: $e');
    }
  }

  void _drainPendingRoute() {
    if (_stopped || !_foreground || !_startupFinished || _isAnnouncing) return;
    final route = _pendingRoute;
    final capturedAt = _pendingRouteCapturedAt;
    _pendingRoute = null;
    _pendingRouteCapturedAt = null;
    if (route == null ||
        route == _lastAnnouncedRoute ||
        capturedAt == null ||
        _now().difference(capturedAt) >= _haptics.staleAfter) {
      return;
    }
    unawaited(_announceRoute(route));
  }

  bool _isCurrent(int generation) =>
      mounted && !_stopped && _foreground && generation == _streamGeneration;

  void _queueCamera(Future<void> Function() operation) {
    // Serialize camera initialization/release across rapid lifecycle changes.
    _cameraWork = _cameraWork.then((_) => operation()).catchError((Object e) {
      debugPrint('Camera error: $e');
      _haptics.invalidateGuidance(sessionId: _sessionId, capturedAt: _now());
    });
  }

  Future<void> _initializeCamera(int generation) async {
    if (!_isCurrent(generation)) return;
    final cameras = await availableCameras();
    if (!_isCurrent(generation) || cameras.isEmpty) return;
    final camera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      if (!_isCurrent(generation)) {
        await controller.dispose();
        return;
      }
      _cameraController = controller;
      controller.addListener(_onCameraChanged);
      setState(() {});
      await controller.startImageStream((frame) {
        unawaited(_processFrame(frame, generation));
      });
    } catch (e) {
      if (identical(_cameraController, controller)) {
        _cameraController = null;
        controller.removeListener(_onCameraChanged);
        if (mounted) setState(() {});
      }
      await controller.dispose();
      rethrow;
    }
  }

  void _onCameraChanged() {
    if (_cameraController?.value.hasError ?? false) {
      _haptics.invalidateGuidance(sessionId: _sessionId, capturedAt: _now());
    }
  }

  Future<void> _processFrame(CameraImage frame, int generation) async {
    final capturedAt = _now();
    if (!_isCurrent(generation) ||
        _busyGeneration == generation ||
        (_lastFrameTime != null &&
            capturedAt.difference(_lastFrameTime!) <
                const Duration(milliseconds: 300))) {
      return;
    }
    _busyGeneration = generation;
    _lastFrameTime = capturedAt;
    try {
      final frameBytes = await _frameEncoder.encodeToJpeg(frame);
      if (!_isCurrent(generation)) return;
      final result = await _apiService.processFrameBytes(frameBytes);
      if (!_isCurrent(generation)) return;
      if (result == null) {
        _haptics.invalidateGuidance(
          sessionId: _sessionId,
          capturedAt: capturedAt,
        );
        return;
      }
      // The watchdog uses capture time: a slow response is not a fresh frame.
      if (!_haptics.updateGuidance(
        sessionId: _sessionId,
        busInGuidanceZone: result.busInGuidanceZone,
        capturedAt: capturedAt,
      )) {
        return;
      }

      if (result.detected && result.routeNumber.isNotEmpty) {
        final route = result.routeNumber;
        if (route != lastDetectedRoute) {
          setState(() {
            lastDetectedRoute = route;
            busMessage = 'رقم وجهة الباص: $route';
          });
        }
        // Remember the latest route independently from the display. Frames
        // remain responsive and a route seen during speech is not lost.
        _pendingRoute =
            route != _activeRoute &&
                (_isAnnouncing || route != _lastAnnouncedRoute)
            ? route
            : null;
        _pendingRouteCapturedAt = _pendingRoute == null ? null : capturedAt;
        _drainPendingRoute();
      }
    } catch (e) {
      if (_isCurrent(generation)) {
        _haptics.invalidateGuidance(
          sessionId: _sessionId,
          capturedAt: capturedAt,
        );
      }
      debugPrint('Stream frame error: $e');
    } finally {
      if (_busyGeneration == generation) _busyGeneration = null;
    }
  }

  Future<void> _announceRoute(String route, {bool replay = false}) async {
    if (_stopped || !_foreground) return;
    final generation = ++_speechGeneration;
    _isAnnouncing = true;
    _activeRoute = route;
    _pauseInstructions();
    try {
      await _ttsReady;
      if (_stopped || !_foreground || generation != _speechGeneration) return;
      _lastSpokenRoute = route;
      final completed = replay
          ? await _ttsService.replayLastRoute()
          : await _ttsService.speakRouteNumber(route);
      if (completed && !_stopped && generation == _speechGeneration) {
        _lastAnnouncedRoute = route;
        _haptics.completeRouteAnnouncement(_sessionId);
        // Only route/replay completion starts shahad's five-second delay.
        // Startup and instruction speech never complete vibration guidance.
        _scheduleInstructions();
      }
    } catch (e) {
      debugPrint('TTS error: $e');
    } finally {
      if (generation == _speechGeneration) {
        _isAnnouncing = false;
        _activeRoute = null;
        _drainPendingRoute();
        _resumeInstructions();
      }
    }
  }

  Future<void> _releaseCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    if (controller == null) return;
    // Remove the preview before notifying/disposal can schedule its rebuild.
    if (mounted) setState(() {});
    controller.removeListener(_onCameraChanged);
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } finally {
      await controller.dispose();
    }
  }

  Future<void> _stopSpeech({bool permanently = false}) async {
    try {
      if (permanently) {
        await _ttsService.dispose();
      } else {
        await _ttsService.stop();
      }
    } catch (e) {
      debugPrint('TTS stop error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_stopped) return;
    if (state != AppLifecycleState.resumed) {
      if (!_foreground) return;
      _foreground = false;
      _streamGeneration++;
      _speechGeneration++;
      _isAnnouncing = false;
      _activeRoute = null;
      _pendingRoute = null;
      _pendingRouteCapturedAt = null;
      if (_startupStarted) _startupFinished = true;
      _pauseInstructions();
      _haptics.suspend();
      _apiService.cancelPending();
      unawaited(_stopSpeech());
      _queueCamera(_releaseCamera);
    } else if (!_foreground) {
      _foreground = true;
      _streamGeneration++;
      _lastFrameTime = null;
      _haptics.resume();
      if (!_startupStarted) unawaited(_speakStartMessage());
      _resumeInstructions();
      final generation = _streamGeneration;
      _queueCamera(() => _initializeCamera(generation));
    }
  }

  void _stopDetection() {
    if (_stopped) return;
    _stopped = true;
    _streamGeneration++;
    _speechGeneration++;
    _pendingRoute = null;
    _pendingRouteCapturedAt = null;
    _cancelInstructions();
    _haptics.stopSession();
    _apiService.dispose();
    unawaited(_stopSpeech(permanently: true));
    _queueCamera(_releaseCamera);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopDetection();
    unawaited(_haptics.dispose());
    super.dispose();
  }

  // -----------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: PopScope(
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) _stopDetection();
        },
        child: Center(
          child: Container(
            width: 320,
            height: MediaQuery.of(context).size.height * 0.88,
            constraints: const BoxConstraints(maxWidth: 380),
            decoration: BoxDecoration(
              color: const Color(0xFF303030),
              borderRadius: BorderRadius.circular(25),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 15,
                  spreadRadius: 2,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                // Bus route message

                Container(
                  height: 90,
                  width: double.infinity,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  color: const Color(0xFF303030),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF252525),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      busMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

                // Live phone camera feed
                Expanded(
                  child: Container(
                    width: double.infinity,
                    color: Colors.black,

                    child:
                        _cameraController != null &&
                            _cameraController!.value.isInitialized
                        ? ClipRect(
                            child: SizedBox.expand(
                              child: FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: _cameraController!
                                      .value
                                      .previewSize!
                                      .height,

                                  height: _cameraController!
                                      .value
                                      .previewSize!
                                      .width,

                                  child: CameraPreview(_cameraController!),
                                ),
                              ),
                            ),
                          )
                        : const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),

                // Bottom buttons area
                Container(
                  height: 90,
                  width: double.infinity,
                  color: const Color(0xFF303030),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Replay audio button - LEFT
                      SizedBox(
                        width: 55,
                        height: 55,
                        child: ElevatedButton(
                          onPressed: () {
                            final route = _lastSpokenRoute;
                            if (_startupFinished && route != null) {
                              unawaited(_announceRoute(route, replay: true));
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFF252525),
                            foregroundColor: Colors.white,
                          ),

                          child: const Icon(Icons.volume_up, size: 26),
                        ),
                      ),

                      // Stop detection button - RIGHT
                      SizedBox(
                        width: 55,
                        height: 55,
                        child: ElevatedButton(
                          onPressed: () {
                            _stopDetection();
                            Navigator.pop(context);
                          },
                          style: ElevatedButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: EdgeInsets.zero,
                            backgroundColor: const Color(0xFF252525),
                            foregroundColor: Colors.white,
                          ),

                          child: const Icon(Icons.stop, size: 28),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
