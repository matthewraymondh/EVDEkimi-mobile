import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/connectivity/connectivity_service.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/api_client.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/network/sse/sse_client.dart';
import 'package:evdekimi_ai/features/ai/data/engines/remote_sse_engine.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where OCR text goes, and where it must not.
///
/// The two engines need it in opposite forms, which is the whole reason it is a
/// separate field. A chat completions API only accepts message content, so the
/// cloud engine has to fold it inline. The local engine is a seven-way intent
/// classifier, so folding it in there means classifying the contents of a
/// photograph instead of the question about it — which is exactly what shipped
/// before this: a picture of a keyboard and the words "read this" came back as
/// an answer about Indonesian property law.
void main() {
  group('Message.toPromptTurn', () {
    test('carries what the user typed, and not the image text', () {
      final message = _message(
        content: 'Read this',
        extracted: 'Villa Melati — Berawa. Leasehold to 2049.',
      );

      expect(message.toPromptTurn().content, equals('Read this'));
      expect(
        message.toPromptTurn().content,
        isNot(contains('Villa Melati')),
        reason: 'folding it in here is what mis-classified the prompt',
      );
    });

    test('still exposes both together for embedding and search', () {
      // The search index does want them concatenated: a photographed listing
      // should be findable by the words in the photograph.
      final message = _message(
        content: 'Read this',
        extracted: 'Villa Melati — Berawa',
      );

      expect(message.searchableText, contains('Read this'));
      expect(message.searchableText, contains('Villa Melati'));
    });

    test('offers the image text on its own', () {
      final message = _message(content: '', extracted: '  Villa Melati  ');
      expect(message.recognisedText, equals(['Villa Melati']));
    });

    test('reports nothing when an image produced no text', () {
      expect(
        _message(content: 'Look', extracted: null).recognisedText,
        isEmpty,
      );
      expect(
        _message(content: 'Look', extracted: '   ').recognisedText,
        isEmpty,
      );
    });
  });

  group('RemoteSseEngine', () {
    test('folds the image text into the last user turn, labelled', () async {
      final adapter = _CapturingAdapter();
      final engine = _engineWith(adapter);

      await engine
          .generate(
            const InferenceRequest(
              modelId: 'mock-gpt',
              turns: [
                PromptTurn.user('Older question'),
                PromptTurn.assistant('Older answer'),
                PromptTurn.user('Read this'),
              ],
              recognisedText: ['Villa Melati — Berawa'],
            ),
          )
          .toList();

      final messages = adapter.body!['messages'] as List<dynamic>;
      final lastUser = messages.lastWhere((m) => (m as Map)['role'] == 'user');
      final content = (lastUser as Map)['content'] as String;

      expect(content, startsWith('Read this'));
      expect(content, contains('Villa Melati — Berawa'));
      expect(
        content,
        contains('read from the attached image'),
        reason:
            'unlabelled text after a short question gets answered instead of '
            'treated as evidence about it',
      );

      // Only the newest turn. Re-attaching every photograph the user ever sent
      // would eat the context window for nothing.
      final earlier = messages.firstWhere((m) => (m as Map)['role'] == 'user');
      expect((earlier as Map)['content'], equals('Older question'));
    });

    test('leaves the prompt untouched when there is no image text', () async {
      final adapter = _CapturingAdapter();
      final engine = _engineWith(adapter);

      await engine
          .generate(
            const InferenceRequest(
              modelId: 'mock-gpt',
              turns: [PromptTurn.user('Villas in Canggu')],
            ),
          )
          .toList();

      final messages = adapter.body!['messages'] as List<dynamic>;
      expect((messages.single as Map)['content'], equals('Villas in Canggu'));
    });
  });
}

Message _message({required String content, required String? extracted}) =>
    Message(
      id: 'm1',
      conversationId: 'c1',
      role: MessageRole.user,
      content: content,
      status: MessageStatus.complete,
      sequence: 0,
      attachments: [
        Attachment(
          id: 'a1',
          messageId: 'm1',
          kind: AttachmentKind.image,
          localPath: '/tmp/a.jpg',
          extractedText: extracted,
          createdAt: DateTime.utc(2026, 8, 8),
        ),
      ],
      createdAt: DateTime.utc(2026, 8, 8),
      updatedAt: DateTime.utc(2026, 8, 8),
    );

RemoteSseEngine _engineWith(_CapturingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
    ..httpClientAdapter = adapter;
  return RemoteSseEngine(
    apiClient: ApiClient(
      dio: dio,
      sseClient: SseClient(
        dio: dio,
        logger: AppLogger.silent(),
        authDelegate: const NoopAuthTokenDelegate(),
      ),
    ),
    logger: AppLogger.silent(),
    connectivity: _AlwaysOnline(),
  );
}

class _AlwaysOnline implements ConnectivityService {
  @override
  NetworkStatus get status => NetworkStatus.online;

  @override
  Stream<NetworkStatus> get onStatusChanged => const Stream.empty();

  @override
  Future<NetworkStatus> refresh() async => NetworkStatus.online;

  @override
  Future<void> dispose() async {}
}

/// Records the request body and returns a minimal well-formed stream.
class _CapturingAdapter implements HttpClientAdapter {
  Map<String, dynamic>? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    body = jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>;
    return ResponseBody.fromString(
      'data: ${jsonEncode({
        'choices': [
          {
            'delta': {'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
      })}\n\ndata: [DONE]\n\n',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
