import 'dart:async';
import 'dart:developer' as developer;

import 'package:evdekimi_ai/core/logging/log_record.dart';
import 'package:flutter/foundation.dart';

/// A destination for [LogRecord]s.
///
/// Splitting sinks from the logger facade is what lets the same call sites feed
/// the debug console, the in-app log viewer, and (later) a crash reporter
/// without touching any calling code.
abstract interface class LogSink {
  /// Records below this level are not delivered to this sink.
  LogLevel get minimumLevel;

  void add(LogRecord record);

  FutureOr<void> dispose();
}

/// Writes to the Dart developer log. Debug/profile builds only.
class ConsoleLogSink implements LogSink {
  ConsoleLogSink({this.minimumLevel = LogLevel.debug});

  @override
  final LogLevel minimumLevel;

  @override
  void add(LogRecord record) {
    // `dart:developer` keeps records attached to the isolate and avoids the
    // 1 KB truncation that print() applies on Android.
    developer.log(
      record.format(includeTimestamp: false),
      time: record.timestamp,
      name: record.scope,
      level: _toDeveloperLevel(record.level),
      error: record.error,
      stackTrace: record.stackTrace,
    );
  }

  @override
  void dispose() {}

  /// Maps onto `package:logging`-style numeric levels understood by DevTools.
  static int _toDeveloperLevel(LogLevel level) => switch (level) {
    LogLevel.trace => 300,
    LogLevel.debug => 500,
    LogLevel.info => 800,
    LogLevel.warning => 900,
    LogLevel.error => 1000,
  };
}

/// Keeps the most recent records in memory for the in-app diagnostics screen.
///
/// Bounded on purpose: a chat app that streams tokens can emit thousands of
/// records per session, and an unbounded buffer would be a slow memory leak.
class RingBufferLogSink extends ChangeNotifier implements LogSink {
  RingBufferLogSink({this.capacity = 500, this.minimumLevel = LogLevel.debug});

  final int capacity;

  @override
  final LogLevel minimumLevel;

  final List<LogRecord> _records = <LogRecord>[];

  /// Newest-last view of the buffer.
  List<LogRecord> get records => List.unmodifiable(_records);

  @override
  void add(LogRecord record) {
    _records.add(record);
    if (_records.length > capacity) {
      _records.removeRange(0, _records.length - capacity);
    }
    notifyListeners();
  }

  void clear() {
    _records.clear();
    notifyListeners();
  }

  /// Plain-text export used by the "copy logs" action.
  String export() => _records.map((record) => record.format()).join('\n');

  @override
  void dispose() {
    _records.clear();
    super.dispose();
  }
}

/// Collects records for assertions in tests.
@visibleForTesting
class MemoryLogSink implements LogSink {
  MemoryLogSink({this.minimumLevel = LogLevel.trace});

  final List<LogRecord> records = <LogRecord>[];

  @override
  final LogLevel minimumLevel;

  @override
  void add(LogRecord record) => records.add(record);

  @override
  void dispose() => records.clear();
}
