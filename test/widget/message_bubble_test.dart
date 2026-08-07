import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:evdekimi_ai/features/chat/presentation/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Widget tests for the transcript.
///
/// These assert the behaviour that is easy to regress silently: which bubble
/// shows a typing indicator, whether Markdown is rendered for the assistant but
/// not the user, and that both themes actually resolve (a missing `ChatTheme`
/// extension would throw on a null assertion at paint time).
void main() {
  Message message({
    required MessageRole role,
    String content = '',
    MessageStatus status = MessageStatus.complete,
    EngineKind? engine,
    Duration? latency,
    String? errorMessage,
    List<Attachment> attachments = const [],
  }) => Message(
    id: 'm1',
    conversationId: 'c1',
    role: role,
    content: content,
    status: status,
    sequence: 0,
    engine: engine,
    latency: latency,
    errorMessage: errorMessage,
    attachments: attachments,
    createdAt: DateTime.utc(2026, 8, 7),
    updatedAt: DateTime.utc(2026, 8, 7),
  );

  Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  group('MessageBubble', () {
    testWidgets('renders user text as plain selectable text', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.user,
              content: 'Use **stars** literally',
            ),
          ),
        ),
      );

      expect(find.text('Use **stars** literally'), findsOneWidget);
      // A user's own asterisks must not be reinterpreted as formatting.
      expect(find.byType(GptMarkdown), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('renders assistant text as Markdown', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.assistant,
              content: 'Here is **bold** text',
            ),
          ),
        ),
      );

      expect(find.byType(GptMarkdown), findsOneWidget);
    });

    testWidgets('shows a typing indicator before the first token', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.assistant,
              status: MessageStatus.sending,
            ),
          ),
        ),
      );

      expect(find.byType(TypingIndicator), findsOneWidget);
    });

    testWidgets('replaces the indicator once content arrives', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.assistant,
              content: 'Hel',
              status: MessageStatus.streaming,
            ),
          ),
        ),
      );

      expect(find.byType(TypingIndicator), findsNothing);
      // The caret is what signals "still generating" once text exists.
      expect(find.byType(StreamingCaret), findsOneWidget);
    });

    testWidgets('shows the engine badge and latency when complete', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.assistant,
              content: 'Answer',
              engine: EngineKind.onDevice,
              latency: const Duration(milliseconds: 1500),
            ),
            onRegenerate: () {},
          ),
        ),
      );

      // The user should be able to tell a local answer from a cloud one.
      expect(find.text('On-device'), findsOneWidget);
      expect(find.text('1.5s'), findsOneWidget);
    });

    testWidgets('offers retry only for a failed message', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.user,
              content: 'Send me',
              status: MessageStatus.failed,
              errorMessage: 'Could not reach the server.',
            ),
            onRetry: () => retried = true,
          ),
        ),
      );

      expect(find.text('Could not reach the server.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });

    testWidgets('marks a queued message so nothing looks lost', (tester) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.user,
              content: 'Offline message',
              status: MessageStatus.queued,
            ),
          ),
        ),
      );

      expect(find.text('Queued'), findsOneWidget);
    });

    testWidgets('surfaces on-device OCR text for an attachment', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.user,
              content: 'What does this say?',
              attachments: [
                Attachment(
                  id: 'a1',
                  messageId: 'm1',
                  kind: AttachmentKind.image,
                  createdAt: DateTime.utc(2026, 8, 7),
                  extractedText: 'TOTAL 42.00',
                ),
              ],
            ),
          ),
        ),
      );

      // Showing that text was read locally is what makes the feature legible.
      expect(find.textContaining('Text recognised on-device'), findsOneWidget);
    });

    testWidgets('renders in dark mode without a missing-theme crash', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          MessageBubble(
            message: message(
              role: MessageRole.assistant,
              content: 'Dark mode answer',
              engine: EngineKind.remote,
            ),
            onRegenerate: () {},
          ),
          brightness: Brightness.dark,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Cloud'), findsOneWidget);
    });
  });

  group('OfflineBanner', () {
    testWidgets('is hidden when online', (tester) async {
      await tester.pumpWidget(host(const OfflineBanner(isVisible: false)));
      expect(find.textContaining('Offline'), findsNothing);
    });

    testWidgets('reports the queued count when offline', (tester) async {
      await tester.pumpWidget(
        host(const OfflineBanner(isVisible: true, pendingCount: 3)),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('3 messages will send automatically'),
        findsOneWidget,
      );
    });

    testWidgets('uses the singular form for one queued message', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const OfflineBanner(isVisible: true, pendingCount: 1)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('1 message will'), findsOneWidget);
    });
  });

  group('FailureView', () {
    testWidgets('offers retry for a retryable failure only', (tester) async {
      await tester.pumpWidget(
        host(const FailureView(failure: NetworkFailure(message: 'offline'))),
      );
      // Retryability is a domain property, so the affordance appears without the
      // screen deciding anything.
      expect(find.text('Try again'), findsNothing, reason: 'no callback given');

      await tester.pumpWidget(
        host(
          FailureView(
            failure: const NetworkFailure(message: 'offline'),
            onRetry: () {},
          ),
        ),
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('hides retry for a non-retryable failure', (tester) async {
      await tester.pumpWidget(
        host(
          FailureView(
            failure: const AuthFailure(
              message: 'bad password',
              reason: AuthFailureReason.invalidCredentials,
            ),
            onRetry: () {},
          ),
        ),
      );

      expect(find.text('Incorrect email or password.'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });
}
