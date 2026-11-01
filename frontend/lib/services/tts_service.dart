import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  String? _lastRouteNumber;
  String? _activeRouteNumber;
  String? _completedRouteNumber;
  Future<void>? _initialization;
  Completer<bool>? _speechCompletion;
  int _speechGeneration = 0;
  bool _disposed = false;

  TtsService() {
    // The plugin's cancel event has no utterance ID and can arrive after replay
    // starts. Use stop/generation and the awaited speak result for cancellation.
    _flutterTts.setErrorHandler((_) => _finishSpeech(false));
  }

  Future<void> initialize() => _initialization ??= _configure();

  Future<void> _configure() async {
    await _flutterTts.setLanguage('ar');
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.awaitSpeakCompletion(true);
  }

  Future<bool> speakStartMessage() => _speak('بدا التحقق');

  /// Returns true only when this route utterance finishes naturally.
  Future<bool> speakRouteNumber(String routeNumber) async {
    if (_disposed ||
        routeNumber.isEmpty ||
        (routeNumber == _lastRouteNumber &&
            (routeNumber == _activeRouteNumber ||
                routeNumber == _completedRouteNumber))) {
      return false;
    }

    _lastRouteNumber = routeNumber;
    return _speak('الباص رقم $routeNumber', routeNumber: routeNumber);
  }

  Future<bool> speakInstruction() =>
      _speak('لإعادة رقم الوجهة اضغط زر إعادة, و لإنهاء التحقق اضغط زر إنهاء');

  Future<bool> replayLastRoute() async {
    final routeNumber = _lastRouteNumber;
    if (_disposed || routeNumber == null) {
      return false;
    }
    return _speak('الباص رقم $routeNumber', routeNumber: routeNumber);
  }

  Future<bool> _speak(String text, {String? routeNumber}) async {
    if (_disposed) return false;
    final generation = ++_speechGeneration;
    _finishSpeech(false);
    _activeRouteNumber = routeNumber;

    try {
      await initialize();
      if (_disposed || generation != _speechGeneration) return false;

      await _flutterTts.stop();
      if (_disposed || generation != _speechGeneration) return false;

      final completion = Completer<bool>();
      _speechCompletion = completion;
      // With awaitSpeakCompletion enabled, 1 means the utterance finished.
      // Keep this tied to its request: a stopped/replayed utterance may reply late.
      unawaited(
        _flutterTts
            .speak(text)
            .then(
              (result) {
                if (generation == _speechGeneration &&
                    identical(_speechCompletion, completion)) {
                  _finishSpeech(!_disposed && result == 1);
                }
              },
              onError: (Object _, StackTrace _) {
                if (generation == _speechGeneration &&
                    identical(_speechCompletion, completion)) {
                  _finishSpeech(false);
                }
              },
            ),
      );
      return await completion.future;
    } catch (_) {
      if (generation == _speechGeneration) {
        _activeRouteNumber = null;
        _finishSpeech(false);
      }
      return false;
    }
  }

  void _finishSpeech(bool completed) {
    final completion = _speechCompletion;
    if (completion == null) return;
    if (completed && _activeRouteNumber != null) {
      _completedRouteNumber = _activeRouteNumber;
    }
    _activeRouteNumber = null;
    _speechCompletion = null;
    completion.complete(completed);
  }

  Future<void> stop() async {
    ++_speechGeneration;
    _finishSpeech(false);
    _activeRouteNumber = null;
    await _flutterTts.stop();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }
}
