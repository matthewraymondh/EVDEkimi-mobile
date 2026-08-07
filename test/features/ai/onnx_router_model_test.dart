import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/onnx_router_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Failure handling for the on-device runtime.
///
/// These cover the path that actually runs on most machines: the native library
/// is missing. `onnxruntime` ships `arm64-v8a` and `armeabi-v7a` only, so every
/// x86_64 emulator fails to `dlopen` it — and that must degrade quietly to the
/// cloud engine rather than spamming load attempts.
///
/// Successful inference is deliberately not tested here: it needs the real native
/// runtime, which cannot load in a desktop test process. The feature extraction
/// feeding it *is* fully covered, in `hashing_vectorizer_parity_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// An asset bundle that fails every load, standing in for a device where the
  /// runtime or the asset cannot be read.
  late _CountingBundle bundle;

  setUp(() => bundle = _CountingBundle());

  group('OnnxRouterModel when the runtime cannot load', () {
    test('reports unavailable rather than throwing', () async {
      final model = OnnxRouterModel(logger: AppLogger.silent(), bundle: bundle);

      expect(await model.isAvailable(), isFalse);
    });

    test(
      'attempts initialisation only once, however often it is called',
      () async {
        // The regression this locks down: an earlier version cleared the
        // in-flight future on failure, so every embed() retried a doomed dlopen.
        // On a real device that produced a dozen identical warnings per message.
        final model = OnnxRouterModel(
          logger: AppLogger.silent(),
          bundle: bundle,
        );

        for (var i = 0; i < 5; i++) {
          await model.isAvailable();
        }
        for (var i = 0; i < 3; i++) {
          await model.embed('hello there').catchError((_) => null);
        }

        expect(
          model.initialisationAttempts,
          equals(1),
          reason: 'the failure must be latched after the first attempt',
        );
      },
    );

    test(
      'surfaces the same typed failure on the first attempt and later ones',
      () async {
        // Otherwise ErrorMapper would classify one condition two different ways:
        // a raw platform error once, a typed one thereafter.
        final model = OnnxRouterModel(
          logger: AppLogger.silent(),
          bundle: bundle,
        );

        await expectLater(
          model.embed('hello'),
          throwsA(isA<EngineUnavailableException>()),
        );
        await expectLater(
          model.embed('hello again'),
          throwsA(isA<EngineUnavailableException>()),
        );
      },
    );

    test('explains the cause instead of leaving it blank', () async {
      final model = OnnxRouterModel(logger: AppLogger.silent(), bundle: bundle);
      await model.isAvailable();

      expect(model.unavailableReason, isNotNull);
      expect(model.unavailableReason, isNotEmpty);
    });

    test('skips inference entirely for input with no features', () async {
      // A zero vector would make the model return its bias — a confidently
      // meaningless answer — so this must short-circuit before touching the
      // runtime at all.
      final model = OnnxRouterModel(logger: AppLogger.silent(), bundle: bundle);

      expect(await model.predict('   '), isNull);
      expect(await model.predict('!!! ???'), isNull);
      expect(
        model.initialisationAttempts,
        isZero,
        reason: 'no-signal input must not even try to load the runtime',
      );
    });
  });
}

/// Counts load attempts and fails them all.
class _CountingBundle extends CachingAssetBundle {
  int loadAttempts = 0;

  @override
  Future<ByteData> load(String key) async {
    loadAttempts++;
    throw FlutterError('Asset unavailable in test: $key');
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    loadAttempts++;
    throw FlutterError('Asset unavailable in test: $key');
  }
}
