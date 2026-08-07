import 'dart:async';
import 'dart:convert';

import 'package:evdekimi_ai/core/network/sse/sse_event.dart';

/// Decodes a raw byte stream into [SseEvent]s per the WHATWG event-stream spec.
///
/// This is hand-written rather than taken from a package for three reasons that
/// all bit in practice with LLM streaming:
///
/// * **Chunk boundaries are arbitrary.** A single token can be split across two
///   TCP reads, and a multi-byte UTF-8 character can be split mid-sequence.
///   Both are handled by chaining the streaming UTF-8 decoder and
///   [LineSplitter], which each buffer their own partial state.
/// * **Idle, not total, timeouts.** A model may legitimately think for seconds
///   between tokens, so the useful failure signal is "no bytes at all for N
///   seconds" rather than a cap on the whole response.
/// * **Cancellation must be prompt.** Stopping generation has to tear the
///   socket down immediately, which means owning the subscription lifecycle.
class SseParser extends StreamTransformerBase<List<int>, SseEvent> {
  const SseParser({this.idleTimeout});

  /// Maximum silence between two byte chunks before the stream errors.
  final Duration? idleTimeout;

  @override
  Stream<SseEvent> bind(Stream<List<int>> stream) {
    var byteStream = stream;
    final timeout = idleTimeout;
    if (timeout != null) {
      byteStream = byteStream.timeout(
        timeout,
        onTimeout: (sink) => sink.addError(
          TimeoutException('No stream data for ${timeout.inSeconds}s'),
        ),
      );
    }

    // utf8.decoder carries partial multi-byte sequences across chunks;
    // LineSplitter carries partial lines. Together they make the parser
    // independent of how the transport happens to fragment the response.
    //
    // `Converter.bind` rather than `Stream.transform`: transform() checks the
    // transformer against the stream's *reified* type argument, and Dio hands us
    // a `Stream<Uint8List>`. A `Converter<List<int>, String>` is not a
    // `StreamTransformer<Uint8List, String>`, so transform() throws at runtime
    // even though the code type-checks. bind() takes `Stream<List<int>>` and
    // accepts the subtype cleanly.
    final decoded = const Utf8Decoder(allowMalformed: true).bind(byteStream);
    final lines = const LineSplitter().bind(decoded);

    return parseLines(lines);
  }

  /// Assembles events from a stream of already-split lines.
  ///
  /// Exposed separately so tests can drive the state machine directly without
  /// constructing byte chunks.
  static Stream<SseEvent> parseLines(Stream<String> lines) async* {
    final dataLines = <String>[];
    String? eventName;
    String? lastId;
    int? retry;

    void reset() {
      dataLines.clear();
      eventName = null;
      retry = null;
    }

    await for (final line in lines) {
      // A blank line dispatches the buffered event.
      if (line.isEmpty) {
        if (dataLines.isEmpty && eventName == null) continue;
        if (dataLines.isNotEmpty) {
          yield SseEvent(
            data: dataLines.join('\n'),
            event: eventName ?? 'message',
            id: lastId,
            retry: retry,
          );
        }
        reset();
        continue;
      }

      // Lines beginning with a colon are comments; servers use them as
      // keep-alive pings, which is also what resets our idle timer.
      if (line.startsWith(':')) continue;

      final colonIndex = line.indexOf(':');
      final String field;
      final String value;
      if (colonIndex == -1) {
        // A line with no colon is a field name with an empty value.
        field = line;
        value = '';
      } else {
        field = line.substring(0, colonIndex);
        // Exactly one leading space after the colon is part of the framing.
        final rawValue = line.substring(colonIndex + 1);
        value = rawValue.startsWith(' ') ? rawValue.substring(1) : rawValue;
      }

      switch (field) {
        case 'data':
          dataLines.add(value);
        case 'event':
          eventName = value;
        case 'id':
          // The spec requires ignoring ids containing a NULL character.
          if (!value.contains('\u0000')) lastId = value;
        case 'retry':
          final parsed = int.tryParse(value);
          if (parsed != null) retry = parsed;
        default:
          // Unknown fields are ignored, per spec.
          break;
      }
    }

    // A stream that ends without a trailing blank line still has a final event
    // worth delivering; real servers close abruptly more often than not.
    if (dataLines.isNotEmpty) {
      yield SseEvent(
        data: dataLines.join('\n'),
        event: eventName ?? 'message',
        id: lastId,
        retry: retry,
      );
    }
  }
}
