import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late List<Completer<Object?>> utterances;
  late TtsService service;

  Future<void> waitForUtterances(int count) async {
    for (
      var attempt = 0;
      attempt < 20 && utterances.length < count;
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(utterances, hasLength(count));
  }

  Future<void> platformEvent(String method, [Object? arguments]) async {
    final handled = Completer<void>();
    await messenger.handlePlatformMessage(
      'flutter_tts',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) => handled.complete(),
    );
    await handled.future;
  }

  setUp(() {
    calls = [];
    utterances = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'speak') {
        final utterance = Completer<Object?>();
        utterances.add(utterance);
        return utterance.future;
      }
      return 1;
    });
    service = TtsService();
  });

  tearDown(() async {
    await service.dispose();
    for (final utterance in utterances) {
      if (!utterance.isCompleted) utterance.complete(0);
    }
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'keeps Arabic announcement and waits for actual utterance completion',
    () async {
      var finished = false;
      final speech = service.speakRouteNumber('123').then((result) {
        finished = true;
        return result;
      });
      await waitForUtterances(1);

      expect(
        calls.where((call) => call.method == 'setLanguage').single.arguments,
        'ar',
      );
      expect(
        calls.where((call) => call.method == 'setSpeechRate').single.arguments,
        0.5,
      );
      expect(
        calls
            .where((call) => call.method == 'awaitSpeakCompletion')
            .single
            .arguments,
        true,
      );
      expect(
        calls.where((call) => call.method == 'speak').single.arguments,
        'الباص رقم 123',
      );
      expect(finished, isFalse);

      utterances.single.complete(1);
      expect(await speech, isTrue);
    },
  );

  test('deduplicates routes while replay keeps the existing text', () async {
    expect(await service.speakRouteNumber(''), isFalse);
    expect(await service.replayLastRoute(), isFalse);
    final speech = service.speakRouteNumber('7');
    await waitForUtterances(1);
    expect(await service.speakRouteNumber('7'), isFalse);
    utterances.first.complete(1);
    expect(await speech, isTrue);

    final replay = service.replayLastRoute();
    await waitForUtterances(2);
    utterances.last.complete(1);
    expect(await replay, isTrue);
    expect(
      calls
          .where((call) => call.method == 'speak')
          .map((call) => call.arguments),
      ['الباص رقم 7', 'الباص رقم 7'],
    );
  });

  test(
    'replay cancels the old future and only its own completion succeeds',
    () async {
      final speech = service.speakRouteNumber('7');
      await waitForUtterances(1);
      final replay = service.replayLastRoute();
      expect(await speech, isFalse);
      await waitForUtterances(2);

      var replayFinished = false;
      unawaited(replay.then((_) => replayFinished = true));
      utterances.first.complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(replayFinished, isFalse);
      utterances.last.complete(1);
      expect(await replay, isTrue);
    },
  );

  test('stop invalidates late successful platform completion', () async {
    final speech = service.speakRouteNumber('7');
    await waitForUtterances(1);
    await service.stop();
    expect(await speech, isFalse);
    utterances.single.complete(1);
    await Future<void>.delayed(Duration.zero);
  });

  test('an interrupted route can be announced again after resume', () async {
    final speech = service.speakRouteNumber('7');
    await waitForUtterances(1);
    await service.stop();
    expect(await speech, isFalse);

    final retry = service.speakRouteNumber('7');
    await waitForUtterances(2);
    utterances.last.complete(1);
    expect(await retry, isTrue);
    expect(await service.speakRouteNumber('7'), isFalse);
  });

  test('dispose blocks speech and invalidates pending completion', () async {
    final speech = service.speakRouteNumber('7');
    await waitForUtterances(1);
    await service.dispose();
    expect(await speech, isFalse);
    utterances.single.complete(1);
    expect(await service.speakRouteNumber('9'), isFalse);
    expect(await service.replayLastRoute(), isFalse);
    expect(utterances, hasLength(1));
  });

  test(
    'a cancelled native utterance never reports speech completion',
    () async {
      final speech = service.speakRouteNumber('7');
      await waitForUtterances(1);
      utterances.single.complete(0);
      expect(await speech, isFalse);
    },
  );

  test('a late untagged cancel cannot cancel a replay utterance', () async {
    final speech = service.speakRouteNumber('7');
    await waitForUtterances(1);
    final replay = service.replayLastRoute();
    expect(await speech, isFalse);
    await waitForUtterances(2);
    await platformEvent('speak.onCancel');
    utterances.last.complete(1);
    expect(await replay, isTrue);
  });

  test('speech engine errors do not report successful completion', () async {
    final speech = service.speakRouteNumber('7');
    await waitForUtterances(1);
    await platformEvent('speak.onError', 'Speech engine failed');
    expect(await speech, isFalse);
  });

  test('rejected utterance and platform exception are unsuccessful', () async {
    final speech = service.speakRouteNumber('7');
    await waitForUtterances(1);
    utterances.first.complete(0);
    expect(await speech, isFalse);

    final replay = service.replayLastRoute();
    await waitForUtterances(2);
    utterances.last.completeError(PlatformException(code: 'tts_error'));
    expect(await replay, isFalse);
  });

  test(
    'stop during initialization prevents a queued utterance from starting',
    () async {
      final configuration = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'setLanguage') return configuration.future;
        return 1;
      });
      final speech = service.speakRouteNumber('7');
      await Future<void>.delayed(Duration.zero);
      await service.stop();
      configuration.complete(1);
      expect(await speech, isFalse);
      expect(calls.where((call) => call.method == 'speak'), isEmpty);
    },
  );
}
