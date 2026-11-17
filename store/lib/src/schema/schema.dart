/// The schema: five tables plus their indexes (v1) and the three nullable
/// columns added in v2. **Describe only, never execute** — `migrations.dart`
/// runs these.
///
/// The DDL mirrors spec §5.1 verbatim. Notes on the deliberate deltas from the
/// authority document's draft are kept here (in Dart) rather than in the SQL, so
/// the statements stay free of non-ASCII characters:
///
/// * `devices.last_port` is **nullable** with a three-state meaning:
///   `NULL` = never observed, `0` = observed but the peer runs no inbound
///   server (the M2 `send` behaviour), `>0` = dialable.
/// * `conversations.device_fingerprint` is nullable and the foreign key uses
///   `ON DELETE SET NULL`, so deleting a device keeps its history.
/// * `conversations.archived_at` replaces hard deletion: `NULL` = active.
/// * `messages.event_nonce` + `updated_at`, and the unique index
///   `ux_messages_event`, back the idempotent-id design (§5.6).
/// * `transfers.next_attempt_at` + `updated_at` let M5 schedule retries.
///
/// No `STRICT` tables are used: the version of the system `winsqlite3.dll` is
/// not pinned, and `STRICT` would risk an incompatibility for no benefit here.
///
/// **v2 (docs/22 §2.2) is three `ALTER TABLE ... ADD COLUMN` statements and
/// nothing else** — see [kSchemaV2Statements]. The `messages.kind` CHECK is
/// deliberately **not** widened to a `folder` value: changing a CHECK means
/// rebuilding the table, and `DROP TABLE messages` under `foreign_keys = ON`
/// performs an implicit `DELETE FROM messages` that cascades into
/// `files.message_id` and **erases every attachment row**. That PRAGMA cannot
/// be switched off inside the migration's transaction either, so the rebuild
/// route is off the table for a pure field addition.
library;

/// The schema version this build writes into `PRAGMA user_version`.
const int kSchemaVersion = 2;

/// Table names created by the v1 schema (order is documentation only).
///
/// v2 adds no table — the list below is still the complete table set of
/// [kSchemaVersion].
const List<String> kSchemaV1Tables = <String>[
  'devices',
  'conversations',
  'messages',
  'files',
  'transfers',
];

/// Index names created by the v1 schema (order is documentation only).
const List<String> kSchemaV1Indexes = <String>[
  'ux_conversations_active',
  'ix_conversations_device',
  'ux_messages_event',
  'ix_messages_conv_created',
  'ix_messages_status',
  'ix_files_message',
  'ix_transfers_file',
  'ix_transfers_retry',
];

/// The complete v1 DDL, **one statement per element**.
///
/// `package:sqlite3`'s `Database.execute` runs a single statement per call, so
/// the statements must stay split rather than being concatenated into a script.
const List<String> kSchemaV1Statements = <String>[
  // ── devices (the counterparty of a conversation) ────────────────────────
  '''
CREATE TABLE IF NOT EXISTS devices (
  fingerprint   TEXT    PRIMARY KEY,
  alias         TEXT    NOT NULL,
  device_type   TEXT,
  model         TEXT,
  last_ip       TEXT,
  last_port     INTEGER,
  last_seen_at  INTEGER,
  trusted       INTEGER NOT NULL DEFAULT 0,
  paired_at     INTEGER,
  group_code    TEXT,
  CHECK (length(fingerprint) > 0),
  CHECK (trusted IN (0,1)),
  CHECK (last_port IS NULL OR last_port >= 0)
)''',

  // ── conversations (separate from devices to support archiving) ──────────
  '''
CREATE TABLE IF NOT EXISTS conversations (
  id                 TEXT    PRIMARY KEY,
  device_fingerprint TEXT    REFERENCES devices(fingerprint) ON DELETE SET NULL,
  created_at         INTEGER NOT NULL,
  last_message_at    INTEGER,
  last_preview       TEXT,
  archived_at        INTEGER,
  CHECK (length(id) > 0)
)''',

  // At most one *active* conversation per fingerprint (partial unique index).
  '''
CREATE UNIQUE INDEX IF NOT EXISTS ux_conversations_active
  ON conversations(device_fingerprint)
  WHERE archived_at IS NULL AND device_fingerprint IS NOT NULL''',

  '''
CREATE INDEX IF NOT EXISTS ix_conversations_device
  ON conversations(device_fingerprint, archived_at)''',

  // ── messages (one row = one transfer event; files are its attachments) ──
  '''
CREATE TABLE IF NOT EXISTS messages (
  id              TEXT    PRIMARY KEY,
  conversation_id TEXT    NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  direction       TEXT    NOT NULL,
  kind            TEXT    NOT NULL,
  text_body       TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  status          TEXT    NOT NULL,
  event_nonce     TEXT    NOT NULL,
  CHECK (direction IN ('in','out')),
  CHECK (kind IN ('file','text')),
  CHECK (kind <> 'text' OR text_body IS NOT NULL),
  CHECK (status IN ('pending','awaiting_confirm','transferring',
                    'done','failed','canceled','rejected'))
)''',

  // Idempotency guard: one message per (conversation, direction, event).
  '''
CREATE UNIQUE INDEX IF NOT EXISTS ux_messages_event
  ON messages(conversation_id, direction, event_nonce)''',

  '''
CREATE INDEX IF NOT EXISTS ix_messages_conv_created
  ON messages(conversation_id, created_at)''',

  '''
CREATE INDEX IF NOT EXISTS ix_messages_status
  ON messages(status)''',

  // ── files (a message may carry several) ─────────────────────────────────
  '''
CREATE TABLE IF NOT EXISTS files (
  id             TEXT    PRIMARY KEY,
  message_id     TEXT    NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  file_name      TEXT    NOT NULL,
  size           INTEGER NOT NULL,
  mime           TEXT,
  sha256         TEXT,
  local_path     TEXT,
  thumbnail_path TEXT
)''',

  '''
CREATE INDEX IF NOT EXISTS ix_files_message ON files(message_id)''',

  // ── transfers (retryable, queueable; no resume) ─────────────────────────
  '''
CREATE TABLE IF NOT EXISTS transfers (
  id              TEXT    PRIMARY KEY,
  file_id         TEXT    NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  session_id      TEXT,
  token           TEXT,
  bytes_done      INTEGER NOT NULL DEFAULT 0,
  bytes_total     INTEGER NOT NULL,
  chunk_size      INTEGER,
  retry_count     INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER,
  error           TEXT,
  updated_at      INTEGER NOT NULL
)''',

  '''
CREATE INDEX IF NOT EXISTS ix_transfers_file ON transfers(file_id)''',

  '''
CREATE INDEX IF NOT EXISTS ix_transfers_retry ON transfers(next_attempt_at)''',
];

/// The complete v2 DDL: three `ADD COLUMN` statements, one per element
/// (docs/22 §2.2 / §2.4).
///
/// `ALTER TABLE ... ADD COLUMN` is one of the few schema changes SQLite can do
/// in place — it rewrites no existing row and therefore cannot lose one, which
/// is exactly why v2 is additive instead of a table rebuild.
///
/// **Every new column is nullable and carries no `DEFAULT`.** A `NOT NULL`
/// column without a default cannot be back-filled for the rows that already
/// exist, so the *statement itself* fails; inside the migration's transaction
/// that rolls back the step, `applyMigrations` throws `MigrationException` and
/// the app cannot open its database at all. `NULL` is also the honest value
/// here: "not a folder message" / "this attachment has no sub-path"
/// (docs/22 §2.3).
///
/// No index is added in v2: nothing queries `folder_name` on its own
/// (conversation history is served by `ix_messages_conv_created`, a folder's
/// files by `ix_files_message`), so an index would be dead weight
/// (docs/22 §2.4).
const List<String> kSchemaV2Statements = <String>[
  // ── messages: the folder a message represents (NULL = plain message) ─────
  'ALTER TABLE messages ADD COLUMN folder_name TEXT',
  // The sender's *declared* file count; the arrived count is COUNT(files).
  'ALTER TABLE messages ADD COLUMN folder_files INTEGER',
  // ── files: path relative to the folder root, `/`-separated (NULL = flat) ─
  'ALTER TABLE files ADD COLUMN relative_path TEXT',
];
