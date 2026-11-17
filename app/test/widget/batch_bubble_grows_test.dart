/// **A multi-select batch is ONE bubble on the receiving side, and it grows**
/// (0.2.51, step 2 of "多选文件在电脑端聚成一条消息").
///
/// The sender has always encoded N selected files as **one `prepare` carrying N
/// files plus N `put`s**, and every arrival already carries the receiver's
/// session id — so nothing on the wire changes. What used to split the batch was
/// the store: with `folderName == null` the orchestrator called
/// `recordIncoming`, whose anchor is one `fileId`, giving one message per file.
///
/// Two things must be true at once, and each has its own failure mode:
///
/// 1. **one message, N rows** — a 5-file 多选 must be one bubble, not five
///    (criterion 1). The opposite failure — folding *everything* — is caught by
///    the different-session test in `transfer_orchestrator_test.dart`;
/// 2. **the bubble grows** — after file 2 arrives the bubble must show two rows,
///    not stay at one until some other message goes by (criterion 5). This is the
///    same defect step 1 fixed for folders, and it is why the batch path had to
///    go through `MessageFilesAppended` too: a batch with one visible file out of
///    five looks exactly like "the transfer died".
///
/// Everything is driven through the **real** orchestrator (`emitReceived` →
/// `TransferOrchestrator._onReceived` → repository → events → controller →
/// thread), so the branch under test is the production one, not a call to the
/// repository made by the test.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/pump_app.dart';

const String _conversationId = 'c-batch';
const String _sessionId = 'sess-multi-select';

const PeerDevice _peer = PeerDevice(
  fingerprint: 'CC01',
  alias: '小甲',
  kind: DeviceKind.desktop,
  isOnline: true,
  lastPort: 53317,
);

/// Every file of the fixture batch is 1 MiB and landable on disk.
const int _kSize = 1024 * 1024;

/// Where file [index] of the batch "landed" (and where a test can delete it).
String _pathOf(int index) => '/downloads/lanlink/clip_$index.bin';

/// What `FileTile` prints instead of the size line when the file is gone.
const String _kUnavailable = '源文件不可用';

/// What a tap on a row the app **knows** is gone says (0.2.48). It must never be
/// silence: a tap that does nothing is indistinguishable from a broken button.
const String _kTapNotice = '文件已不在原位置，无法打开';

DiscoveredPeer _sender() => DiscoveredPeer(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      address: '192.168.1.10',
      port: 53317,
      isOnline: true,
      lastSeen: fixedEpoch,
    );

/// A mounted thread over an empty conversation, plus the backend driving it.
class _Harness {
  _Harness({
    required this.backend,
    required this.controller,
  });

  final FakeBackend backend;
  final ConversationController controller;

  /// `n`-th file of the batch: flat, one session shared by all of them.
  void arrive(int index, {String sessionId = _sessionId}) {
    backend.transfer.emitReceived(
      ReceivedTransfer(
        file: IncomingFile(
          fileId: 'b-$index',
          fileName: 'clip_$index.bin',
          size: _kSize,
          sha256: 'AA',
          savedPath: _pathOf(index),
        ),
        sender: _sender(),
        sessionId: sessionId,
      ),
    );
  }

  /// Delivers one file and lets the event → probe → rebuild chain land.
  Future<void> deliver(WidgetTester tester, int index) async {
    arrive(index);
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  List<ChatMessage> get messages =>
      controller.messages.valueOrNull ?? const <ChatMessage>[];
}

Future<_Harness> _pumpThread(WidgetTester tester) async {
  useSurfaceSize(tester, const Size(600, 1200));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: _peer.fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.platform.setMobile(true);
  return _mount(tester, backend);
}

/// Mounts a **fresh** thread/controller over an existing backend — "leave the
/// conversation and come back", which is the only way to check that what the
/// timeline shows does not depend on having watched the arrivals happen.
Future<_Harness> _pumpThreadReusing(
  WidgetTester tester,
  FakeBackend backend,
) =>
    _mount(tester, backend);

Future<_Harness> _mount(WidgetTester tester, FakeBackend backend) async {
  final ConversationController controller = ConversationController(
    repo: backend.repo,
    orchestrator: TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    ),
    platform: backend.platform,
    ids: backend.ids,
    clock: backend.clock,
    conversationId: _conversationId,
    drafts: ComposerDraftStore(),
  );
  addTearDown(controller.dispose);
  unawaited(controller.load());
  await tester.pumpWidget(
    appWithScope(
      child: MaterialApp(
        home: Scaffold(
          body: ConversationThread(controller: controller, peer: _peer),
        ),
      ),
      deps: testDeps(backend),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(backend: backend, controller: controller);
}

void main() {
  testWidgets(
      '★ criterion 1 + 5: three files of one session are ONE bubble, and it '
      'grows 1 → 2 → 3 rows as they arrive', (WidgetTester tester) async {
    final _Harness harness = await _pumpThread(tester);

    // ── file 1: the message appears, one row.
    await harness.deliver(tester, 0);
    expect(harness.messages, hasLength(1),
        reason: 'one `prepare` session is one message');
    expect(find.byType(FileTile), findsNWidgets(1));
    expect(find.text('clip_0.bin'), findsOneWidget);
    // A batch is NOT a folder: no card, no 打开文件夹 affordance.
    expect(find.byIcon(Icons.folder), findsNothing,
        reason: 'a multi-select must never grow a folder card');

    // ── file 2: SAME bubble, now two rows (the step-1 defect, on this path).
    await harness.deliver(tester, 1);
    expect(harness.messages, hasLength(1),
        reason: 'still one message — the aggregation must not break on append');
    expect(find.byType(FileTile), findsNWidgets(2),
        reason: '★ the bubble must show the file that just landed; a static '
            'bubble here is "1 条但只显示 1 个文件"');
    expect(find.text('clip_1.bin'), findsOneWidget);
    expect(harness.controller.filesOf(harness.messages.single.id), hasLength(2),
        reason: 'two attachment rows on the one message — not two messages');

    // ── file 3: same again.
    await harness.deliver(tester, 2);
    expect(harness.messages, hasLength(1));
    expect(find.byType(FileTile), findsNWidgets(3));
    expect(find.text('clip_2.bin'), findsOneWidget);

    // The message itself is a plain file message, not a folder one.
    final ChatMessage message = harness.messages.single;
    expect(message.isFolder, isFalse);
    expect(message.folderName, isNull,
        reason: 'the batch path writes no descriptor, so no folder page can be '
            'opened for it and no declared count is claimed');
    expect(find.byIcon(Icons.folder), findsNothing);

    // …and the growth was *announced*, not merely re-read: files 2 and 3 are
    // exactly two `MessageFilesAppended` events (the file that created the
    // message is a `MessageAdded`). This is what ties the visible 1 → 2 → 3 to
    // step 1's mechanism instead of to some incidental repaint.
    expect(harness.backend.repo.filesAppendedEvents, 2,
        reason: 'a 3-file batch must announce exactly two appends');
  });

  testWidgets(
      '★ criterion 2: two files of DIFFERENT sessions stay two bubbles',
      (WidgetTester tester) async {
    final _Harness harness = await _pumpThread(tester);

    await harness.deliver(tester, 0);
    harness.arrive(1, sessionId: 'sess-other');
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(harness.messages, hasLength(2),
        reason: 'aggregation is per session — two sends are two messages');
    expect(find.byType(FileTile), findsNWidgets(2));
  });

  testWidgets(
      '★ the appended file is JUDGED: a file that vanishes right after it '
      'arrives dims to 「源文件不可用」 and the tap explains itself',
      (WidgetTester tester) async {
    // The growth itself is step 1's job (`MessageFilesAppended` repaints the
    // row). This is the other half: because the batch path grows a message
    // whose `isFolder` is **false**, a "does this message still grow?" rule
    // keyed on folders never judged the new attachment, so it kept the default
    // 「未知 ⇒ 在盘上」 answer and stayed tappable. Same defect class as
    // "1 条但只显示 1 个文件", one layer down: the count is right, the verdict is
    // not, and the user only finds out when the tap does nothing.
    final _Harness harness = await _pumpThread(tester);

    await harness.deliver(tester, 0);
    expect(find.byType(FileTile), findsNWidgets(1));
    expect(find.text('源文件不可用'), findsNothing);

    // File 2 lands, and is gone from disk by the time the probe can look at it.
    harness.arrive(1);
    harness.backend.platform.setExists(_pathOf(1), false);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // The row is there (the count did move) …
    expect(find.byType(FileTile), findsNWidgets(2));
    // … and it carries the real verdict, not the "unknown ⇒ available" default.
    //
    // `findsWidgets`, not `findsOneWidget`, because the bubble's verdict is
    // **per message**: 0.2.48 established that one missing attachment makes the
    // whole bubble's story false (every operation it still offers walks all of
    // its files), so both rows read 「源文件不可用」 while the taps stay per file.
    // That is existing behaviour for any multi-attachment bubble and is not what
    // this step changes — what it changes is that there is a verdict at all.
    expect(find.text(_kUnavailable), findsWidgets,
        reason: '★ an appended attachment must be probed like any other; '
            'otherwise a deleted file keeps looking openable');

    // 「不静默」: the tap says why instead of doing nothing.
    await tester.tap(find.text('clip_1.bin'));
    await tester.pumpAndSettle();
    expect(find.text(_kTapNotice), findsOneWidget);
    expect(harness.backend.platform.opened, isEmpty,
        reason: 'the platform must not be asked to open a path we know is gone');
    await tester.pump(const Duration(seconds: 3));

    // ── and the verdict survives leaving and re-entering the conversation: a
    // re-mounted thread probes the history afresh, so "re-enter to get the
    // truth" can never diverge from what was on screen.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final _Harness again = await _pumpThreadReusing(tester, harness.backend);
    expect(again.messages, hasLength(1));
    expect(find.text(_kUnavailable), findsWidgets,
        reason: 'the same file must be judged the same way on a fresh visit');
  });
}
