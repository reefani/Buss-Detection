import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/haptic_guidance_service.dart';

class _FakeVibration implements GuidanceVibrationBackend {
  final List<String> commands = [];
  final List<List<int>> patterns = [];
  final List<int> repeats = [];
  Completer<bool>? capabilityGate;
  Completer<void>? nextStartGate;
  Completer<void>? nextCancelGate;
  bool supported = true;
  bool failStart = false;
  int capabilityChecks = 0;

  @override
  Future<bool> hasVibrator() async {
    capabilityChecks += 1;
    return capabilityGate?.future ?? supported;
  }

  @override
  Future<void> vibrate({
    required List<int> pattern,
    required int repeat,
  }) async {
    commands.add('start');
    patterns.add(List<int>.of(pattern));
    repeats.add(repeat);
    final gate = nextStartGate;
    nextStartGate = null;
    if (gate != null) await gate.future;
    if (failStart) throw StateError('Native start failed');
  }

  @override
  Future<void> cancel() async {
    commands.add('cancel');
    final gate = nextCancelGate;
    nextCancelGate = null;
    if (gate != null) await gate.future;
  }
}

class _Clock {
  DateTime now = DateTime.utc(2026, 11, 1);

  DateTime advance([Duration duration = const Duration(milliseconds: 1)]) {
    now = now.add(duration);
    return now;
  }
}

void main() {
  testWidgets(
    'zone updates repeat once, cancel on loss, and resume on return',
    (tester) async {
      final backend = _FakeVibration();
      final clock = _Clock();
      final service = HapticGuidanceService(
        backend: backend,
        now: () => clock.now,
        vibrationDuration: const Duration(milliseconds: 230),
        pauseDuration: const Duration(milliseconds: 290),
      );
      final session = service.startSession();

      expect(
        service.updateGuidance(
          sessionId: session,
          busInGuidanceZone: true,
          capturedAt: clock.now,
        ),
        isTrue,
      );
      await tester.pump();
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: true,
        capturedAt: clock.advance(),
      );
      await tester.pump();
      expect(backend.commands, ['start']);
      expect(backend.patterns, [
        <int>[0, 230, 290, 0],
      ]);
      expect(backend.repeats, [0]);

      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: false,
        capturedAt: clock.advance(),
      );
      await tester.pump();
      expect(backend.commands, ['start', 'cancel']);
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: true,
        capturedAt: clock.advance(),
      );
      await tester.pump();
      expect(backend.commands, ['start', 'cancel', 'start']);
      expect(backend.capabilityChecks, 1);
      await service.dispose();
    },
  );

  testWidgets('watchdog expires from frame capture, not response arrival', (
    tester,
  ) async {
    final backend = _FakeVibration();
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    final capturedAt = clock.now;
    clock.advance(const Duration(seconds: 2));
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: capturedAt,
    );
    await tester.pump();
    expect(backend.commands, ['start']);
    clock.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(backend.commands, ['start', 'cancel']);

    // A late response from an expired frame cannot buy another timeout window.
    final lateFrame = clock.now;
    clock.advance(const Duration(seconds: 3));
    expect(
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: true,
        capturedAt: lateFrame,
      ),
      isFalse,
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
    await service.dispose();
  });

  testWidgets('a delayed capability check cannot start expired guidance', (
    tester,
  ) async {
    final backend = _FakeVibration()..capabilityGate = Completer<bool>();
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    clock.advance(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    backend.capabilityGate!.complete(true);
    await tester.pump();
    expect(backend.commands, isEmpty);
    await service.dispose();
  });

  testWidgets('stop and disposal suppress delayed capability completions', (
    tester,
  ) async {
    final backend = _FakeVibration()..capabilityGate = Completer<bool>();
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    service.stopSession();
    final disposal = service.dispose();
    backend.capabilityGate!.complete(true);
    await tester.pump();
    await disposal;
    expect(backend.commands, isEmpty);
    expect(
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: true,
        capturedAt: clock.advance(),
      ),
      isFalse,
    );
    expect(service.startSession, throwsStateError);
  });

  testWidgets('late native start cancels before rapid zone return restarts', (
    tester,
  ) async {
    final startGate = Completer<void>();
    final cancelGate = Completer<void>();
    final backend = _FakeVibration()
      ..nextStartGate = startGate
      ..nextCancelGate = cancelGate;
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    await tester.pump();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: false,
      capturedAt: clock.advance(),
    );
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.advance(),
    );
    expect(backend.commands, ['start']);
    startGate.complete();
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
    cancelGate.complete();
    await tester.pump();
    expect(backend.commands, ['start', 'cancel', 'start']);
    await service.dispose();
  });

  testWidgets('disposal waits for a late start and cancels it', (tester) async {
    final startGate = Completer<void>();
    final backend = _FakeVibration()..nextStartGate = startGate;
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    await tester.pump();
    var disposed = false;
    final disposal = service.dispose().then((_) => disposed = true);
    await tester.pump();
    expect(disposed, isFalse);
    startGate.complete();
    await tester.pump();
    await disposal;
    expect(disposed, isTrue);
    expect(backend.commands, ['start', 'cancel']);
    service.completeRouteAnnouncement(session);
    service.resume();
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
  });

  testWidgets('speech completion latches only its own detection session', (
    tester,
  ) async {
    final backend = _FakeVibration();
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final firstSession = service.startSession();
    service.updateGuidance(
      sessionId: firstSession,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    await tester.pump();
    // Guidance continues throughout route speech until actual completion.
    clock.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(backend.commands, ['start']);
    service.completeRouteAnnouncement(firstSession);
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
    service.suspend();
    clock.advance();
    service.resume();
    expect(
      service.updateGuidance(
        sessionId: firstSession,
        busInGuidanceZone: true,
        capturedAt: clock.advance(),
      ),
      isTrue,
    );

    final secondSession = service.startSession();
    service.completeRouteAnnouncement(firstSession);
    service.updateGuidance(
      sessionId: secondSession,
      busInGuidanceZone: true,
      capturedAt: clock.advance(),
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel', 'start']);
    await service.dispose();
  });

  testWidgets('resume requires a frame captured after foregrounding', (
    tester,
  ) async {
    final backend = _FakeVibration();
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    await tester.pump();
    final inFlightCapture = clock.advance();
    service.suspend();
    await tester.pump();
    clock.advance(const Duration(seconds: 1));
    service.resume();
    expect(
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: true,
        capturedAt: inFlightCapture,
      ),
      isFalse,
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.advance(),
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel', 'start']);
    await service.dispose();
  });

  testWidgets('newer frames and failures supersede old network results', (
    tester,
  ) async {
    final backend = _FakeVibration();
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    final olderCapture = clock.now;
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.advance(),
    );
    await tester.pump();
    expect(
      service.invalidateGuidance(sessionId: session, capturedAt: olderCapture),
      isFalse,
    );
    expect(
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: false,
        capturedAt: olderCapture,
      ),
      isFalse,
    );
    await tester.pump();
    expect(backend.commands, ['start']);
    final failedCapture = clock.advance();
    expect(
      service.invalidateGuidance(sessionId: session, capturedAt: failedCapture),
      isTrue,
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
    expect(
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: true,
        capturedAt: failedCapture,
      ),
      isFalse,
    );
    final nextSession = service.startSession();
    expect(
      service.updateGuidance(
        sessionId: session,
        busInGuidanceZone: true,
        capturedAt: clock.advance(),
      ),
      isFalse,
    );
    service.updateGuidance(
      sessionId: nextSession,
      busInGuidanceZone: true,
      capturedAt: clock.advance(),
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel', 'start']);
    service.stopSession();
    await tester.pump();
    expect(backend.commands, ['start', 'cancel', 'start', 'cancel']);
    await service.dispose();
  });

  testWidgets('unsupported devices do not start or repeatedly check hardware', (
    tester,
  ) async {
    final backend = _FakeVibration()..supported = false;
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    await tester.pump();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.advance(),
    );
    await tester.pump();
    expect(backend.commands, isEmpty);
    expect(backend.capabilityChecks, 1);
    await service.dispose();
  });

  testWidgets('failed starts are cancelled without an endless retry loop', (
    tester,
  ) async {
    final backend = _FakeVibration()..failStart = true;
    final clock = _Clock();
    final service = HapticGuidanceService(
      backend: backend,
      now: () => clock.now,
    );
    final session = service.startSession();
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.now,
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
    service.updateGuidance(
      sessionId: session,
      busInGuidanceZone: true,
      capturedAt: clock.advance(),
    );
    await tester.pump();
    expect(backend.commands, ['start', 'cancel']);
    await service.dispose();
  });
}
