import 'package:evdekimi_ai/core/error/error_mapper.dart';
import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure domain logic: no database, no network, no widgets.
void main() {
  group('ConversationTitle.fromFirstMessage', () {
    test('uses the first sentence', () {
      expect(
        ConversationTitle.fromFirstMessage(
          'How does streaming work? I want details.',
        ),
        equals('How does streaming work'),
      );
    });

    test('strips leading politeness so the subject leads', () {
      expect(
        ConversationTitle.fromFirstMessage('Can you explain SSE to me'),
        equals('Explain SSE to me'),
      );
      expect(
        ConversationTitle.fromFirstMessage('please write a test'),
        equals('Write a test'),
      );
    });

    test('collapses whitespace', () {
      expect(
        ConversationTitle.fromFirstMessage('too    many\n\nspaces'),
        equals('Too many spaces'),
      );
    });

    test('truncates on a word boundary, not mid-word', () {
      final title = ConversationTitle.fromFirstMessage(
        'Explain the architectural tradeoffs between on-device inference and '
        'hosted inference for mobile applications',
      );
      expect(title.length, lessThanOrEqualTo(ConversationTitle.maxLength + 1));
      expect(title, endsWith('…'));
      // A boundary cut means no partial word before the ellipsis.
      expect(title, isNot(contains('applicat…')));
    });

    test('falls back to the placeholder for empty input', () {
      expect(
        ConversationTitle.fromFirstMessage('   '),
        equals(Conversation.untitledTitle),
      );
      expect(
        ConversationTitle.fromFirstMessage('!!!'),
        equals('!!!'),
        reason: 'punctuation-only still yields something rather than crashing',
      );
    });
  });

  group('MessageStatus', () {
    test('classifies in-flight versus terminal states', () {
      expect(MessageStatus.queued.isInFlight, isTrue);
      expect(MessageStatus.sending.isInFlight, isTrue);
      expect(MessageStatus.streaming.isInFlight, isTrue);
      expect(MessageStatus.complete.isInFlight, isFalse);
      expect(MessageStatus.failed.isTerminal, isTrue);
      expect(MessageStatus.cancelled.isTerminal, isTrue);
    });

    test('offers retry only for failures', () {
      expect(MessageStatus.failed.canRetry, isTrue);
      expect(MessageStatus.cancelled.canRetry, isFalse);
      expect(MessageStatus.complete.canRetry, isFalse);
    });

    test('survives an unknown persisted name', () {
      // Forward compatibility: a row written by a newer build must not crash an
      // older one.
      expect(MessageStatus.fromName('teleported'), MessageStatus.complete);
      expect(MessageRole.fromName('nonsense'), MessageRole.assistant);
    });
  });

  group('Message', () {
    Message build({
      String content = '',
      MessageStatus status = MessageStatus.sending,
      MessageRole role = MessageRole.assistant,
      List<Attachment> attachments = const [],
    }) => Message(
      id: 'm',
      conversationId: 'c',
      role: role,
      content: content,
      status: status,
      sequence: 0,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      attachments: attachments,
    );

    test('awaits the first token only while empty and sending', () {
      expect(build().isAwaitingFirstToken, isTrue);
      expect(build(content: 'hi').isAwaitingFirstToken, isFalse);
      expect(
        build(status: MessageStatus.complete).isAwaitingFirstToken,
        isFalse,
      );
      expect(
        build(role: MessageRole.user).isAwaitingFirstToken,
        isFalse,
        reason: 'only assistant bubbles show a typing indicator',
      );
    });

    test('appendDelta accumulates content and flips to streaming', () {
      final message = build()
          .appendDelta('Hel', now: DateTime.utc(2026))
          .appendDelta('lo', now: DateTime.utc(2026));
      expect(message.content, equals('Hello'));
      expect(message.status, equals(MessageStatus.streaming));
    });

    test('searchableText folds in OCR text from attachments', () {
      // This is what makes a photographed receipt findable offline.
      final message = build(
        content: 'What does this say?',
        attachments: [
          Attachment(
            id: 'a',
            messageId: 'm',
            kind: AttachmentKind.image,
            createdAt: DateTime.utc(2026),
            extractedText: 'TOTAL 42.00 IDR',
          ),
        ],
      );
      expect(message.searchableText, contains('What does this say?'));
      expect(message.searchableText, contains('TOTAL 42.00 IDR'));
    });

    test('clearError wipes both error fields', () {
      final failed = build().copyWith(
        status: MessageStatus.failed,
        errorCode: 'x',
        errorMessage: 'y',
      );
      final cleared = failed.copyWith(clearError: true);
      expect(cleared.errorCode, isNull);
      expect(cleared.errorMessage, isNull);
    });

    test('maps to a prompt turn with the matching role', () {
      expect(
        build(role: MessageRole.user, content: 'hi').toPromptTurn().role,
        equals(PromptRole.user),
      );
      expect(
        build(content: 'hi').toPromptTurn().role,
        equals(PromptRole.assistant),
      );
    });
  });

  group('AuthCredentials.validate', () {
    test('accepts a well-formed pair', () {
      const credentials = AuthCredentials(
        email: 'matthew@erela.id',
        password: 'correct horse',
      );
      expect(credentials.validate(), isEmpty);
      expect(credentials.isValidForSignIn, isTrue);
    });

    test('rejects a malformed email', () {
      expect(
        const AuthCredentials(email: 'nope', password: 'password1').validate(),
        containsPair('email', isA<String>()),
      );
    });

    test('enforces the minimum password length', () {
      final errors = const AuthCredentials(
        email: 'a@b.co',
        password: 'short',
      ).validate();
      expect(errors.containsKey('password'), isTrue);
    });

    test('requires a name only when signing up', () {
      const credentials = AuthCredentials(
        email: 'a@b.co',
        password: 'password1',
      );
      expect(credentials.validate(), isEmpty);
      expect(
        credentials.validate(requireDisplayName: true),
        containsPair('name', isA<String>()),
      );
    });

    test('never exposes the password in toString', () {
      // Credentials end up in logs and error reports by accident; this is the
      // cheap guard against that.
      const credentials = AuthCredentials(
        email: 'a@b.co',
        password: 'super-secret',
      );
      expect(credentials.toString(), isNot(contains('super-secret')));
    });
  });

  group('AuthSession', () {
    test('treats a token inside the refresh skew as expired', () {
      final session = AuthSession(
        user: const User(id: 'u', email: 'a@b.co'),
        accessToken: 'a',
        refreshToken: 'r',
        // Inside the 60s skew, so it should refresh proactively rather than
        // letting a request race the boundary and take a 401.
        accessTokenExpiresAt: DateTime.now().toUtc().add(
          const Duration(seconds: 30),
        ),
      );
      expect(session.isAccessTokenExpired, isTrue);
    });

    test('treats a comfortably future token as valid', () {
      final session = AuthSession(
        user: const User(id: 'u', email: 'a@b.co'),
        accessToken: 'a',
        refreshToken: 'r',
        accessTokenExpiresAt: DateTime.now().toUtc().add(
          const Duration(hours: 1),
        ),
      );
      expect(session.isAccessTokenExpired, isFalse);
    });

    test('never exposes tokens in toString', () {
      final session = AuthSession(
        user: const User(id: 'u', email: 'a@b.co'),
        accessToken: 'super-secret-access',
        refreshToken: 'super-secret-refresh',
      );
      expect(session.toString(), isNot(contains('super-secret')));
    });
  });

  group('User', () {
    test('derives initials from a display name', () {
      expect(
        const User(
          id: 'u',
          email: 'x@y.z',
          displayName: 'Matthew Tan',
        ).initials,
        equals('MT'),
      );
    });

    test('falls back to the email local part', () {
      expect(
        const User(id: 'u', email: 'adhy_it@erela.id').initials,
        equals('AI'),
      );
      expect(
        const User(id: 'u', email: 'adhy_it@erela.id').friendlyName,
        equals('adhy_it'),
      );
    });
  });

  group('Result', () {
    test('folds both branches', () {
      const ok = Ok<int>(1);
      const err = Err<int>(CacheFailure(message: 'nope'));

      expect(ok.fold(ok: (value) => value * 2, err: (_) => -1), equals(2));
      expect(err.fold(ok: (value) => value * 2, err: (_) => -1), equals(-1));
    });

    test('map transforms success and preserves failure', () {
      expect(const Ok<int>(2).map((value) => value + 1).valueOrNull, equals(3));
      const failure = CacheFailure(message: 'nope');
      expect(
        const Err<int>(failure).map((value) => value + 1).failureOrNull,
        equals(failure),
      );
    });

    test(
      'guardAsync converts a thrown exception into a mapped failure',
      () async {
        final result = await Result.guardAsync<int>(
          () async => throw const ModelNotInstalledException('gemma'),
        );
        expect(result.isErr, isTrue);
        final failure = result.failureOrNull;
        expect(failure, isA<InferenceFailure>());
        expect(
          (failure! as InferenceFailure).reason,
          equals(InferenceFailureReason.modelNotInstalled),
        );
        expect(failure.isRetryable, isFalse);
      },
    );

    test('getOrElse supplies a fallback on failure', () {
      expect(
        const Err<int>(CacheFailure(message: 'x')).getOrElse((_) => 7),
        equals(7),
      );
    });
  });

  group('ErrorMapper', () {
    test('classifies HTTP status codes into domain failures', () {
      expect(
        ErrorMapper.map(const ApiException(message: 'bad', statusCode: 401)),
        isA<AuthFailure>(),
      );
      expect(
        ErrorMapper.map(const ApiException(message: 'bad', statusCode: 422)),
        isA<ValidationFailure>(),
      );
      expect(
        ErrorMapper.map(const ApiException(message: 'bad', statusCode: 503)),
        isA<ServerFailure>(),
      );
    });

    test('marks 5xx and 429 as retryable but 4xx as not', () {
      final serverError =
          ErrorMapper.map(const ApiException(message: 'x', statusCode: 500))
              as ServerFailure;
      final rateLimited =
          ErrorMapper.map(const ApiException(message: 'x', statusCode: 429))
              as ServerFailure;
      final notFound =
          ErrorMapper.map(const ApiException(message: 'x', statusCode: 404))
              as ServerFailure;

      expect(serverError.isRetryable, isTrue);
      expect(rateLimited.isRetryable, isTrue);
      expect(rateLimited.isRateLimited, isTrue);
      expect(notFound.isRetryable, isFalse);
    });

    test('parses the common server error envelopes', () {
      final nested = ErrorMapper.parseApiException(400, {
        'error': {'message': 'Bad model', 'code': 'invalid_model'},
      });
      expect(nested.message, equals('Bad model'));
      expect(nested.errorCode, equals('invalid_model'));

      final flat = ErrorMapper.parseApiException(400, {'message': 'Flat'});
      expect(flat.message, equals('Flat'));

      final fieldErrors = ErrorMapper.parseApiException(422, {
        'errors': {
          'email': ['is taken'],
        },
      });
      expect(fieldErrors.fieldErrors['email'], equals('is taken'));

      // A plain-text or HTML body must not blow up the mapper.
      final plain = ErrorMapper.parseApiException(500, '<html>oops</html>');
      expect(plain.message, contains('oops'));
    });

    test('passes an existing Failure through unchanged', () {
      const failure = CacheFailure(message: 'already mapped');
      expect(ErrorMapper.map(failure), same(failure));
    });
  });
}
