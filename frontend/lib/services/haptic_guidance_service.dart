import 'dart:async';

import 'package:vibration/vibration.dart';

/// The small native boundary is injectable so lifecycle and command races can
/// be tested without a device's vibration motor.
abstract interface class GuidanceVibrationBackend {
  Future<bool> hasVibrator();

  Future<void> vibrate({required List<int> pattern, required int repeat});

  Future<void> cancel();
}

class _PluginVibrationBackend implements GuidanceVibrationBackend {
  @override
  Future<bool> hasVibrator() => Vibration.hasVibrator();

  @override
  Future<void> vibrate({required List<int> pattern, required int repeat}) =>
      Vibration.vibrate(pattern: pattern, repeat: repeat);

  @override
  Future<void> cancel() => Vibration.cancel();
}

/// Repeats guidance only while a fresh frame places a bus in the central zone.
///
/// Session tokens also guard delayed network and speech completions. Native
/// start/cancel commands are serialized: a late start is always followed by a
/// cancel before another start can be issued.
class HapticGuidanceService {
  HapticGuidanceService({
    GuidanceVibrationBackend? backend,
    this.vibrationDuration = const Duration(milliseconds: 220),
    this.pauseDuration = const Duration(milliseconds: 280),
    this.staleAfter = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : assert(vibrationDuration.inMilliseconds > 0),
       assert(pauseDuration.inMilliseconds > 0),
       assert(staleAfter > Duration.zero),
       _backend = backend ?? _PluginVibrationBackend(),
       _now = now ?? DateTime.now;

  final Duration vibrationDuration;
  final Duration pauseDuration;
  final Duration staleAfter;
  final GuidanceVibrationBackend _backend;
  final DateTime Function() _now;

  int _sessionId = 0;
  bool _active = false;
  bool _suspended = false;
  bool _announcementCompleted = false;
  bool _disposed = false;
  bool _inGuidanceZone = false;
  bool _nativeRunning = false;
  bool _cancelRequired = false;
  bool? _supported;
  DateTime? _resultsNotBefore;
  DateTime? _latestCapturedAt;
  Timer? _expiryTimer;
  Future<void>? _reconcileFuture;

  /// Starts a fresh detection session, resetting its speech-completion latch.
  int startSession() {
    if (_disposed) {
      throw StateError('Cannot start a disposed guidance service.');
    }
    _clearGuidance();
    _sessionId += 1;
    _active = true;
    _announcementCompleted = false;
    _latestCapturedAt = null;
    _resultsNotBefore = _now();
    return _sessionId;
  }

  /// [capturedAt] must be recorded when the frame/request starts, not when its
  /// response arrives. Returns false for obsolete or already-expired results.
  bool updateGuidance({
    required int sessionId,
    required bool busInGuidanceZone,
    required DateTime capturedAt,
  }) {
    if (!_acceptsResult(sessionId, capturedAt)) return false;
    _latestCapturedAt = capturedAt;
    final remaining = staleAfter - _now().difference(capturedAt);
    if (remaining <= Duration.zero) {
      _clearGuidance();
      return false;
    }
    // Keep accepting detection data for the screen after speech completes;
    // only the vibration permission is latched off for the current session.
    if (_announcementCompleted) return true;
    if (!busInGuidanceZone) {
      _clearGuidance();
      return true;
    }

    _inGuidanceZone = true;
    _expiryTimer?.cancel();
    _expiryTimer = Timer(remaining, () {
      if (sessionId == _sessionId && capturedAt == _latestCapturedAt) {
        _clearGuidance();
      }
    });
    _scheduleReconcile();
    return true;
  }

  /// A failed request immediately removes guidance, without allowing an older
  /// failed request to cancel a newer successful result.
  bool invalidateGuidance({
    required int sessionId,
    required DateTime capturedAt,
  }) {
    if (!_acceptsResult(sessionId, capturedAt)) return false;
    _latestCapturedAt = capturedAt;
    _clearGuidance();
    return true;
  }

  /// Call only after the route-number utterance actually finishes speaking.
  void completeRouteAnnouncement(int sessionId) {
    if (_disposed || !_active || sessionId != _sessionId) return;
    _announcementCompleted = true;
    _clearGuidance();
  }

  void stopSession() {
    _active = false;
    _clearGuidance();
  }

  /// Foregrounding keeps the same session and speech latch, but needs a newly
  /// captured frame. In-flight frames from before suspension cannot restart it.
  void suspend() {
    _suspended = true;
    _resultsNotBefore = _now();
    _clearGuidance();
  }

  void resume() {
    if (_disposed) return;
    _suspended = false;
    _resultsNotBefore = _now();
    _clearGuidance();
  }

  Future<void> dispose() {
    _disposed = true;
    _active = false;
    _clearGuidance();
    return _reconcileFuture ?? Future<void>.value();
  }

  bool _acceptsResult(int sessionId, DateTime capturedAt) {
    if (_disposed ||
        !_active ||
        _suspended ||
        sessionId != _sessionId ||
        capturedAt.isAfter(_now())) {
      return false;
    }
    final notBefore = _resultsNotBefore;
    if (notBefore != null && capturedAt.isBefore(notBefore)) return false;
    final latest = _latestCapturedAt;
    return latest == null || capturedAt.isAfter(latest);
  }

  bool get _shouldVibrate {
    final capturedAt = _latestCapturedAt;
    return !_disposed &&
        _active &&
        !_suspended &&
        !_announcementCompleted &&
        _inGuidanceZone &&
        _supported != false &&
        capturedAt != null &&
        _now().difference(capturedAt) < staleAfter;
  }

  void _clearGuidance() {
    _inGuidanceZone = false;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    // Preserve a stop even if another result/session arrives before the native
    // command in flight finishes. It must cancel before a replacement starts.
    _cancelRequired = _cancelRequired || _nativeRunning;
    _scheduleReconcile();
  }

  void _scheduleReconcile() {
    if (_reconcileFuture != null) return;
    final completion = Completer<void>();
    _reconcileFuture = completion.future;
    unawaited(_reconcile(completion));
  }

  Future<void> _reconcile(Completer<void> completion) async {
    try {
      while (true) {
        if (_cancelRequired || (!_shouldVibrate && _nativeRunning)) {
          _cancelRequired = false;
          if (_nativeRunning) {
            try {
              await _backend.cancel();
            } catch (_) {
              // Unsupported/failing native APIs must not break frame handling.
              _supported = false;
            }
            _nativeRunning = false;
          }
          continue;
        }
        if (!_shouldVibrate || _nativeRunning) break;

        if (_supported == null) {
          try {
            _supported = await _backend.hasVibrator();
          } catch (_) {
            _supported = false;
          }
          // State may have changed while checking the device's capabilities.
          continue;
        }

        _nativeRunning = true;
        try {
          // Keep an even number of alternating wait/vibrate segments so every
          // repetition starts with the same 220 ms pulse and 280 ms pause.
          await _backend.vibrate(
            pattern: [
              0,
              vibrationDuration.inMilliseconds,
              pauseDuration.inMilliseconds,
              0,
            ],
            repeat: 0,
          );
        } catch (_) {
          _supported = false;
          // A failed start may still have reached the motor. Cancel it below.
          _cancelRequired = true;
        }
      }
    } finally {
      _reconcileFuture = null;
      completion.complete();
    }
  }
}
