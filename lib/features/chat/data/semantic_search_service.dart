import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/ai/data/engines/on_device_engine.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/hashing_vectorizer.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/onnx_router_model.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/data/local/message_dao.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';

/// Offline semantic search over stored messages.
///
/// Extracted from `ChatRepositoryImpl` to break a real dependency cycle: the
/// on-device engine needs to search local history, the chat repository needs the
/// engine router to generate, and the router owns the on-device engine. Search
/// only ever needed the message DAO and the embedder, so pulling it out removes
/// the cycle *and* leaves a smaller, independently testable unit.
///
/// Scoring runs in Dart over every stored vector. A linear scan sounds wasteful
/// but a personal chat history is thousands of 64-float vectors — well under a
/// frame — and it avoids bolting a vector index onto SQLite for no measurable
/// gain.
class SemanticSearchService implements LocalKnowledgeSource {
  SemanticSearchService({
    required MessageDao messageDao,
    required OnnxRouterModel embedder,
    required AppLogger logger,
  }) : _messageDao = messageDao,
       _embedder = embedder,
       _logger = logger.scoped('chat.search');

  /// Below this cosine similarity a result is treated as unrelated.
  ///
  /// Low enough to surface loose matches in explicit search, where the user can
  /// judge relevance themselves. `OnDeviceEngine` applies a stricter threshold
  /// before quoting a message back as an answer.
  static const double _minimumScore = 0.2;

  final MessageDao _messageDao;
  final OnnxRouterModel _embedder;
  final AppLogger _logger;

  /// Ranked matches for [query].
  Future<List<MessageSearchHit>> search(String query, {int limit = 20}) async {
    final queryVector = await _embedder.embed(query);
    if (queryVector == null) return const [];

    final records = await _messageDao.findAllEmbeddings();
    if (records.isEmpty) return const [];

    final scored =
        records
            .map(
              (record) => (
                record: record,
                score: VectorMath.cosineSimilarity(queryVector, record.vector),
              ),
            )
            .where((entry) => entry.score > _minimumScore)
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));

    final hits = <MessageSearchHit>[];
    for (final entry in scored.take(limit)) {
      final message = await _messageDao.findById(entry.record.messageId);
      if (message == null) continue;
      hits.add(
        MessageSearchHit(
          message: message,
          conversationTitle: entry.record.conversationTitle,
          score: entry.score,
        ),
      );
    }
    return hits;
  }

  @override
  Future<List<LocalKnowledgeHit>> findSimilar(
    String query, {
    int limit = 5,
  }) async {
    final hits = await search(query, limit: limit);
    return hits
        .map(
          (hit) => LocalKnowledgeHit(
            text: hit.message.searchableText,
            conversationTitle: hit.conversationTitle.isEmpty
                ? 'Untitled'
                : hit.conversationTitle,
            score: hit.score,
            createdAt: hit.message.createdAt,
          ),
        )
        .toList(growable: false);
  }

  /// Embeds a completed message so it becomes searchable.
  ///
  /// Best-effort by design: a failure to index must never surface as a chat
  /// error, because the message itself was delivered fine.
  Future<void> index(String messageId, String text) async {
    try {
      if (!HashingVectorizer.hasSignal(text)) return;
      final vector = await _embedder.embed(text);
      if (vector == null) return;
      await _messageDao.saveEmbedding(
        messageId: messageId,
        modelId: KnownModels.onDeviceRouter,
        vector: vector,
      );
    } catch (error) {
      _logger.d('Embedding skipped', fields: {'error': '$error'});
    }
  }

  /// Embeds completed messages that predate the index, so search works on
  /// history created before the feature existed.
  Future<int> backfill({int limit = 100}) async {
    final ids = await _messageDao.findMessagesMissingEmbeddings(limit: limit);
    for (final id in ids) {
      final message = await _messageDao.findById(id);
      if (message == null) continue;
      await index(id, message.searchableText);
    }
    if (ids.isNotEmpty) {
      _logger.i('Backfilled embeddings', fields: {'count': ids.length});
    }
    return ids.length;
  }
}
