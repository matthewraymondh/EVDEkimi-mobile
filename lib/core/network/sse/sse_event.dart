import 'package:flutter/foundation.dart';

/// A single dispatched server-sent event.
///
/// Field names mirror the WHATWG event-stream specification so the parser can
/// be checked against it directly.
@immutable
class SseEvent {
  const SseEvent({
    required this.data,
    this.event = 'message',
    this.id,
    this.retry,
  });

  /// The joined `data:` payload. Multiple `data:` lines are joined with `\n`.
  final String data;

  /// The `event:` name, defaulting to `message` per the specification.
  final String event;

  /// The `id:` field, used as the `Last-Event-ID` on reconnection.
  final String? id;

  /// The `retry:` reconnection hint in milliseconds.
  final int? retry;

  /// Whether this is the OpenAI-style terminator (`data: [DONE]`).
  bool get isDone => data.trim() == '[DONE]';

  @override
  bool operator ==(Object other) =>
      other is SseEvent &&
      other.data == data &&
      other.event == event &&
      other.id == id &&
      other.retry == retry;

  @override
  int get hashCode => Object.hash(data, event, id, retry);

  @override
  String toString() =>
      'SseEvent(event: $event, id: $id, data: ${data.length > 64 ? '${data.substring(0, 64)}…' : data})';
}
