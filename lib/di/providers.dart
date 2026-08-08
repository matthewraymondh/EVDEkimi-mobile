/// Composition root.
///
/// Every dependency is declared here and nowhere else. No service locator, no
/// singletons reached through globals — a widget or controller asks for what it
/// needs and Riverpod supplies it, which is also what makes every one of them
/// overridable in a test with one line.
///
/// Providers that need `await` during startup ([appConfigProvider],
/// [keyValueStoreProvider], [connectivityServiceProvider], [loggerProvider]) throw
/// until overridden. `bootstrap()` constructs them and installs the overrides, so
/// a missing override fails immediately and loudly instead of silently handing
/// out a half-initialised object.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/config/app_config.dart';
import 'package:evdekimi_ai/core/connectivity/connectivity_service.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/logging/log_sink.dart';
import 'package:evdekimi_ai/core/network/api_client.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/network/dio_factory.dart';
import 'package:evdekimi_ai/core/network/sse/sse_client.dart';
import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/core/persistence/key_value_store.dart';
import 'package:evdekimi_ai/core/persistence/secure_store.dart';
import 'package:evdekimi_ai/features/ai/data/engines/engine_router.dart';
import 'package:evdekimi_ai/features/ai/data/engines/on_device_engine.dart';
import 'package:evdekimi_ai/features/ai/data/engines/remote_sse_engine.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/onnx_router_model.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/auth/data/auth_remote_data_source.dart';
import 'package:evdekimi_ai/features/auth/data/auth_repository_impl.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';
import 'package:evdekimi_ai/features/auth/domain/repositories/auth_repository.dart';
import 'package:evdekimi_ai/features/chat/data/local/conversation_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/message_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/outbox_dao.dart';
import 'package:evdekimi_ai/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:evdekimi_ai/features/chat/data/repositories/conversation_repository_impl.dart';
import 'package:evdekimi_ai/features/chat/data/semantic_search_service.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';
import 'package:evdekimi_ai/features/input/attachment_service.dart';
import 'package:evdekimi_ai/features/input/speech_input_service.dart';
import 'package:evdekimi_ai/features/settings/domain/app_settings.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------- bootstrap

const String _mustOverride =
    'This provider must be overridden in ProviderScope by bootstrap().';

final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError(_mustOverride),
);

/// In-memory log buffer backing the in-app diagnostics screen.
final logBufferProvider = Provider<RingBufferLogSink>(
  (ref) => throw UnimplementedError(_mustOverride),
);

final loggerProvider = Provider<AppLogger>(
  (ref) => throw UnimplementedError(_mustOverride),
);

final keyValueStoreProvider = Provider<KeyValueStore>(
  (ref) => throw UnimplementedError(_mustOverride),
);

final connectivityServiceProvider = Provider<ConnectivityService>(
  (ref) => throw UnimplementedError(_mustOverride),
);

// ---------------------------------------------------------------- core

final secureStoreProvider = Provider<SecureStore>(
  (ref) => FlutterSecureStore(),
);

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase(logger: ref.watch(loggerProvider));
  ref.onDispose(database.close);
  return database;
});

/// Indirection that lets the HTTP client be built before the auth repository.
final authTokenDelegateProvider = Provider<DeferredAuthTokenDelegate>(
  (ref) => DeferredAuthTokenDelegate(),
);

final dioProvider = Provider<Dio>((ref) {
  final dio = DioFactory.create(
    config: ref.watch(appConfigProvider),
    logger: ref.watch(loggerProvider),
    authDelegate: ref.watch(authTokenDelegateProvider),
  );
  ref.onDispose(dio.close);
  return dio;
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(appConfigProvider);
  return ApiClient(
    dio: ref.watch(dioProvider),
    sseClient: SseClient(
      dio: ref.watch(dioProvider),
      logger: ref.watch(loggerProvider),
      idleTimeout: config.streamIdleTimeout,
    ),
  );
});

// ---------------------------------------------------------------- auth

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final repository = AuthRepositoryImpl(
    remote: AuthRemoteDataSource(ref.watch(apiClientProvider)),
    secureStore: ref.watch(secureStoreProvider),
    logger: ref.watch(loggerProvider),
    // Signing out must not leave another user's conversations on the device.
    onSignedOut: () => ref.read(appDatabaseProvider).wipe(),
  );

  // Close the construction cycle: the HTTP layer can now authenticate.
  final delegate = ref.watch(authTokenDelegateProvider);
  if (!delegate.isBound) delegate.bind(repository);

  ref.onDispose(repository.dispose);
  return repository;
});

/// The live session, or `null` when signed out. Drives the router's guard.
final authSessionProvider = StreamProvider<AuthSession?>(
  (ref) => ref.watch(authRepositoryProvider).sessionChanges,
);

final currentUserProvider = Provider<User?>(
  (ref) => ref.watch(authSessionProvider).value?.user,
);

// ---------------------------------------------------------------- ai

final onnxRouterModelProvider = Provider<OnnxRouterModel>((ref) {
  final model = OnnxRouterModel(logger: ref.watch(loggerProvider));
  ref.onDispose(model.dispose);
  return model;
});

final remoteEngineProvider = Provider<RemoteSseEngine>(
  (ref) => RemoteSseEngine(
    apiClient: ref.watch(apiClientProvider),
    logger: ref.watch(loggerProvider),
    connectivity: ref.watch(connectivityServiceProvider),
  ),
);

/// Offline semantic search, and the on-device engine's knowledge source.
///
/// Separate from the chat repository on purpose: depending on the repository here
/// would create the cycle
/// `onDeviceEngine → chatRepository → engineRouter → onDeviceEngine`.
final semanticSearchProvider = Provider<SemanticSearchService>(
  (ref) => SemanticSearchService(
    messageDao: ref.watch(messageDaoProvider),
    embedder: ref.watch(onnxRouterModelProvider),
    logger: ref.watch(loggerProvider),
  ),
);

final onDeviceEngineProvider = Provider<OnDeviceEngine>(
  (ref) => OnDeviceEngine(
    model: ref.watch(onnxRouterModelProvider),
    // Only the narrow LocalKnowledgeSource port crosses into the AI layer.
    knowledge: ref.watch(semanticSearchProvider),
    logger: ref.watch(loggerProvider),
  ),
);

final engineRouterProvider = Provider<EngineRouter>(
  (ref) => EngineRouter(
    remoteEngine: ref.watch(remoteEngineProvider),
    onDeviceEngine: ref.watch(onDeviceEngineProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    logger: ref.watch(loggerProvider),
    // `ref.read` inside a callback, not `ref.watch`: watching would rebuild the
    // router (and with it the chat repository) whenever the user changes their
    // default model, tearing down any generation in flight.
    fallbackRemoteModelId: () {
      final selected = ref.read(settingsControllerProvider).selectedModelId;
      return selected == KnownModels.onDeviceRouter
          ? AppConfig.defaultRemoteModelId
          : selected;
    },
  ),
);

/// Whether the bundled on-device model can actually run here.
final onDeviceAvailableProvider = FutureProvider<bool>(
  (ref) => ref.watch(onnxRouterModelProvider).isAvailable(),
);

// ---------------------------------------------------------------- chat data

final conversationDaoProvider = Provider<ConversationDao>(
  (ref) => ConversationDao(ref.watch(appDatabaseProvider)),
);

final messageDaoProvider = Provider<MessageDao>(
  (ref) => MessageDao(ref.watch(appDatabaseProvider)),
);

final outboxDaoProvider = Provider<OutboxDao>(
  (ref) => OutboxDao(ref.watch(appDatabaseProvider)),
);

final conversationRepositoryProvider = Provider<ConversationRepository>(
  (ref) => ConversationRepositoryImpl(
    database: ref.watch(appDatabaseProvider),
    dao: ref.watch(conversationDaoProvider),
    logger: ref.watch(loggerProvider),
  ),
);

/// Concrete type on purpose: `bootstrap()` needs the recovery and backfill
/// entry points, which are lifecycle concerns rather than part of the port.
final chatRepositoryProvider = Provider<ChatRepositoryImpl>((ref) {
  final repository = ChatRepositoryImpl(
    database: ref.watch(appDatabaseProvider),
    conversationDao: ref.watch(conversationDaoProvider),
    messageDao: ref.watch(messageDaoProvider),
    outboxDao: ref.watch(outboxDaoProvider),
    engineRouter: ref.watch(engineRouterProvider),
    embedder: ref.watch(onnxRouterModelProvider),
    search: ref.watch(semanticSearchProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    apiClient: ref.watch(apiClientProvider),
    config: ref.watch(appConfigProvider),
    logger: ref.watch(loggerProvider),
    readSettings: () => ref.read(settingsControllerProvider),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

// ---------------------------------------------------------------- streams

final networkStatusProvider = StreamProvider<NetworkStatus>(
  (ref) => ref.watch(connectivityServiceProvider).onStatusChanged,
);

final isOnlineProvider = Provider<bool>(
  (ref) =>
      ref.watch(networkStatusProvider).value?.isOnline ??
      ref.watch(connectivityServiceProvider).status.isOnline,
);

final conversationsProvider = StreamProvider<List<Conversation>>(
  (ref) => ref.watch(conversationRepositoryProvider).watchConversations(),
);

/// Messages of one conversation. Auto-disposes: leaving a thread should release
/// its database subscription rather than keep re-querying in the background.
final messagesProvider = StreamProvider.family<List<Message>, String>(
  (ref, conversationId) =>
      ref.watch(chatRepositoryProvider).watchMessages(conversationId),
  isAutoDispose: true,
);

final conversationProvider = StreamProvider.family<Conversation?, String>(
  (ref, conversationId) => ref
      .watch(conversationRepositoryProvider)
      .watchConversation(conversationId),
  isAutoDispose: true,
);

final pendingMessageCountProvider = StreamProvider<int>(
  (ref) => ref.watch(chatRepositoryProvider).watchPendingCount(),
);

/// Available models: the cached remote catalog plus the bundled on-device one.
///
/// Refreshed from the network when possible, but always answers from cache, so
/// the model picker works offline.
final availableModelsProvider = FutureProvider<List<ModelDescriptor>>((
  ref,
) async {
  final dao = ref.watch(conversationDaoProvider);
  final isOnline = ref.watch(isOnlineProvider);

  if (isOnline) {
    try {
      final response = await ref
          .watch(apiClientProvider)
          .getJsonList(ApiRoutes.models);
      final models = response
          .whereType<Map<String, dynamic>>()
          .map(ModelDescriptor.fromJson)
          .where((model) => model.engine == EngineKind.remote)
          .toList(growable: false);
      if (models.isNotEmpty) await dao.replaceModels(models);
    } catch (error) {
      // Stale catalog beats an error screen in a model picker.
      ref
          .read(loggerProvider)
          .d(
            'Model catalog refresh failed; using cache',
            fields: {'error': '$error'},
          );
    }
  }

  final cached = await dao.findModels();
  final onDeviceInstalled = await ref.watch(onDeviceAvailableProvider.future);

  return [...cached, if (onDeviceInstalled) KnownModels.onDevice];
});

// ---------------------------------------------------------------- input

final speechInputServiceProvider = Provider<SpeechInputService>((ref) {
  final service = SpeechInputService(logger: ref.watch(loggerProvider));
  ref.onDispose(service.dispose);
  return service;
});

final speechStateProvider = StreamProvider<SpeechState>(
  (ref) => ref.watch(speechInputServiceProvider).onStateChanged,
);

final attachmentServiceProvider = Provider<AttachmentService>((ref) {
  final service = AttachmentService(logger: ref.watch(loggerProvider));
  ref.onDispose(service.dispose);
  return service;
});

// ---------------------------------------------------------------- settings

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(keyValueStoreProvider)),
);

/// App settings, loaded synchronously so the first frame paints in the right
/// theme instead of flashing light before dark is applied.
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsRepositoryProvider).load();

  Future<void> _update(AppSettings next) async {
    state = next;
    await ref.read(settingsRepositoryProvider).save(next);
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _update(state.copyWith(themeMode: mode));

  Future<void> setModel(ModelDescriptor model) => _update(
    state.copyWith(selectedModelId: model.id, preferredEngine: model.engine),
  );

  Future<void> setUseOnDeviceWhenOffline({required bool value}) =>
      _update(state.copyWith(useOnDeviceWhenOffline: value));

  Future<void> setHaptics({required bool value}) =>
      _update(state.copyWith(hapticsEnabled: value));

  Future<void> setSendOnEnter({required bool value}) =>
      _update(state.copyWith(sendOnEnter: value));

  Future<void> setLiquidGlass({required bool value}) =>
      _update(state.copyWith(liquidGlass: value));
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

// ---------------------------------------------------------------- lifecycle

/// Flushes the outbox on reconnect and on a timer.
///
/// Kept as a provider rather than living in a widget so delivery does not depend
/// on any particular screen being mounted — a queued message must go out even if
/// the user is sitting on Settings.
class OutboxCoordinator {
  OutboxCoordinator({
    required ChatRepository repository,
    required ConnectivityService connectivity,
    required AppConfig config,
    required AppLogger logger,
  }) : _repository = repository,
       _connectivity = connectivity,
       _config = config,
       _logger = logger.scoped('chat.outbox');

  final ChatRepository _repository;
  final ConnectivityService _connectivity;
  final AppConfig _config;
  final AppLogger _logger;

  StreamSubscription<NetworkStatus>? _subscription;
  Timer? _timer;

  void start() {
    _subscription = _connectivity.onStatusChanged.listen((status) {
      if (status.isOnline) {
        _logger.i('Back online; flushing outbox');
        unawaited(_repository.flushOutbox());
      }
    });

    // A periodic sweep covers the captive-portal case, where the interface
    // reports online but requests were failing until now.
    _timer = Timer.periodic(_config.outboxFlushInterval, (_) {
      if (_connectivity.status.isOnline) {
        unawaited(_repository.flushOutbox());
      }
    });
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription?.cancel();
  }
}

final outboxCoordinatorProvider = Provider<OutboxCoordinator>((ref) {
  final coordinator = OutboxCoordinator(
    repository: ref.watch(chatRepositoryProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    config: ref.watch(appConfigProvider),
    logger: ref.watch(loggerProvider),
  );
  coordinator.start();
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
