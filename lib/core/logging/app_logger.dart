import 'package:evdekimi_ai/core/logging/log_record.dart';
import 'package:evdekimi_ai/core/logging/log_sink.dart';
import 'package:flutter/foundation.dart';

/// The logging facade used everywhere in the app.
///
/// Two design points matter here:
///
/// 1. Call sites depend on this interface, never on a package. Swapping in
///    Crashlytics/Sentry later is a change to sink wiring only.
/// 2. [scoped] returns a cheap child logger that stamps every record with a
///    subsystem name, so `logger.d('sent')` in the chat stream is still
///    attributable without repeating the tag at each call.
class AppLogger {
  AppLogger({
    required List<LogSink> sinks,
    String scope = 'app',
    Map<String, Object?> boundFields = const {},
    Set<String> redactedKeys = defaultRedactedKeys,
  }) : _sinks = sinks,
       _scope = scope,
       _boundFields = boundFields,
       _redactedKeys = redactedKeys;

  /// A logger that discards everything, for tests and headless contexts.
  factory AppLogger.silent() => AppLogger(sinks: const []);

  /// Field names whose values are replaced before they can reach a sink.
  ///
  /// Defence in depth: the redaction happens in the logger rather than at call
  /// sites, so forgetting to scrub a token at one call site cannot leak it.
  static const Set<String> defaultRedactedKeys = {
    'password',
    'token',
    'accessToken',
    'access_token',
    'refreshToken',
    'refresh_token',
    'authorization',
    'apiKey',
    'api_key',
    'secret',
  };

  static const String _redacted = '***';

  final List<LogSink> _sinks;
  final String _scope;
  final Map<String, Object?> _boundFields;
  final Set<String> _redactedKeys;

  /// Derives a logger for a subsystem, optionally binding persistent fields.
  AppLogger scoped(String scope, {Map<String, Object?> fields = const {}}) =>
      AppLogger(
        sinks: _sinks,
        scope: _scope == 'app' ? scope : '$_scope.$scope',
        boundFields: {..._boundFields, ...fields},
        redactedKeys: _redactedKeys,
      );

  void t(String message, {Map<String, Object?> fields = const {}}) =>
      _log(LogLevel.trace, message, fields: fields);

  void d(String message, {Map<String, Object?> fields = const {}}) =>
      _log(LogLevel.debug, message, fields: fields);

  void i(String message, {Map<String, Object?> fields = const {}}) =>
      _log(LogLevel.info, message, fields: fields);

  void w(
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _log(
    LogLevel.warning,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  void e(
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) => _log(
    LogLevel.error,
    message,
    fields: fields,
    error: error,
    stackTrace: stackTrace,
  );

  void _log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_sinks.isEmpty) return;

    // Build the record once and only if at least one sink wants it; formatting
    // and map merging on a hot streaming path is not free.
    final interested = _sinks
        .where((sink) => level >= sink.minimumLevel)
        .toList(growable: false);
    if (interested.isEmpty) return;

    final record = LogRecord(
      level: level,
      scope: _scope,
      message: message,
      timestamp: DateTime.now(),
      fields: _redact({..._boundFields, ...fields}),
      error: error,
      stackTrace: stackTrace,
    );

    for (final sink in interested) {
      try {
        sink.add(record);
      } catch (sinkError, sinkStack) {
        // A failing sink must never take down the caller. Report in debug only.
        assert(() {
          debugPrint(
            'LogSink ${sink.runtimeType} threw: $sinkError\n$sinkStack',
          );
          return true;
        }());
      }
    }
  }

  Map<String, Object?> _redact(Map<String, Object?> fields) {
    if (fields.isEmpty) return const {};
    var needsRedaction = false;
    for (final key in fields.keys) {
      if (_redactedKeys.contains(key)) {
        needsRedaction = true;
        break;
      }
    }
    if (!needsRedaction) return fields;
    return {
      for (final entry in fields.entries)
        entry.key: _redactedKeys.contains(entry.key) ? _redacted : entry.value,
    };
  }

  void dispose() {
    for (final sink in _sinks) {
      sink.dispose();
    }
  }
}
