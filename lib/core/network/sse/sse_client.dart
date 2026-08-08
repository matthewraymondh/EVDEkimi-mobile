import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/error/error_mapper.dart';
import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/network/sse/sse_event.dart';
import 'package:evdekimi_ai/core/network/sse/sse_parser.dart';

/// Opens a server-sent-events connection and yields decoded [SseEvent]s.
///
/// Streaming responses need handling that ordinary JSON calls do not:
///
/// * **Error bodies arrive as a stream.** With `ResponseType.stream`, Dio hands
///   back an unread byte stream even for a 500, so `validateStatus` is disabled
///   and the status is checked here — draining the body first so the real server
///   message survives instead of being reported as an opaque parse error.
/// * **Cancellation must free the socket.** Every stream is tied to a
///   [CancelToken]; when the consumer stops listening (user hit stop, screen
///   disposed) the token is cancelled in `onCancel` and the connection closes
///   rather than leaking until the server gives up.
class SseClient {
  SseClient({
    required Dio dio,
    required AppLogger logger,
    required AuthTokenDelegate authDelegate,
    Duration? idleTimeout,
  }) : _dio = dio,
       _logger = logger.scoped('http.sse'),
       _authDelegate = authDelegate,
       _idleTimeout = idleTimeout;

  final Dio _dio;
  final AppLogger _logger;
  final Duration? _idleTimeout;

  /// Used to recover from a 401 on this transport.
  ///
  /// `AuthInterceptor` cannot do it here: it acts in `onError`, and disabling
  /// `validateStatus` above means Dio never raises one. Without this, the chat
  /// endpoint was the only route in the app that could not refresh a token — it
  /// simply reported "session expired" the first time one aged out.
  ///
  /// Note the ordering constraint this creates: two transports can now refresh,
  /// so [AuthTokenDelegate.refreshSession] has to collapse concurrent callers.
  final AuthTokenDelegate _authDelegate;

  /// Issues [method] against [path] and streams the response as events.
  ///
  /// [cancelToken] may be supplied by the caller to stop generation
  /// imperatively; otherwise one is created and cancelled on unsubscribe.
  Stream<SseEvent> stream({
    required String path,
    Object? body,
    String method = 'POST',
    Map<String, dynamic>? queryParameters,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    Map<String, dynamic>? extra,
  }) {
    final token = cancelToken ?? CancelToken();
    late final StreamController<SseEvent> controller;
    StreamSubscription<SseEvent>? subscription;

    Future<Response<ResponseBody>> issue() => _dio.request<ResponseBody>(
      path,
      data: body,
      queryParameters: queryParameters,
      cancelToken: token,
      options: Options(
        method: method,
        responseType: ResponseType.stream,
        // We inspect the status ourselves so a non-2xx body can be read.
        validateStatus: (_) => true,
        headers: {
          'Accept': 'text/event-stream',
          'Cache-Control': 'no-cache',
          ...?headers,
        },
        extra: extra,
      ),
    );

    Future<void> start() async {
      try {
        var response = await issue();

        // Recover from an expired access token exactly once. The retry does not
        // set a header itself — AuthInterceptor attaches the refreshed token on
        // the way out, the same as for any other request.
        if (response.statusCode == 401) {
          _logger.d('Stream got 401; refreshing', fields: {'path': path});
          final refreshed = await _authDelegate.refreshSession();
          if (refreshed) {
            response = await issue();
          } else {
            _logger.w('Refresh failed; invalidating session');
            await _authDelegate.onSessionInvalidated();
          }
        }

        final responseBody = response.data;
        final statusCode = response.statusCode ?? 0;

        if (responseBody == null) {
          throw const SseFormatException('Stream response had no body');
        }

        if (statusCode < 200 || statusCode >= 300) {
          // Read the error payload before surfacing it, otherwise the caller
          // only ever sees the status with no server explanation.
          final payload = await _drain(responseBody.stream);
          _logger.w(
            'Stream rejected',
            fields: {'status': statusCode, 'path': path},
          );
          throw ErrorMapper.parseApiException(
            statusCode,
            _tryDecodeJson(payload),
          );
        }

        _logger.d('Stream opened', fields: {'path': path});

        subscription = SseParser(idleTimeout: _idleTimeout)
            .bind(responseBody.stream)
            .listen(
              controller.add,
              onError: controller.addError,
              onDone: controller.close,
              cancelOnError: true,
            );
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      }
    }

    controller = StreamController<SseEvent>(
      onListen: () => unawaited(start()),
      onCancel: () async {
        await subscription?.cancel();
        if (!token.isCancelled) {
          token.cancel('Stream cancelled by consumer');
        }
        _logger.d('Stream cancelled', fields: {'path': path});
      },
    );

    return controller.stream;
  }

  static Future<String> _drain(Stream<Uint8List> stream) async {
    final buffer = <int>[];
    await for (final chunk in stream) {
      buffer.addAll(chunk);
      // An error body should be small; refuse to buffer a runaway response.
      if (buffer.length > 64 * 1024) break;
    }
    return utf8.decode(buffer, allowMalformed: true);
  }

  static Object? _tryDecodeJson(String payload) {
    if (payload.trim().isEmpty) return null;
    try {
      return jsonDecode(payload);
    } on FormatException {
      return payload;
    }
  }
}
