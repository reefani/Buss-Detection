import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  String? _lastRouteNumber;

  Future<void> initialize() async {
    await _flutterTts.setLanguage('ar');
    await _flutterTts.setSpeechRate(0.5);
  }

  Future<void> speakRouteNumber(String routeNumber) async {
    if (routeNumber.isEmpty || routeNumber == _lastRouteNumber) {
      return;
    }

    _lastRouteNumber = routeNumber;

    // Share the announcement guard; unavailable haptics must not interrupt TTS.
    try {
      await HapticFeedback.vibrate();
    } catch (_) {
      // Continue with speech when vibration is unavailable.
    }

    await _flutterTts.stop();
    await _flutterTts.speak('الباص رقم $routeNumber');
  }

  Future<void> replayLastRoute() async {
    final routeNumber = _lastRouteNumber;

    if (routeNumber != null) {
      await _flutterTts.stop();
      await _flutterTts.speak('الباص رقم $routeNumber');
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }
}
