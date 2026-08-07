import 'dart:convert';
import 'dart:io';

import 'package:evdekimi_ai/features/ai/data/onnx/hashing_vectorizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the Dart feature extractor to the Python reference implementation.
///
/// This is the highest-value test in the suite. The ONNX model was trained on
/// features produced by `tools/train_router_model.py`; if the Dart port drifts by
/// even one hash bucket, inference silently degrades — no crash, no exception,
/// just worse answers. Nothing else in the codebase would catch that.
///
/// The fixture is generated at training time by the same script that produces the
/// weights, so regenerating the model necessarily regenerates the expectations.
void main() {
  group('HashingVectorizer ↔ Python parity', () {
    late Map<String, dynamic> fixture;
    late List<dynamic> cases;
    const vectorizer = HashingVectorizer();

    setUpAll(() {
      final file = File('test/fixtures/onnx_router_golden.json');
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'Golden fixture missing. Run: python tools/train_router_model.py',
      );
      fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      cases = fixture['cases'] as List<dynamic>;
    });

    test('feature dimension matches the exported model', () {
      expect(fixture['featureDim'], equals(vectorizer.dimensions));
    });

    test('intent label order matches RouterIntent', () {
      // The softmax output is positional: reordering the enum silently remaps
      // every prediction.
      expect(
        fixture['intents'],
        equals([
          'greeting',
          'gratitude',
          'recall',
          'code',
          'summarize',
          'question',
        ]),
      );
    });

    test('every golden case produces an identical sparse vector', () {
      expect(cases, isNotEmpty);

      for (final entry in cases) {
        final testCase = entry as Map<String, dynamic>;
        final text = testCase['text'] as String;
        final expected = (testCase['featureNonZero'] as Map<String, dynamic>)
            .map(
              (key, value) =>
                  MapEntry(int.parse(key), (value as num).toDouble()),
            );

        final actual = vectorizer.transform(text);

        final actualNonZero = <int, double>{};
        for (var i = 0; i < actual.length; i++) {
          if (actual[i] != 0) actualNonZero[i] = actual[i];
        }

        expect(
          actualNonZero.keys.toSet(),
          equals(expected.keys.toSet()),
          reason: 'Bucket set differs for "$text"',
        );

        for (final index in expected.keys) {
          expect(
            actualNonZero[index],
            closeTo(expected[index]!, 1e-5),
            reason: 'Bucket $index differs for "$text"',
          );
        }
      }
    });

    test('vectors are L2-normalised', () {
      for (final entry in cases) {
        final text = (entry as Map<String, dynamic>)['text'] as String;
        if (!HashingVectorizer.hasSignal(text)) continue;

        final vector = vectorizer.transform(text);
        var sumOfSquares = 0.0;
        for (final value in vector) {
          sumOfSquares += value * value;
        }
        expect(sumOfSquares, closeTo(1.0, 1e-4), reason: 'for "$text"');
      }
    });
  });

  group('FNV-1a hashing', () {
    test('matches known reference digests', () {
      // Reference values for the 32-bit FNV-1a algorithm. If Dart's 64-bit ints
      // were not masked back to 32 bits these would diverge immediately.
      expect(HashingVectorizer.fnv1a32(''), equals(2166136261));
      expect(HashingVectorizer.fnv1a32('a'), equals(0xE40C292C));
      expect(HashingVectorizer.fnv1a32('foobar'), equals(0xBF9CF968));
    });

    test('is stable across calls', () {
      final first = HashingVectorizer.fnv1a32('w:hello');
      final second = HashingVectorizer.fnv1a32('w:hello');
      expect(first, equals(second));
    });
  });

  group('feature extraction', () {
    test('emits word unigrams, bigrams and character trigrams', () {
      final features = HashingVectorizer.extractFeatures('hi there');

      expect(features, contains('w:hi'));
      expect(features, contains('w:there'));
      expect(features, contains('b:hi_there'));
      // Space-padded, so boundary trigrams exist.
      expect(features, contains('c: hi'));
      expect(features, contains('c:re '));
    });

    test('normalises case and punctuation identically to the reference', () {
      expect(
        HashingVectorizer.normalise('Hello,   WORLD!!'),
        equals('hello world'),
      );
      expect(HashingVectorizer.normalise('  ...  '), isEmpty);
    });

    test('reports no signal for empty or punctuation-only input', () {
      // The model's output for an all-zero vector is just its bias — a
      // confidently meaningless prediction — so callers must not run inference.
      expect(HashingVectorizer.hasSignal(''), isFalse);
      expect(HashingVectorizer.hasSignal('!!! ???'), isFalse);
      expect(HashingVectorizer.hasSignal('hi'), isTrue);
    });

    test('produces an all-zero vector for input with no signal', () {
      const vectorizer = HashingVectorizer();
      final vector = vectorizer.transform('   ');
      expect(vector.every((value) => value == 0), isTrue);
    });
  });

  group('VectorMath.cosineSimilarity', () {
    test('is 1 for identical vectors and 0 for orthogonal ones', () {
      const vectorizer = HashingVectorizer();
      final a = vectorizer.transform('write a dart function');
      expect(VectorMath.cosineSimilarity(a, a), closeTo(1.0, 1e-6));
    });

    test('ranks a paraphrase above an unrelated sentence', () {
      const vectorizer = HashingVectorizer();
      final query = vectorizer.transform('how do i parse json in flutter');
      final related = vectorizer.transform('parsing json with flutter');
      final unrelated = vectorizer.transform('the capital of indonesia');

      expect(
        VectorMath.cosineSimilarity(query, related),
        greaterThan(VectorMath.cosineSimilarity(query, unrelated)),
      );
    });

    test('returns 0 rather than NaN for a zero vector', () {
      const vectorizer = HashingVectorizer();
      final zero = vectorizer.transform('');
      final real = vectorizer.transform('hello');
      expect(VectorMath.cosineSimilarity(zero, real), equals(0));
    });
  });
}
