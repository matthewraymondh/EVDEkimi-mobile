/// The SQL schema, expressed as an ordered list of migrations.
///
/// Each entry is the set of statements that upgrades the database *to* that
/// version. `AppDatabase` replays every migration above the on-disk version, so
/// a fresh install and an upgrade take exactly the same code path — which is the
/// only way to be confident an upgrade produces the schema you designed.
///
/// Rules for adding a version:
/// 1. Never edit a shipped migration. Append a new one.
/// 2. Statements must be idempotent-safe in ordering (create table, then index).
/// 3. Store timestamps as UTC milliseconds since epoch (INTEGER) and enums as
///    their `name` string, so rows stay readable in a SQL console.
abstract final class DatabaseSchema {
  static const String databaseName = 'evdekimi_ai.db';

  /// Bump this when appending to [migrations].
  static const int version = 1;

  static const List<String> tableNames = [
    'conversations',
    'messages',
    'attachments',
    'outbox',
    'message_embeddings',
    'model_catalog',
  ];

  /// version -> statements applied to reach it.
  static const Map<int, List<String>> migrations = {1: _v1};

  static const List<String> _v1 = [
    '''
    CREATE TABLE conversations (
      id                   TEXT    PRIMARY KEY,
      remote_id            TEXT,
      title                TEXT    NOT NULL,
      model_id             TEXT    NOT NULL,
      engine               TEXT    NOT NULL,
      last_message_preview TEXT,
      message_count        INTEGER NOT NULL DEFAULT 0,
      is_pinned            INTEGER NOT NULL DEFAULT 0,
      is_archived          INTEGER NOT NULL DEFAULT 0,
      sync_state           TEXT    NOT NULL DEFAULT 'localOnly',
      created_at           INTEGER NOT NULL,
      updated_at           INTEGER NOT NULL,
      deleted_at           INTEGER
    )
    ''',
    // Drives the conversation list: newest activity first, pinned on top,
    // excluding soft-deleted rows.
    '''
    CREATE INDEX idx_conversations_activity
      ON conversations (is_archived, is_pinned DESC, updated_at DESC)
    ''',
    'CREATE INDEX idx_conversations_remote ON conversations (remote_id)',

    '''
    CREATE TABLE messages (
      id              TEXT    PRIMARY KEY,
      conversation_id TEXT    NOT NULL,
      remote_id       TEXT,
      role            TEXT    NOT NULL,
      content         TEXT    NOT NULL DEFAULT '',
      status          TEXT    NOT NULL,
      sequence        INTEGER NOT NULL,
      model_id        TEXT,
      engine          TEXT,
      token_count     INTEGER,
      latency_ms      INTEGER,
      error_code      TEXT,
      error_message   TEXT,
      reply_to_id     TEXT,
      metadata        TEXT,
      created_at      INTEGER NOT NULL,
      updated_at      INTEGER NOT NULL,
      FOREIGN KEY (conversation_id) REFERENCES conversations (id)
        ON DELETE CASCADE
    )
    ''',
    // `sequence` rather than `created_at` is the sort key: two messages created
    // in the same millisecond must still have a stable, total order.
    '''
    CREATE UNIQUE INDEX idx_messages_sequence
      ON messages (conversation_id, sequence)
    ''',
    'CREATE INDEX idx_messages_status ON messages (status)',

    '''
    CREATE TABLE attachments (
      id           TEXT    PRIMARY KEY,
      message_id   TEXT    NOT NULL,
      kind         TEXT    NOT NULL,
      local_path   TEXT,
      remote_url   TEXT,
      mime_type    TEXT,
      size_bytes   INTEGER,
      width        INTEGER,
      height       INTEGER,
      extracted_text TEXT,
      upload_state TEXT    NOT NULL DEFAULT 'pending',
      created_at   INTEGER NOT NULL,
      FOREIGN KEY (message_id) REFERENCES messages (id) ON DELETE CASCADE
    )
    ''',
    'CREATE INDEX idx_attachments_message ON attachments (message_id)',

    // The outbox is what makes offline sending durable. One row per message
    // awaiting delivery; `id` equals the message id so enqueueing twice is a
    // no-op instead of a duplicate send.
    '''
    CREATE TABLE outbox (
      id              TEXT    PRIMARY KEY,
      conversation_id TEXT    NOT NULL,
      idempotency_key TEXT    NOT NULL,
      payload         TEXT    NOT NULL,
      attempts        INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL,
      last_error      TEXT,
      created_at      INTEGER NOT NULL,
      FOREIGN KEY (id) REFERENCES messages (id) ON DELETE CASCADE
    )
    ''',
    'CREATE INDEX idx_outbox_due ON outbox (next_attempt_at)',

    // Vectors produced by the on-device ONNX model, stored as raw
    // little-endian float32 bytes. Cosine similarity is computed in Dart:
    // conversation history is small enough that a linear scan is faster than
    // maintaining an index, and it keeps the schema portable.
    '''
    CREATE TABLE message_embeddings (
      message_id TEXT    PRIMARY KEY,
      model_id   TEXT    NOT NULL,
      dimensions INTEGER NOT NULL,
      vector     BLOB    NOT NULL,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (message_id) REFERENCES messages (id) ON DELETE CASCADE
    )
    ''',

    // Cached copy of GET /models so the model picker works offline.
    '''
    CREATE TABLE model_catalog (
      id                 TEXT    PRIMARY KEY,
      name               TEXT    NOT NULL,
      provider           TEXT    NOT NULL,
      engine             TEXT    NOT NULL,
      context_window     INTEGER NOT NULL DEFAULT 0,
      supports_streaming INTEGER NOT NULL DEFAULT 1,
      supports_vision    INTEGER NOT NULL DEFAULT 0,
      is_default         INTEGER NOT NULL DEFAULT 0,
      description        TEXT,
      updated_at         INTEGER NOT NULL
    )
    ''',
  ];
}

/// Column name constants, so a typo is a compile error rather than a
/// silent empty result at runtime.
abstract final class ConversationColumns {
  static const String table = 'conversations';
  static const String id = 'id';
  static const String remoteId = 'remote_id';
  static const String title = 'title';
  static const String modelId = 'model_id';
  static const String engine = 'engine';
  static const String lastMessagePreview = 'last_message_preview';
  static const String messageCount = 'message_count';
  static const String isPinned = 'is_pinned';
  static const String isArchived = 'is_archived';
  static const String syncState = 'sync_state';
  static const String createdAt = 'created_at';
  static const String updatedAt = 'updated_at';
  static const String deletedAt = 'deleted_at';
}

abstract final class MessageColumns {
  static const String table = 'messages';
  static const String id = 'id';
  static const String conversationId = 'conversation_id';
  static const String remoteId = 'remote_id';
  static const String role = 'role';
  static const String content = 'content';
  static const String status = 'status';
  static const String sequence = 'sequence';
  static const String modelId = 'model_id';
  static const String engine = 'engine';
  static const String tokenCount = 'token_count';
  static const String latencyMs = 'latency_ms';
  static const String errorCode = 'error_code';
  static const String errorMessage = 'error_message';
  static const String replyToId = 'reply_to_id';
  static const String metadata = 'metadata';
  static const String createdAt = 'created_at';
  static const String updatedAt = 'updated_at';
}

abstract final class AttachmentColumns {
  static const String table = 'attachments';
  static const String id = 'id';
  static const String messageId = 'message_id';
  static const String kind = 'kind';
  static const String localPath = 'local_path';
  static const String remoteUrl = 'remote_url';
  static const String mimeType = 'mime_type';
  static const String sizeBytes = 'size_bytes';
  static const String width = 'width';
  static const String height = 'height';
  static const String extractedText = 'extracted_text';
  static const String uploadState = 'upload_state';
  static const String createdAt = 'created_at';
}

abstract final class OutboxColumns {
  static const String table = 'outbox';
  static const String id = 'id';
  static const String conversationId = 'conversation_id';
  static const String idempotencyKey = 'idempotency_key';
  static const String payload = 'payload';
  static const String attempts = 'attempts';
  static const String nextAttemptAt = 'next_attempt_at';
  static const String lastError = 'last_error';
  static const String createdAt = 'created_at';
}

abstract final class EmbeddingColumns {
  static const String table = 'message_embeddings';
  static const String messageId = 'message_id';
  static const String modelId = 'model_id';
  static const String dimensions = 'dimensions';
  static const String vector = 'vector';
  static const String createdAt = 'created_at';
}

abstract final class ModelCatalogColumns {
  static const String table = 'model_catalog';
  static const String id = 'id';
  static const String name = 'name';
  static const String provider = 'provider';
  static const String engine = 'engine';
  static const String contextWindow = 'context_window';
  static const String supportsStreaming = 'supports_streaming';
  static const String supportsVision = 'supports_vision';
  static const String isDefault = 'is_default';
  static const String description = 'description';
  static const String updatedAt = 'updated_at';
}
