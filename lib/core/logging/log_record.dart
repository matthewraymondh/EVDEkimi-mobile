import 'package:flutter/foundation.dart';

/// Severity ordering used for sink filtering.
enum LogLevel {
  trace(0, 'TRC'),
  debug(1, 'DBG'),
  info(2, 'INF'),
  warning(3, 'WRN'),
  error(4, 'ERR');

  const LogLevel(this.severity, this.label);

  final int severity;
  final String label;

  bool operator >=(LogLevel other) => severity >= other.severity;
}

/// One structured log entry.
///
/// Logs carry a [scope] and an optional [fields] map rather than pre-formatted
/// strings, so a future crash-reporting or analytics sink can consume them
/// without re-parsing text.
@immutable
class LogRecord {
  const LogRecord({
    required this.level,
    required this.scope,
    required this.message,
    required this.timestamp,
    this.fields = const {},
    this.error,
    this.stackTrace,
  });

  final LogLevel level;

  /// Subsystem that emitted the record, e.g. `chat.stream` or `http`.
  final String scope;

  final String message;
  final DateTime timestamp;

  /// Structured context. Keep values small and non-sensitive.
  final Map<String, Object?> fields;

  final Object? error;
  final StackTrace? stackTrace;

  /// Single-line rendering used by the console sink and the in-app log viewer.
  String format({bool includeTimestamp = true}) {
    final buffer = StringBuffer();
    if (includeTimestamp) {
      final time = timestamp.toIso8601String().split('T').last;
      buffer.write('$time ');
    }
    buffer.write('${level.label} [$scope] $message');
    if (fields.isNotEmpty) {
      buffer.write(' ');
      buffer.write(
        fields.entries.map((entry) => '${entry.key}=${entry.value}').join(' '),
      );
    }
    if (error != null) buffer.write(' error=$error');
    return buffer.toString();
  }

  @override
  String toString() => format();
}
