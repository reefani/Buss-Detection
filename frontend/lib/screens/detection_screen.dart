import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/detection_api_service.dart';
import '../services/frame_encoder.dart';
import '../services/tts_service.dart';
import 'dart:async';

class DetectionScreen extends StatefulWidget {
  const DetectionScreen({super.key});

  @override
  State<DetectionScreen> createState() => _DetectionScreenState();
}

class _DetectionScreenState extends State<DetectionScreen> {
  CameraController? _cameraController;
  final DetectionApiService _apiService = DetectionApiService();
  final TtsService _ttsService = TtsService();
  final FrameEncoder _frameEncoder = FrameEncoder();

  bool _isServerBusy = false;
  Timer? _instructionsTimer;
  bool _instructionsSpoken = false;
  DateTime _lastFrameTime = DateTime.now();
  String lastDetectedRoute = '';

  String busMessage = 'بانتظار قراءة رقم الباص...';

  @override
  void initState() {
    super.initState();
    _initializeServices();
    _initializeCamera();
  }

  Future<void> _initializeServices() async {
   await _ttsService.initialize();
   if(!mounted) return;
   await _ttsService.speakStartMessage();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final camera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset
            .medium, // Medium resolution keeps payloads lightweight and fast
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      _cameraController = controller;
      await controller.initialize();

      if (mounted) {
        setState(() {});
        _startLiveStream(); // <--- START STREAMING HERE
      }
    } catch (e) {
      debugPrint('Camera error: $e');
    }
  }

  void _scheduleInstructions() {
    if (_instructionsSpoken) return;
    _instructionsTimer?.cancel(); // Cancel any existing timer
    _instructionsTimer = Timer(const Duration(seconds: 5), () async {

      if (!mounted || _instructionsSpoken) return;{
        _instructionsSpoken = true;
        await _ttsService.speakInstruction();
      }
    }
    );
  }

  void _startLiveStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized)
      return;

    _cameraController!.startImageStream((CameraImage frame) async {
      debugPrint('Camera frame format: ${frame.format.group}');
      debugPrint('Number of planes: ${frame.planes.length}');

      final now = DateTime.now();

      // 300ms Throttle: Avoids overwhelming network/backend while keeping up with moving buses
      if (_isServerBusy ||
          now.difference(_lastFrameTime).inMilliseconds < 300) {
        return;
      }

      _isServerBusy = true;
      _lastFrameTime = now;

      try {
        final Uint8List frameBytes = await _frameEncoder.encodeToJpeg(frame);
        final result = await _apiService.processFrameBytes(frameBytes);

       if (result != null && result.detected && mounted) {
          final routeNumber = result.routeNumber;

          if (routeNumber.isNotEmpty && routeNumber != lastDetectedRoute) {
            setState(() {
              lastDetectedRoute = routeNumber;
              busMessage = 'رقم وجهة الباص: $routeNumber';
            });
            await _ttsService.speakRouteNumber(routeNumber);
            if (!mounted) return;
            _scheduleInstructions();
           }
        } // Schedule instructions after first successful detection

      } catch (e) {
        debugPrint('Stream frame error: $e');
      } finally {
        _isServerBusy = false;
      }
    });
  }

  @override
  void dispose() {
    _instructionsTimer?.cancel();
    _ttsService.stop();

    final controller = _cameraController;

    if (controller != null && controller.value.isStreamingImages) {
      controller.stopImageStream();
    }

    controller?.dispose();
    super.dispose();
  }

  // -----------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: Center(
        child: Container(
          width: 320,
          height: MediaQuery.of(context).size.height * 0.88,
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: const Color(0xFF303030),
            borderRadius: BorderRadius.circular(25),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
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

                                height:
                                    _cameraController!.value.previewSize!.width,

                                child: CameraPreview(_cameraController!),
                              ),
                            ),
                          ),
                        )
                      : const Center(
                          child: CircularProgressIndicator(color: Colors.white),
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
                          _ttsService.replayLastRoute();
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
    );
  }
}
