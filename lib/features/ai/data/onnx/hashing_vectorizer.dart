import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Turns text into the fixed-width float vector the ONNX router expects.
///
/// **This is a port of `tools/train_router_model.py` and must stay identical to
/// it.** If the two disagree by even one bucket, the model receives features from
/// a different distribution than it was trained on and silently degrades — no
/// crash, just worse answers. `test/features/ai/onnx_parity_test.dart` pins the
/// two together against a golden fixture generated at training time, so drift
/// fails CI instead of shipping.
///
/// Why hashing rather than a learned vocabulary: no vocab file to bundle or
/// version, unbounded vocabulary handled gracefully, and a fixed memory
/// footprint. The cost is hash collisions, which at 512 buckets for short chat
/// messages are rare enough to be noise the training absorbs.
class HashingVectorizer {
  const HashingVectorizer({this.dimensions = defaultDimensions});

  /// Must equal `FEATURE_DIM` in the training script.
  static const int defaultDimensions = 512;

  static const int _fnvOffsetBasis = 2166136261;
  static const int _fnvPrime = 16777619;
  static const int _uint32Mask = 0xFFFFFFFF;

  static final RegExp _nonAlphanumeric = RegExp('[^a-z0-9]+');
  static final RegExp _whitespace = RegExp(r'\s+');

  final int dimensions;

  /// Lowercases and collapses every non-alphanumeric run to a single space.
  static String normalise(String text) =>
      text.toLowerCase().replaceAll(_nonAlphanumeric, ' ').trim();

  /// Word unigrams, word bigrams, and character trigrams.
  ///
  /// The three families are prefixed (`w:`, `b:`, `c:`) so a word and a trigram
  /// that happen to share characters cannot hash to the same feature.
  /// Trigrams run over a space-padded string, which is what lets the model see
  /// word boundaries (`' th'` differs from `'oth'`).
  static List<String> extractFeatures(String text) {
    final normalised = normalise(text);
    if (normalised.isEmpty) return const [];

    final words = normalised.split(_whitespace);
    final features = <String>[];

    for (final word in words) {
      features.add('w:$word');
    }
    for (var i = 0; i < words.length - 1; i++) {
      features.add('b:${words[i]}_${words[i + 1]}');
    }

    final padded = ' $normalised ';
    for (var i = 0; i < padded.length - 2; i++) {
      features.add('c:${padded.substring(i, i + 3)}');
    }

    return features;
  }

  /// FNV-1a (32-bit) over the UTF-8 bytes of [value].
  ///
  /// Masked to 32 bits after every multiply: Dart ints are 64-bit, so without
  /// the mask the result would diverge from the Python reference immediately.
  static int fnv1a32(String value) {
    var hash = _fnvOffsetBasis;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * _fnvPrime) & _uint32Mask;
    }
    return hash;
  }

  /// The L2-normalised feature vector for [text].
  ///
  /// An empty or purely-punctuation input yields an all-zero vector; callers
  /// must treat that as "no signal" rather than feeding it to the model, since
  /// the classifier's output for a zero vector is meaningless (it collapses to
  /// the bias term).
  Float32List transform(String text) {
    final vector = Float32List(dimensions);
    final features = extractFeatures(text);
    if (features.isEmpty) return vector;

    for (final feature in features) {
      vector[fnv1a32(feature) % dimensions] += 1.0;
    }

    var sumOfSquares = 0.0;
    for (final value in vector) {
      sumOfSquares += value * value;
    }
    if (sumOfSquares > 0) {
      final inverseNorm = 1.0 / math.sqrt(sumOfSquares);
      for (var i = 0; i < vector.length; i++) {
        vector[i] *= inverseNorm;
      }
    }
    return vector;
  }

  /// Whether [text] carries enough signal to classify.
  static bool hasSignal(String text) => extractFeatures(text).isNotEmpty;
}

/// Vector maths for the retrieval half of the on-device feature.
abstract final class VectorMath {
  /// Cosine similarity, safe against zero-length vectors.
  ///
  /// Computed from raw dot/norms rather than assuming unit length: embeddings
  /// come out of a `tanh` and are *not* normalised by the graph.
  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }
}
