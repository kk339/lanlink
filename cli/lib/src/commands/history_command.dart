import 'dart:convert';
import 'dart:io';

import 'package:lanlink_store/lanlink_store.dart';

/// `lanlink history` — read back the M3 session history and print it.
///
/// Options:
///   * `--db <path>`   path to the history database (default:
///                     `%LOCALAPPDATA%\lanlink\lanlink.db`). `--db` with no
///                     value uses that default location.
///   * `--json`        emit a single JSON object (`{db, conversations: [...]}`)
///                     for scripts instead of the human readable rendering
///   * `--archived`    also list archived conversations (default: active only)
///   * `--limit <n>`   cap the number of messages shown per conversation
///                     (default: all)
///
/// Exit codes: `0` success (including "no database yet"); `64` usage error.
///
/// The output is a *pure function of the database*: the same file renders the
/// same way every time (conversations by recency, messages newest first). The
/// write side (this milestone) lives in `send` / `discover --accept`, which only
/// record when they are given an explicit `--db`.
class HistoryCommand {
  /// Creates the command; [write] overrides the output sink (tests).
  HistoryCommand(this.options, {void Function(String line)? write})
      : _write = write ?? stdout.writeln;

  /// Raw `--key value` options parsed from the command line.
  final Map<String, String> options;

  final void Function(String line) _write;

  Future<int> run() async {
    final dbPath = _resolveDbPath(options) ?? _defaultDbPath();
    final asJson = options['json'] == 'true';
    final includeArchived = options['archived'] == 'true';
    final limitOption = _intOption(options, 'limit', 0);
    final limit = limitOption > 0 ? limitOption : null;

    // A missing database is not an error: it simply means nothing was ever
    // recorded (e.g. M2 workflows that never pass `--db`).
    if (!File(dbPath).existsSync()) {
      if (asJson) {
        _write(jsonEncode(<String, Object?>{
          'db': dbPath,
          'conversationCount': 0,
          'messageCount': 0,
          'conversations': const <Object?>[],
        }));
      } else {
        _write('history: no database at $dbPath (nothing recorded yet)');
      }
      return 0;
    }

    final db = LanlinkDatabase.openFile(dbPath);
    final store = SessionStore(db: db, ids: RandomIdGenerator());
    try {
      final conversations =
          store.conversations(includeArchived: includeArchived);
      final views = <_ConversationView>[];
      var messageCount = 0;
      for (final conversation in conversations) {
        final messages = store.history(conversation.id, limit: limit);
        messageCount += messages.length;
        views.add(
          _ConversationView(
            record: conversation,
            messages: <_MessageView>[
              for (final message in messages)
                _MessageView(
                  record: message,
                  files: store.filesOf(message.id),
                ),
            ],
          ),
        );
      }

      if (asJson) {
        _write(jsonEncode(<String, Object?>{
          'db': dbPath,
          'conversationCount': views.length,
          'messageCount': messageCount,
          'conversations': <Object?>[
            for (final view in views) view.toJson(),
          ],
        }));
      } else {
        _printHuman(dbPath, views, messageCount);
      }
      return 0;
    } finally {
      store.close();
    }
  }

  void _printHuman(
    String dbPath,
    List<_ConversationView> views,
    int messageCount,
  ) {
    _write('history  db=$dbPath');
    _write('${views.length} conversation(s), $messageCount message(s)');
    if (views.isEmpty) {
      _write('(no history yet)');
      return;
    }
    for (final view in views) {
      _write('');
      _write(view.headerLine());
      if (view.messages.isEmpty) {
        _write('    (no messages)');
        continue;
      }
      for (final message in view.messages) {
        _write('    ${message.line()}');
      }
    }
  }
}

/// The rendered view of one conversation and its messages.
class _ConversationView {
  _ConversationView({required this.record, required this.messages});

  final ConversationRecord record;
  final List<_MessageView> messages;

  String headerLine() {
    final device = record.deviceFingerprint == null
        ? '-'
        : _short(record.deviceFingerprint!);
    final archived = record.isArchived ? '  [archived]' : '';
    final preview =
        record.lastPreview == null ? '-' : _oneLine(record.lastPreview!);
    return '▪ ${record.id}  device=$device  '
        'created=${_iso(record.createdAt)}  '
        'last=${_isoOrDash(record.lastMessageAt)}  '
        'preview=$preview$archived';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': record.id,
        'deviceFingerprint': record.deviceFingerprint,
        'createdAt': _iso(record.createdAt),
        'lastMessageAt': _isoOrNull(record.lastMessageAt),
        'lastPreview': record.lastPreview,
        'archivedAt': _isoOrNull(record.archivedAt),
        'messages': <Object?>[for (final m in messages) m.toJson()],
      };
}

/// The rendered view of one message and its attached files.
class _MessageView {
  _MessageView({required this.record, required this.files});

  final MessageRecord record;
  final List<MessageFileRecord> files;

  String line() {
    final direction =
        record.direction == MessageDirection.outgoing ? 'OUT' : 'IN ';
    final status = record.status.wire.padRight(16);
    final summary = _summary();
    return '${_iso(record.createdAt)}  $direction  $status  $summary';
  }

  String _summary() {
    if (record.kind == MessageKind.text) {
      final body = record.textBody ?? '';
      return '(text) ${_oneLine(body)}';
    }
    if (files.isEmpty) {
      return '(no files)';
    }
    final parts = <String>[];
    for (final file in files) {
      final hash =
          file.sha256 == null ? '' : '  sha256=${_short(file.sha256!)}';
      parts.add('${file.fileName} (${file.size} B)$hash');
    }
    return parts.join(' | ');
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': record.id,
        'direction': record.direction.wire,
        'kind': record.kind.wire,
        'status': record.status.wire,
        'createdAt': _iso(record.createdAt),
        'updatedAt': _iso(record.updatedAt),
        'textBody': record.textBody,
        'files': <Object?>[
          for (final file in files)
            <String, Object?>{
              'id': file.id,
              'fileName': file.fileName,
              'size': file.size,
              'mime': file.mime,
              'sha256': file.sha256,
              'localPath': file.localPath,
            },
        ],
      };
}

/// The default on-disk database location (spec §11.4):
/// `%LOCALAPPDATA%\lanlink\lanlink.db`, falling back to a home-relative path
/// on platforms without `LOCALAPPDATA`.
String _defaultDbPath() {
  final base = Platform.environment['LOCALAPPDATA'] ??
      Platform.environment['XDG_DATA_HOME'] ??
      Directory.current.path;
  return <String>[base, 'lanlink', 'lanlink.db'].join(Platform.pathSeparator);
}

/// Resolves `--db`: `null` when the option is absent, the default location when
/// it is given without a value, else the supplied path.
String? _resolveDbPath(Map<String, String> options) {
  final raw = options['db'];
  if (raw == null) {
    return null;
  }
  if (raw == 'true' || raw.isEmpty) {
    return _defaultDbPath();
  }
  return raw;
}

int _intOption(Map<String, String> options, String key, int fallback) {
  final raw = options[key];
  if (raw == null) {
    return fallback;
  }
  return int.tryParse(raw) ?? fallback;
}

/// ISO-8601 in UTC (`...Z`), the canonical rendering of every stored instant.
String _iso(DateTime value) => value.toUtc().toIso8601String();

String? _isoOrNull(DateTime? value) => value == null ? null : _iso(value);

String _isoOrDash(DateTime? value) => value == null ? '-' : _iso(value);

/// The first 16 hex characters of [value] followed by an ellipsis, so a long
/// fingerprint / hash stays readable without hiding that it was truncated.
String _short(String value) =>
    value.length <= 16 ? value : '${value.substring(0, 16)}…';

/// Collapses newlines so one record always renders on one line.
String _oneLine(String value) =>
    value.replaceAll('\r', ' ').replaceAll('\n', ' ');
