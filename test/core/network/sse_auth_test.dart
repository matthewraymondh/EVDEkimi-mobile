import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/network/sse/sse_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Token refresh on the streaming transport.
///
/// This path had a hole for a long time and nothing caught it: `SseClient` sets
/// `validateStatus: (_) => true` so it can read a non-2xx body, which means Dio
/// never raises a `DioException` — and `AuthInterceptor` only acts in `onError`.
/// The chat endpoint was therefore the one route in the app that could not
/// refresh an expired token; it just reported "session expired" to the user.
///
/// It only reproduced after the access token aged out, which is why it looked
/// intermittent rather than broken.
void main() {
  late _RecordingDelegate delegate;

  SseClient buildClient(_ScriptedAdapter adapter) {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    return SseClient(
      dio: dio,
      logger: AppLogger.silent(),
      authDelegate: delegate,
    );
  }

  setUp(() => delegate = _RecordingDelegate());

  test('refreshes once and replays the stream after a 401', () async {
    final adapter = _ScriptedAdapter([
      _unauthorised(),
      _eventStream('data: hello\n\ndata: [DONE]\n\n'),
    ]);

    final events = await buildClient(adapter).stream(path: '/chat').toList();

    expect(delegate.refreshCalls, equals(1));
    expect(adapter.requestCount, equals(2), reason: 'the request is replayed');
    expect(events.first.data, equals('hello'));
    expect(
      delegate.invalidateCalls,
      isZero,
      reason: 'a successful refresh must not sign the user out',
    );
  });

  test('signs out when the refresh itself fails', () async {
    delegate.canRefresh = false;
    final adapter = _ScriptedAdapter([_unauthorised()]);

    await expectLater(
      buildClient(adapter).stream(path: '/chat').toList(),
      throwsA(isA<ApiException>()),
    );

    expect(delegate.refreshCalls, equals(1));
    expect(delegate.invalidateCalls, equals(1));
    expect(
      adapter.requestCount,
      equals(1),
      reason: 'no point replaying without a new token',
    );
  });

  test('does not retry a second time if the replay is also rejected', () async {
    // Otherwise an endpoint returning 401 unconditionally would loop, and with
    // rotating refresh tokens each pass would burn one.
    final adapter = _ScriptedAdapter([_unauthorised(), _unauthorised()]);

    await expectLater(
      buildClient(adapter).stream(path: '/chat').toList(),
      throwsA(isA<ApiException>()),
    );

    expect(delegate.refreshCalls, equals(1));
    expect(adapter.requestCount, equals(2));
  });

  test('leaves a successful stream alone', () async {
    final adapter = _ScriptedAdapter([
      _eventStream('data: one\n\ndata: two\n\n'),
    ]);

    final events = await buildClient(adapter).stream(path: '/chat').toList();

    expect(delegate.refreshCalls, isZero);
    expect(events.map((event) => event.data), equals(['one', 'two']));
  });

  test('surfaces a non-auth error with the server message intact', () async {
    // The reason validateStatus is disabled in the first place: the body of a
    // failed streaming response is an unread stream, and draining it is what
    // preserves the real explanation.
    final adapter = _ScriptedAdapter([
      _ScriptedResponse(
        statusCode: 503,
        body: jsonEncode({
          'error': {'message': 'Model is warming up', 'code': 'cold_start'},
        }),
      ),
    ]);

    await expectLater(
      buildClient(adapter).stream(path: '/chat').toList(),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 503)
            .having((error) => error.message, 'message', contains('warming up'))
            .having((error) => error.errorCode, 'errorCode', 'cold_start'),
      ),
    );
    expect(delegate.refreshCalls, isZero, reason: '503 is not an auth problem');
  });
}

_ScriptedResponse _unauthorised() => _ScriptedResponse(
  statusCode: 401,
  body: jsonEncode({
    'error': {'message': 'Your session has expired.', 'code': 'token_expired'},
  }),
);

_ScriptedResponse _eventStream(String payload) =>
    _ScriptedResponse(statusCode: 200, body: payload);

class _ScriptedResponse {
  const _ScriptedResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Serves a queued response per request and counts how many were made.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._responses);

  final List<_ScriptedResponse> _responses;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final scripted = _responses[requestCount.clamp(0, _responses.length - 1)];
    requestCount++;
    return ResponseBody.fromString(
      scripted.body,
      scripted.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Records what the client asked of the auth layer.
class _RecordingDelegate implements AuthTokenDelegate {
  bool canRefresh = true;
  int refreshCalls = 0;
  int invalidateCalls = 0;

  @override
  Future<String?> currentAccessToken() async => 'stale-token';

  @override
  Future<bool> refreshSession() async {
    refreshCalls++;
    return canRefresh;
  }

  @override
  Future<void> onSessionInvalidated() async => invalidateCalls++;
}
