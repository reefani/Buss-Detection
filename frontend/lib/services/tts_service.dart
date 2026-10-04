import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  String? _lastRouteNumber;

  Future<void> initialize() async {
    await _flutterTts.setLanguage('ar');
    await _flutterTts.setSpeechRate(0.5);
  }

  Future<void> speakRouteNumber(String routeNumber) async {
    _lastRouteNumber = routeNumber;
    await _flutterTts.stop();
    await _flutterTts.speak('الباص رقم $routeNumber');
  }

  Future<void> replayLastRoute() async {
    final routeNumber = _lastRouteNumber;
    if (routeNumber != null) {
      await speakRouteNumber(routeNumber);
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }
}
