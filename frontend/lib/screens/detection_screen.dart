import 'package:flutter/material.dart';
import 'dart:typed_data';
import '../services/detection_api_service.dart';
import 'package:camera/camera.dart';

class DetectionScreen extends StatefulWidget {

  const DetectionScreen({super.key});

  @override

  State<DetectionScreen> createState() => _DetectionScreenState();

}

class _DetectionScreenState extends State<DetectionScreen> {

  CameraController? _cameraController;
  final DetectionApiService _apiService = DetectionApiService();
  bool _isServerBusy = false;
  DateTime _lastFrameTime = DateTime.now();
  String lastDetectedRoute = '';

  String busMessage = 'بانتظار قراءة رقم الباص...';

  @override

  void initState() {

    super.initState();

    _initializeCamera();

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

        ResolutionPreset.medium,

        enableAudio: false,

      );

      _cameraController = controller;

      await controller.initialize();
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
        ResolutionPreset.medium, // Medium resolution keeps payloads lightweight and fast
        enableAudio: false,
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

  void _startLiveStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    _cameraController!.startImageStream((CameraImage frame) async {
      final now = DateTime.now();

      // 300ms Throttle: Avoids overwhelming network/backend while keeping up with moving buses
      if (_isServerBusy || now.difference(_lastFrameTime).inMilliseconds < 300) {
        return;
      }

      _isServerBusy = true;
      _lastFrameTime = now;

      try {
        final Uint8List frameBytes = frame.planes[0].bytes;
        final result = await _apiService.processFrameBytes(frameBytes);

        if (result != null && result.detected && mounted) {
          setState(() {
            lastDetectedRoute = result.routeNumber;
            busMessage = 'حافلة رقم: ${result.routeNumber}';
          });
        }
      } catch (e) {
        debugPrint('Stream frame error: $e');
      } finally {
        _isServerBusy = false;
      }
    });
  }

      if (mounted) {

        setState(() {});

      }

    } catch (e) {

      debugPrint('Camera error: $e');

    }

  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    super.dispose();
  }

  }

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
              // live phone camera
              Expanded(

                child: Container(

                  width: double.infinity,

                  color: Colors.black,

                  child: _cameraController != null &&

                          _cameraController!.value.isInitialized

                      ? ClipRect(

                          child: SizedBox.expand(

                            child: FittedBox(

                              fit: BoxFit.cover,

                              child: SizedBox(

                                width: _cameraController!

                                    .value.previewSize!.height,

                                height: _cameraController!

                                    .value.previewSize!.width,

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
              // Bottom buttons

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

                          // TODO: Replay the last bus route audio

                        },

                        style: ElevatedButton.styleFrom(

                          shape: const CircleBorder(),

                          padding: EdgeInsets.zero,

                          backgroundColor: const Color(0xFF252525),

                          foregroundColor: Colors.white,

                        ),

                        child: const Icon(

                          Icons.volume_up,

                          size: 26,

                        ),

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

                        child: const Icon(

                          Icons.stop,

                          size: 28,

                        ),

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