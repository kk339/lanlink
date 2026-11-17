/// "The source file is gone" — said out loud, and said **before** dialling
/// (0.2.52).
///
/// **The defect.** `OutboxPump._resume` checked that an attachment's `localPath`
/// was *non-empty* and nothing else. On Android that path is a copy in
/// `cache/lanlink-picked/<uuid>/`, which the launch sweep used to delete at the
/// next boot — so a queued message could name a file that no longer existed, and
/// the pump dialled anyway. What the user saw was 「失败」 with no reason: the
/// raw `FileSystemException` that eventually surfaced is deliberately **not**
/// printed by the timeline (a diagnostic string must not become UI copy, see
/// `_failureNote`), and nothing named the one action available (重新发送).
///
/// Two things are asserted, and both matter:
///
/// * the message fails **immediately** — `prepareCalls` stays `0`, so no
///   request that can only fail is ever sent;
/// * it fails with a reason a person can read (`kSourceMissingError`), which the
///   bubble then prints (`widget/failed_source_note_test.dart`).
///
/// The fixture is the real pump + real orchestrator over the fake ports: the bug
/// lived in the seam, and a hand-rolled double would have hidden it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/outbox_pump.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';

import 'support/fakes.dart';

const String _kFingerprint = 'AAAA1111';
const String _kConversationId = 'c-source-gone';
final DateTime _t0 = DateTime.utc(2026, 1, 1, 12);

/// The peer the queue is waiting for: stored offline, live and dialable now.
DiscoveredPeer _livePeer() => DiscoveredPeer(
      fingerprint: _kFingerprint,
      alias: 'Alice Laptop',
      kind: DeviceKind.desktop,
      address: '192.168.1.10',
      port: 53317,
      isOnline: true,
      lastSeen: _t0,
    );

FakeBackend _backend() {
  final FakeBackend backend = FakeBackend(
    now: _t0,
    devices: <PeerDevice>[
      PeerDevice(
        fingerprint: _kFingerprint,
        alias: 'Alice Laptop',
        kind: DeviceKind.desktop,
        isOnline: false,
        lastPort: 53317,
        lastSeenAt: _t0,
      ),
    ],
  );
  backend.repo.addConversation(
    id: _kConversationId,
    deviceFingerprint: _kFingerprint,
    createdAt: _t0,
    lastMessageAt: _t0,
  );
  return backend;
}

/// Seeds one `pending` outgoing **file** message — the row
/// `TransferOrchestrator.send` leaves behind when the peer is offline.
void _seedQueuedFile(FakeBackend backend, {required String localPath}) {
  backend.repo.addMessage(
    id: 'm-queued',
    conversationId: _kConversationId,
    direction: MessageDirection.outgoing,
    status: MessageStatus.pending,
    createdAt: _t0,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f-queued',
        messageId: 'm-queued',
        fileName: 'report.pdf',
        size: 2048,
        sha256: 'AB' * 32,
        localPath: localPath,
      ),
    ],
  );
}

OutboxPump _pump(FakeBackend backend) => OutboxPump(
      repo: backend.repo,
      discovery: backend.discovery,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      clock: backend.clock,
    );

Future<void> _settle() async {
  for (int i = 0; i < 8; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

ChatMessage _message(FakeBackend backend) => backend.repo
    .messagesByStatus(<MessageStatus>{...MessageStatus.values})
    .firstWhere((ChatMessage message) => message.id == 'm-queued');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('1. a vanished source fails at once, without dialling', () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend, localPath: '/cache/lanlink-picked/uuid-1/report.pdf');
    backend.platform.setExists(
      '/cache/lanlink-picked/uuid-1/report.pdf',
      false,
    );
    final OutboxPump pump = _pump(backend);
    addTearDown(pump.dispose);

    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(backend.transfer.prepareCalls, 0,
        reason: 'the file is not there — a prepare-upload can only fail, so it '
            'must never be sent');
    expect(_message(backend).status, MessageStatus.failed,
        reason: 'a message that cannot be resumed must leave `pending`, or the '
            'queue goes on retrying it forever');
  });

  test('2. …and the recorded reason is readable and names the way out',
      () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend, localPath: '/cache/lanlink-picked/uuid-2/report.pdf');
    backend.platform.setExists(
      '/cache/lanlink-picked/uuid-2/report.pdf',
      false,
    );
    final OutboxPump pump = _pump(backend);
    addTearDown(pump.dispose);

    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    final String? error = backend.repo.transferOf('f-queued')?.error;
    expect(error, isNotNull,
        reason: 'a failure with no reason is the half of the bug the user '
            'meets first');
    expect(error, contains('重新发送'),
        reason: 'the sentence has to name the action the bubble offers');
    expect(error, equals(kSourceMissingError),
        reason: 'the writer and the reader must spell it the same way — a '
            'second hand-written copy is how the UI stops matching');
    expect(error, isNot(contains('Exception')),
        reason: 'a raw exception string is a diagnostic, not an answer');
  });

  test('3. a source that IS there still goes out (no over-eager guard)',
      () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend, localPath: '/src/report.pdf');
    final OutboxPump pump = _pump(backend);
    addTearDown(pump.dispose);

    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(backend.transfer.prepareCalls, 1,
        reason: 'the guard exists to skip a doomed dial, not to stop sending');
    expect(_message(backend).status, MessageStatus.done);
  });

  test('4. a throwing `exists` counts as present — never block a real send',
      () async {
    final FakeBackend backend = _backend();
    _seedQueuedFile(backend, localPath: '/src/report.pdf');
    backend.platform.failExistsWith(StateError('port unavailable'));
    final OutboxPump pump = _pump(backend);
    addTearDown(pump.dispose);

    pump.start();
    await _settle();
    backend.discovery.comeOnline(_livePeer());
    await _settle();

    expect(backend.transfer.prepareCalls, 1,
        reason: 'a host that cannot answer must not turn a sendable message '
            'into a permanent 失败');
    expect(_message(backend).status, MessageStatus.done);
  });
}
