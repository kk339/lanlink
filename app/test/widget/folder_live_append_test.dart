/// **A folder card must grow while the folder is still arriving** (0.2.51).
///
/// The defect these tests pin (step 1 of "多选文件在电脑端聚成一条消息"):
///
/// > 发一个文件夹、对方一个一个把文件传过来时，对面那张卡片**不会从 1 个刷到 2 个、3 个**，
/// > 只在别的消息进出时顺带重绘。
///
/// The data layer was right and the render was right — only the **notification**
/// was missing. `SessionStore` emits `MessageInserted` exactly once per session
/// (the first file creates the message, docs/22 §4.2), and the append branch
/// (file 2…N onto an existing message id) emitted **nothing**; the fake did the
/// same. So the bubble had two files and the screen still said one, because
/// nothing told the controller to look again.
///
/// The three halves, in the order the tests appear:
///
/// 1. **the red one**: 1 file arrived, then a 2nd → the card must go from
///    `已收到 1/3` to `已收到 2/3`. This is the user-visible fact, and it is what
///    fails when the append emits nothing;
/// 2. **the rate**: one batch of 3 files is **one** `MessageAdded` plus exactly
///    **two** `MessageFilesAppended` — not three (a naive "emit per file" would
///    also re-announce the message that was already there) and not zero (the
///    defect). A re-delivered file adds no row, so it adds no event either;
/// 3. **the flat path is untouched**: two consecutive flat arrivals are still
///    two messages with two events, and never a `MessageFilesAppended` — the
///    folder path's new event must not leak into the one-file-one-message path
///    (`transfer_orchestrator_test.dart:354` ★ keeps owning that rule).
///
/// Nothing here asserts *how* the UI is refreshed — only that it is. The event
/// is counted on the **fake repository** (`FakeSessionRepository
/// .filesAppendedEvents`), so a green means the notification really left the
/// data layer rather than being papered over by a widget-local rebuild.
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

import '../support/pump_app.dart';

const String _conversationId = 'c-append';
const String _folderName = 'lanlink-现场素材-0.2.51';
const String _sessionId = 's-append';

/// The sender's declared count for the fixture folder: 3 files.
const int _declared = 3;

/// The peer every arrival comes from (`openActive` reuses `_conversationId`).
const PeerDevice _sender = PeerDevice(
  fingerprint: 'CC01',
  alias: '小甲',
  kind: DeviceKind.desktop,
  isOnline: true,
  lastPort: 53317,
);

PeerDevice _peer() => _sender;

/// One file of the fixture folder, 1 MiB, laid out under `data/`.
IncomingFile _incoming(int index) => IncomingFile(
      fileId: 'f-$index',
      fileName: 'clip_$index.mp4',
      size: 1024 * 1024,
      sha256: 'AA',
      savedPath: '/downloads/lanlink/clip_$index.mp4',
      relativePath: 'data/clip_$index.mp4',
    );

/// Records the `prepare` session for one file — the **real** arrival path, not a
/// seeded row: the whole point is what that write notifies.
void _arrive(FakeBackend backend, int index) {
  backend.repo.recordIncomingFolderFile(
    sender: _sender,
    file: _incoming(index),
    sessionId: _sessionId,
    folderName: _folderName,
    folderFiles: _declared,
  );
}

/// A mounted thread over a folder message that already holds [arrived] files.
class _Harness {
  _Harness({
    required this.backend,
    required this.controller,
  });

  final FakeBackend backend;
  final ConversationController controller;

  /// Delivers file [index] and lets the thread react: one pump to hand the
  /// repository event over, one more for any awaited work it starts.
  Future<void> arrive(WidgetTester tester, int index) async {
    _arrive(backend, index);
    await tester.pump();
    await tester.pump();
  }
}

/// Seeds nothing but the conversation and mounts the timeline; [arrived] files
/// of the folder are recorded **before** the mount, exactly as a thread opened
/// mid-batch sees them (they are plain history by then).
Future<_Harness> _pumpThread(
  WidgetTester tester, {
  required int arrived,
}) async {
  useSurfaceSize(tester, const Size(600, 1200));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: _sender.fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  for (int i = 0; i < arrived; i++) {
    _arrive(backend, i);
  }
  backend.platform.setMobile(true);

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
  // Load **before** mounting: a thread still in `Loading` draws the spinner and
  // `pumpAndSettle` would never settle on it.
  unawaited(controller.load());
  await tester.pumpWidget(
    appWithScope(
      child: MaterialApp(
        home: Scaffold(
          body: ConversationThread(controller: controller, peer: _peer()),
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
      '★ the card grows while the folder arrives: 1 file landed, then a 2nd → '
      '「已收到 1/3」 becomes 「已收到 2/3」', (WidgetTester tester) async {
    final _Harness harness = await _pumpThread(tester, arrived: 1);

    // The thread opens on a folder that has received exactly one file.
    expect(find.text(_folderName), findsOneWidget);
    expect(find.text('已收到 1/3'), findsOneWidget,
        reason: '1 MiB arrived of 3 declared — the card must say so');

    // …and the second file lands, some seconds later, with the thread open.
    harness.backend.clock.advance(const Duration(seconds: 5));
    await harness.arrive(tester, 1);

    // ★ The defect: this stayed at 1/3 until some *other* message came or went.
    expect(find.text('已收到 2/3'), findsOneWidget,
        reason: 'a file appended to a message already on screen is a change the '
            'user can see, so the store must announce it and the timeline must '
            'repaint without waiting for an unrelated message');
    expect(find.text('已收到 1/3'), findsNothing);

    // The bytes line moves with it (2 MiB of the folder's 3 MiB are here).
    expect(find.text('2.0 MB · 3 个文件'), findsOneWidget);
    // Still ONE card — growing, not duplicating (docs/22 §4.2).
    expect(find.byIcon(Icons.folder), findsOneWidget);
  });

  testWidgets(
      '★ rate: a 3-file batch is ONE message + exactly TWO append events — not '
      'three, and not zero', (WidgetTester tester) async {
    // Mounted on an empty conversation: the batch starts while the user watches.
    final _Harness harness = await _pumpThread(tester, arrived: 0);
    expect(harness.backend.repo.filesAppendedEvents, 0,
        reason: 'nothing has arrived yet');

    await harness.arrive(tester, 0); // creates the message
    expect(harness.backend.repo.filesAppendedEvents, 0,
        reason: 'the file that CREATES the message is a `MessageAdded`, not an '
            'append — announcing it twice would double-fetch it');
    expect(find.text('已收到 1/3'), findsOneWidget);

    await harness.arrive(tester, 1);
    await harness.arrive(tester, 2);

    expect(harness.backend.repo.filesAppendedEvents, 2,
        reason: 'files 2 and 3 append to the message file 1 created: exactly two '
            'append events. Three would mean the creating file also announced '
            'itself; zero is the defect this step fixes');
    expect(find.text('已收到 3/3'), findsNothing,
        reason: 'a COMPLETE folder prints no count at all — the line is for a '
            'batch still arriving');
    expect(find.text('3.0 MB · 3 个文件'), findsOneWidget);

    // One message, three attachments — the aggregation itself is unchanged.
    expect(harness.controller.messages.valueOrNull, hasLength(1));
    expect(harness.controller.filesOf('in-folder:$_conversationId:$_sessionId'),
        hasLength(3));

    // A re-delivered file writes no row, so it must announce nothing either.
    await harness.arrive(tester, 1);
    expect(harness.backend.repo.filesAppendedEvents, 2,
        reason: 'the store writes nothing for a file id it already holds, and an '
            'event about a write that did not happen would be a lie');
  });

  testWidgets(
      '★ the flat path is untouched: two consecutive flat arrivals are two '
      'messages, two `MessageAdded`s and NO append event',
      (WidgetTester tester) async {
    final _Harness harness = await _pumpThread(tester, arrived: 0);

    for (int i = 0; i < 2; i++) {
      harness.backend.repo.recordIncoming(
        sender: _sender,
        file: IncomingFile(
          fileId: 'flat-$i',
          fileName: 'loose_$i.pdf',
          size: 2048,
          sha256: 'AA',
          savedPath: '/downloads/lanlink/loose_$i.pdf',
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    expect(harness.controller.messages.valueOrNull, hasLength(2),
        reason: 'one file per message on the flat path — unchanged (see '
            '`transfer_orchestrator_test.dart` ★ "two flat arrivals are two '
            'messages")');
    expect(harness.backend.repo.filesAppendedEvents, 0,
        reason: 'the append event belongs to the folder path only; a flat '
            'arrival must never claim to have grown an existing message');
    expect(find.text('loose_0.pdf'), findsOneWidget);
    expect(find.text('loose_1.pdf'), findsOneWidget);
    // …and no folder card appeared anywhere.
    expect(find.byIcon(Icons.folder), findsNothing);
  });
}
