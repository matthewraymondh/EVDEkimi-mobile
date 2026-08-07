import 'dart:async';
import 'dart:convert';

import 'package:evdekimi_ai/core/network/sse/sse_event.dart';
import 'package:evdekimi_ai/core/network/sse/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// The SSE parser is the component most likely to be subtly wrong, because in
/// manual testing a local mock server almost always delivers one tidy event per
/// chunk. Real networks do not. These tests drive the failure modes that only show
/// up on a slow connection.
void main() {
  /// Feeds [chunks] as separate byte packets, simulating transport framing.
  Future<List<SseEvent>> parse(List<String> chunks) {
    final stream = Stream.fromIterable(
      chunks.map((chunk) => utf8.encode(chunk)),
    );
    return const SseParser().bind(stream).toList();
  }

  group('SseParser framing', () {
    test('parses a single well-formed event', () async {
      final events = await parse(['data: hello\n\n']);
      expect(events, hasLength(1));
      expect(events.single.data, equals('hello'));
      expect(events.single.event, equals('message'));
    });

    test('reassembles an event split mid-token across chunks', () async {
      // The exact case that breaks naive per-chunk parsers.
      final events = await parse(['data: hel', 'lo wor', 'ld\n\n']);
      expect(events.single.data, equals('hello world'));
    });

    test('reassembles an event split inside the field name', () async {
      final events = await parse(['da', 'ta: split\n', '\n']);
      expect(events.single.data, equals('split'));
    });

    test('handles a multi-byte character split across chunks', () async {
      // 'é' is two UTF-8 bytes; cutting between them must not corrupt it.
      final bytes = utf8.encode('data: café\n\n');
      final splitIndex = bytes.indexOf(0xC3) + 1;
      final events = await const SseParser()
          .bind(
            Stream.fromIterable([
              bytes.sublist(0, splitIndex),
              bytes.sublist(splitIndex),
            ]),
          )
          .toList();
      expect(events.single.data, equals('café'));
    });

    test('joins multiple data lines with a newline, per spec', () async {
      final events = await parse(['data: line one\ndata: line two\n\n']);
      expect(events.single.data, equals('line one\nline two'));
    });

    test('parses several events in one chunk', () async {
      final events = await parse(['data: a\n\ndata: b\n\ndata: c\n\n']);
      expect(events.map((event) => event.data), equals(['a', 'b', 'c']));
    });

    test('handles CRLF line endings', () async {
      final events = await parse(['data: windows\r\n\r\n']);
      expect(events.single.data, equals('windows'));
    });

    test('strips exactly one leading space after the colon', () async {
      final events = await parse(['data:  two spaces\n\n']);
      // One space is framing; the second is content.
      expect(events.single.data, equals(' two spaces'));
    });

    test('handles a field with no colon as an empty value', () async {
      final events = await parse(['data\n\n']);
      expect(events.single.data, isEmpty);
    });

    test('ignores comment lines used as keep-alive pings', () async {
      final events = await parse([': ping\n\n', 'data: real\n\n']);
      expect(events, hasLength(1));
      expect(events.single.data, equals('real'));
    });

    test('ignores unknown fields', () async {
      final events = await parse(['unknown: x\ndata: kept\n\n']);
      expect(events.single.data, equals('kept'));
    });

    test(
      'emits a trailing event when the stream closes without a blank line',
      () async {
        // Real servers close abruptly more often than they send a tidy terminator.
        final events = await parse(['data: truncated\n']);
        expect(events.single.data, equals('truncated'));
      },
    );

    test('parses event names, ids and retry hints', () async {
      final events = await parse([
        'event: token\nid: 42\nretry: 3000\ndata: payload\n\n',
      ]);
      expect(events.single.event, equals('token'));
      expect(events.single.id, equals('42'));
      expect(events.single.retry, equals(3000));
    });

    test('carries the last id forward to later events', () async {
      final events = await parse(['id: 1\ndata: a\n\n', 'data: b\n\n']);
      expect(events[0].id, equals('1'));
      // Per spec the last id persists until replaced, which is what makes
      // Last-Event-ID reconnection work.
      expect(events[1].id, equals('1'));
    });

    test('recognises the OpenAI terminator', () async {
      final events = await parse(['data: [DONE]\n\n']);
      expect(events.single.isDone, isTrue);
    });

    test('produces nothing for an empty stream', () async {
      final events = await parse([]);
      expect(events, isEmpty);
    });

    test('ignores blank lines with no buffered event', () async {
      final events = await parse(['\n\n\n', 'data: x\n\n']);
      expect(events, hasLength(1));
    });
  });

  group('SseParser idle timeout', () {
    test('errors when no bytes arrive within the idle window', () async {
      // A generation can legitimately pause between tokens, so the guard has to
      // be "silence for N", not a cap on total duration.
      final controller = StreamController<List<int>>();
      const parser = SseParser(idleTimeout: Duration(milliseconds: 50));

      final future = parser.bind(controller.stream).toList();
      controller.add(utf8.encode('data: first\n\n'));
      // Never send anything else; let the idle timer fire.

      await expectLater(future, throwsA(isA<TimeoutException>()));
      await controller.close();
    });

    test('does not error while chunks keep arriving', () async {
      final controller = StreamController<List<int>>();
      const parser = SseParser(idleTimeout: Duration(milliseconds: 120));
      final future = parser.bind(controller.stream).toList();

      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        controller.add(utf8.encode('data: chunk$i\n\n'));
      }
      await controller.close();

      final events = await future;
      expect(events, hasLength(4));
    });
  });

  group('SseParser.parseLines', () {
    test('can be driven directly with lines, without byte framing', () async {
      final events = await SseParser.parseLines(
        Stream.fromIterable(['data: direct', '']),
      ).toList();
      expect(events.single.data, equals('direct'));
    });
  });
}
