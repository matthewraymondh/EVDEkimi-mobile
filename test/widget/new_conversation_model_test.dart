import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';
import 'package:evdekimi_ai/features/chat/presentation/conversation_list_screen.dart';
import 'package:evdekimi_ai/features/settings/domain/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which model a brand-new conversation is created with.
///
/// The distinction this pins down is between a *preference* and a *condition*.
/// A conversation's model is what it is for; which engine answers any given
/// message is a question about what is reachable at that moment, and
/// `EngineRouter` settles that per message.
///
/// Conflating them shipped a real defect. Starting a chat in airplane mode
/// wrote the on-device model onto the row, and the row outlived the outage — so
/// after reconnecting the conversation was still pinned to the local engine.
/// Asking it to book a viewing refused forever: every retry routed back to the
/// engine that had just said no, and because the row looked like a deliberate
/// model choice, nothing upstream could tell it was an accident of timing.
void main() {
  late _RecordingConversationRepository repository;

  Widget host({required bool isOnline, required EngineKind preferred}) =>
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(
            (ref) => Stream.value(const <Conversation>[]),
          ),
          pendingMessageCountProvider.overrideWith((ref) => Stream.value(0)),
          isOnlineProvider.overrideWithValue(isOnline),
          onDeviceAvailableProvider.overrideWith((ref) async => true),
          conversationRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWith(
            () => _FixedSettings(AppSettings(preferredEngine: preferred)),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ConversationListScreen(),
        ),
      );

  setUp(() => repository = _RecordingConversationRepository());

  Future<void> tapNewChat(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.text('New chat'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('offline alone does not pin the conversation to the local model', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(isOnline: false, preferred: EngineKind.remote),
    );
    await tapNewChat(tester);

    expect(
      repository.requestedEngine,
      equals(EngineKind.remote),
      reason:
          'being offline is a condition, not a choice — the router falls back '
          'per message and queues what it cannot answer',
    );
    expect(
      repository.requestedModelId,
      isNot(equals(KnownModels.onDeviceRouter)),
    );
  });

  testWidgets('a standing preference for on-device is honoured', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(isOnline: true, preferred: EngineKind.onDevice),
    );
    await tapNewChat(tester);

    expect(repository.requestedEngine, equals(EngineKind.onDevice));
    expect(
      repository.requestedModelId,
      equals(KnownModels.onDeviceRouter),
      reason: 'this one really is the user asking for the local model',
    );
  });

  testWidgets('online with no preference uses the selected cloud model', (
    tester,
  ) async {
    await tester.pumpWidget(host(isOnline: true, preferred: EngineKind.remote));
    await tapNewChat(tester);

    expect(repository.requestedEngine, equals(EngineKind.remote));
    expect(
      repository.requestedModelId,
      equals(const AppSettings().selectedModelId),
    );
  });
}

/// Settings fixed for the duration of a test.
class _FixedSettings extends SettingsController {
  _FixedSettings(this._settings);

  final AppSettings _settings;

  @override
  AppSettings build() => _settings;
}

/// Records the creation request and then declines it.
///
/// Declining keeps the test off the navigation path — a successful create
/// pushes a route, which would need a router in the tree and prove nothing
/// about the arguments this file is here to check.
class _RecordingConversationRepository implements ConversationRepository {
  String? requestedModelId;
  EngineKind? requestedEngine;

  @override
  Future<Result<Conversation>> createConversation({
    required String modelId,
    required EngineKind engine,
    String? title,
  }) async {
    requestedModelId = modelId;
    requestedEngine = engine;
    return const Err(UnknownFailure(message: 'declined by the test'));
  }

  @override
  Stream<List<Conversation>> watchConversations({
    bool includeArchived = false,
  }) => Stream.value(const []);

  @override
  Stream<Conversation?> watchConversation(String conversationId) =>
      Stream.value(null);

  @override
  Future<Result<void>> renameConversation(String id, String title) async =>
      const Ok(null);

  @override
  Future<Result<void>> setPinned(String id, {required bool isPinned}) async =>
      const Ok(null);

  @override
  Future<Result<void>> setArchived(
    String id, {
    required bool isArchived,
  }) async => const Ok(null);

  @override
  Future<Result<void>> deleteConversation(String id) async => const Ok(null);

  @override
  Future<Result<void>> setModel(String id, ModelDescriptor model) async =>
      const Ok(null);
}
