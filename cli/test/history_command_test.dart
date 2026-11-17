import 'dart:convert';
import 'dart:io';

import 'package:lanlink_cli/src/commands/history_command.dart';
import 'package:lanlink_core/lanlink_core.dart';
import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

/// A representative 64-char uppercase-hex SHA-256 / fingerprint.
const String _hex64 =
    '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';

/// The fixed instant every fixture uses (spec §9.3).
final DateTime _t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lanlink_t05_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('a recorded outbound send shows up as one out/done message (JSON)',
      () async {
    final dbPath = _dbPath(tempDir, 'send.db');
    _recordSend(dbPath);

    final object = await _readJson(dbPath);

    expect(object['conversationCount'], 1);
    expect(object['messageCount'], 1);
    final conversations = object['conversations'] as List<Object?>;
    final conversation = conversations.single as Map<String, Object?>;
    final messages = conversation['messages'] as List<Object?>;
    final message = messages.single as Map<String, Object?>;
    expect(message['direction'], 'out');
    expect(message['kind'], 'file');
    expect(message['status'], 'done');
    final files = message['files'] as List<Object?>;
    final file = files.single as Map<String, Object?>;
    expect(file['fileName'], 'note.txt');
    expect(file['size'], 5);
    expect(file['sha256'], _hex64);
  });

  test('a recorded inbound file shows up as one in/done message (JSON)',
      () async {
    final dbPath = _dbPath(tempDir, 'recv.db');
    _recordReceive(dbPath);

    final object = await _readJson(dbPath);

    final conversation = (object['conversations'] as List<Object?>).single
        as Map<String, Object?>;
    final message = (conversation['messages'] as List<Object?>).single
        as Map<String, Object?>;
    expect(message['direction'], 'in');
    expect(message['status'], 'done');
    final file =
        (message['files'] as List<Object?>).single as Map<String, Object?>;
    expect(file['fileName'], 'photo.png');
  });

  test('re-recording the same send dedupes to a single message', () async {
    final dbPath = _dbPath(tempDir, 'dedupe.db');
    // Two independent store sessions, same wire fileId: the idempotent message
    // id must collapse them to one row (spec §5.6) — and `history` reflects it.
    _recordSend(dbPath);
    _recordSend(dbPath);

    final object = await _readJson(dbPath);

    expect(object['conversationCount'], 1);
    expect(object['messageCount'], 1);
  });

  test('the human rendering names the file, direction and status', () async {
    final dbPath = _dbPath(tempDir, 'human.db');
    _recordSend(dbPath);

    final lines = <String>[];
    final code = await HistoryCommand({'db': dbPath}, write: lines.add).run();

    expect(code, 0);
    final text = lines.join('\n');
    expect(text, contains('history  db=$dbPath'));
    expect(text, contains('note.txt'));
    expect(text, contains('OUT'));
    expect(text, contains('done'));
  });

  test('a missing database is reported as empty, not an error', () async {
    final dbPath = _dbPath(tempDir, 'absent.db');

    // JSON form: an empty, well-formed document.
    final object = await _readJson(dbPath);
    expect(object['conversationCount'], 0);
    expect((object['conversations'] as List<Object?>), isEmpty);

    // Human form: an explicit note, still exit 0.
    final lines = <String>[];
    final code = await HistoryCommand({'db': dbPath}, write: lines.add).run();
    expect(code, 0);
    expect(lines.join('\n'), contains('no database'));
  });

  test('--limit caps the messages shown per conversation', () async {
    final dbPath = _dbPath(tempDir, 'limit.db');
    _recordSend(dbPath, fileId: 'a');
    _recordSend(dbPath, fileId: 'b');

    final all = await _readJson(dbPath);
    expect(all['messageCount'], 2);

    final lines = <String>[];
    await HistoryCommand(
      {'db': dbPath, 'json': 'true', 'limit': '1'},
      write: lines.add,
    ).run();
    final limited = jsonDecode(lines.single) as Map<String, Object?>;
    expect(limited['messageCount'], 1);
  });
}

String _dbPath(Directory dir, String name) =>
    '${dir.path}${Platform.pathSeparator}$name';

/// Runs `history --json` and returns the decoded document.
Future<Map<String, Object?>> _readJson(String dbPath) async {
  final lines = <String>[];
  final code = await HistoryCommand(
    <String, String>{'db': dbPath, 'json': 'true'},
    write: lines.add,
  ).run();
  expect(code, 0);
  return jsonDecode(lines.single) as Map<String, Object?>;
}

/// Records one fully-successful outbound send (`pending -> done`) at [dbPath].
void _recordSend(String dbPath, {String fileId = 'file-1'}) {
  final store = _open(dbPath, prefix: 't');
  try {
    final peer = DeviceInfo(
      alias: 'Receiver',
      fingerprint: _hex64,
      port: 53317,
    );
    final result = store.recordOutgoingFiles(
      peer: peer,
      files: <OutgoingFileSpec>[
        OutgoingFileSpec(
          id: fileId,
          fileName: 'note.txt',
          size: 5,
          sha256: _hex64,
          localPath: '/tmp/note.txt',
          mime: 'text/plain',
        ),
      ],
      now: _t0,
    );
    store.setStatus(
      messageId: result.messageId,
      from: MessageStatus.pending,
      to: MessageStatus.awaitingConfirm,
      now: _t0,
    );
    store.setStatus(
      messageId: result.messageId,
      from: MessageStatus.awaitingConfirm,
      to: MessageStatus.transferring,
      now: _t0,
    );
    store.markSendSucceeded(
      messageId: result.messageId,
      now: _t0.add(const Duration(seconds: 1)),
    );
  } finally {
    store.close();
  }
}

/// Records one completed inbound file (`in -> done`) at [dbPath].
void _recordReceive(String dbPath) {
  final store = _open(dbPath, prefix: 'r');
  try {
    final sender = DeviceInfo(
      alias: 'Sender',
      fingerprint: _hex64,
      port: 53317,
    );
    store.recordIncomingFile(
      sender: sender,
      file: const IncomingFileSpec(
        fileId: 'rf-1',
        fileName: 'photo.png',
        size: 12,
        sha256: _hex64,
        savedPath: '/recv/photo.png',
        mime: 'image/png',
      ),
      now: _t0,
    );
  } finally {
    store.close();
  }
}

SessionStore _open(String dbPath, {required String prefix}) => SessionStore(
      db: LanlinkDatabase.openFile(dbPath),
      ids: SequentialIdGenerator(prefix: prefix),
    );
