/// **One message, N attachments — one progress bar** (0.2.49).
///
/// The defect these tests pin (user report, Android):
///
/// > 点附件按钮多选了很多视频一次性发送，只显示某一个视频的传输过程，然后就一直呆在那；
/// > 实际一直在传，但只显示一个过程之后就不显示其他的了。
///
/// A multi-select send is **one** `MessageRecord` with N `MessageFileRecord`s
/// (`SessionStore.recordOutgoing`), and the bubble used to read the progress of
/// `files.first` alone (`ORDER BY rowid ASC` = selection order = upload order).
/// The first file therefore pinned the bar at 100 % for the whole batch: the
/// remaining N−1 files were uploading with **not one pixel changing**, so "正在
/// 传下一个" and "卡死了" looked identical on the user's screen.
///
/// Everything here is asserted **through the real `ConversationThread`**, i.e.
/// along the path the app actually walks (`controller.filesOf` →
/// `controller.transferOf` → the aggregate → `MessageBubble.progress`), because
/// the bug lived in that wiring and not in the bar:
///
///  1. 2 attachments, the 1st at 100 % and the 2nd at 30 % → **total** 65 %, the
///     「第 2/2 个」 caption, and no `100%` / `即将完成` anywhere;
///  2. the same message while the **1st** file is at 50 % → 25 %, *not* 50 %;
///  3. one attachment → byte-identical to the old behaviour (regression);
///  4. all files complete while the message is still `transferring` → 100 % and
///     no caption; once the store moves it to `done` the bar is **gone** and the
///     bubble says 已完成 (regression: no "100 % but stuck in 传输中" state).
///
/// The folder variant of the same aggregate lives in `folder_bubble_test.dart`
/// (`folder` keeps its own card; only the numbers' source is shared).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/bootstrap/app_deps.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/pump_app.dart';

const String _conversationId = 'c-multi';
const String _messageId = 'm-multi';

/// Every attachment is the same size, so a percentage is arithmetic a reader can
/// check in his head: N × 1000 bytes, and "the 2nd file at 30 %" is 1300/2000.
const int _size = 1000;

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'AAAA1111',
      alias: 'Alice',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// `count` attachments of [_size] bytes, in selection order (`f-0` first — the
/// order `filesOf` returns and therefore the order the orchestrator uploads).
List<FileAttachment> _files(int count) => <FileAttachment>[
      for (int i = 0; i < count; i++)
        FileAttachment(
          id: 'f-$i',
          messageId: _messageId,
          fileName: 'clip_$i.mp4.bin',
          size: _size,
          sha256: '00',
          localPath: '/src/clip_$i.mp4.bin',
        ),
    ];

/// A mounted thread plus the handles needed to drive and tear it down.
class _Thread {
  _Thread(this.backend, this.controller, this.orchestrator);

  final FakeBackend backend;
  final ConversationController controller;
  final TransferOrchestrator orchestrator;

  bool _disposed = false;

  /// Released **inside** the test body as well as in `addTearDown`: the
  /// framework checks "no timer is still pending" *before* tear-downs run, and a
  /// live transfer legitimately keeps the 1 Hz poll armed.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  }
}

/// Mounts one conversation holding one message with `fileCount` attachments.
///
/// [bytesDone] is indexed by attachment (0-based); an attachment left out keeps
/// the seeded `0 / size` row that `addMessage` writes for every file — which is
/// exactly what the real store does when the batch begins (`attachSession`
/// creates a row per file before the first byte moves).
Future<_Thread> _mount(
  WidgetTester tester, {
  required int fileCount,
  Map<int, int> bytesDone = const <int, int>{},
  MessageStatus status = MessageStatus.transferring,
}) async {
  useSurfaceSize(tester, const Size(600, 900));
  final FakeBackend backend = FakeBackend();
  final List<FileAttachment> files = _files(fileCount);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'AAAA1111',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: _messageId,
    conversationId: _conversationId,
    direction: MessageDirection.outgoing,
    status: status,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
    files: files,
  );
  bytesDone.forEach((int index, int done) {
    backend.repo.addTransfer(
      TransferProgress(fileId: files[index].id, bytesDone: done, bytesTotal: _size),
    );
  });

  final AppDeps deps = testDeps(backend);
  final TransferOrchestrator orchestrator = TransferOrchestrator(
    repo: deps.repo,
    transfer: deps.transfer,
  );
  final ConversationController controller = ConversationController(
    repo: deps.repo,
    orchestrator: orchestrator,
    platform: deps.platform,
    ids: deps.ids,
    clock: deps.clock,
    conversationId: _conversationId,
  );
  final _Thread thread = _Thread(backend, controller, orchestrator);
  addTearDown(thread.dispose);
  // Exactly what opening a conversation does: build the controller, load, hand
  // it to the thread.
  await controller.load();
  await pumpApp(
    tester,
    Scaffold(body: ConversationThread(controller: controller, peer: _peer())),
    backend: backend,
  );
  return thread;
}

/// The bar's fraction — the number the user is watching — or `null` when no bar
/// is drawn at all.
double? _barValue(WidgetTester tester) {
  final Finder finder = find.byType(LinearProgressIndicator);
  if (finder.evaluate().isEmpty) {
    return null;
  }
  expect(finder, findsOneWidget, reason: 'one bubble → at most one bar');
  return tester.widget<LinearProgressIndicator>(finder).value;
}

void main() {
  testWidgets(
      '判据 1: 2 个附件、第 1 个已 100%、第 2 个 30% → 总进度 65%，'
      '显示「第 2/2 个」，不显示 100% / 即将完成', (WidgetTester tester) async {
    final _Thread thread = await _mount(
      tester,
      fileCount: 2,
      // 1000/1000 + 300/1000 = 1300/2000 = 65 %.
      bytesDone: <int, int>{0: _size, 1: 300},
    );

    // The whole point: the bar is the **batch**, not the finished first file.
    // Old wiring read `files.first` and drew 1.0 here.
    expect(_barValue(tester), closeTo(0.65, 1e-9));
    expect(find.textContaining('· 65%'), findsOneWidget);
    // …so nothing on this bubble may claim the batch is complete.
    expect(
      find.textContaining('100%'),
      findsNothing,
      reason: 'the first file being done is not the batch being done',
    );
    // And the live signal: which file the batch has reached. Without it a
    // stalled batch and a batch that moved on to file 2 look the same.
    expect(find.text('第 2/2 个'), findsOneWidget,
        reason: 'the 1st is complete, so the one being uploaded is #2');

    thread.dispose();
  });

  testWidgets(
      '判据 2: 同一条消息，第 1 个附件 50% 时 → 总进度 25%（两个文件等大）',
      (WidgetTester tester) async {
    final _Thread thread = await _mount(
      tester,
      fileCount: 2,
      // 500/1000 + 0/1000 = 500/2000 = 25 %.
      bytesDone: <int, int>{0: 500},
    );

    expect(_barValue(tester), closeTo(0.25, 1e-9),
        reason: 'half of the first of two equal files is a quarter of the batch');
    expect(find.textContaining('· 25%'), findsOneWidget);
    // The ordinal is the file the batch is on, not the one that is done.
    expect(find.text('第 1/2 个'), findsOneWidget);

    thread.dispose();
  });

  testWidgets(
      '判据 3（回归）: 单附件消息与改动前**完全一致** — 精确的分子/分母/百分比，'
      '且没有「第 k/N 个」', (WidgetTester tester) async {
    final _Thread thread = await _mount(
      tester,
      fileCount: 1,
      bytesDone: <int, int>{0: 500},
    );

    expect(_barValue(tester), closeTo(0.5, 1e-9));
    // Exact string, not a `textContaining`: a single attachment has no batch to
    // aggregate, so the label must be byte-identical to what it always was.
    expect(find.text('500 B / 1000 B · 50%'), findsOneWidget);
    expect(
      find.textContaining('第 '),
      findsNothing,
      reason: 'a one-file message has no "第 1/1 个" to report',
    );

    thread.dispose();
  });

  testWidgets(
      '判据 4（回归）: 全部传完 → 传输中时是 100% 且无「第 k/N 个」；'
      '消息转 done 后进度条消失、气泡读 已完成', (WidgetTester tester) async {
    final _Thread thread = await _mount(
      tester,
      fileCount: 2,
      bytesDone: <int, int>{0: _size, 1: _size},
    );

    // The honest intermediate state: every byte is on the peer, but the message
    // has not been moved to `done` yet. 100 % is correct here — what must not
    // happen is claiming a *file index* is still in flight.
    expect(_barValue(tester), closeTo(1.0, 1e-9));
    expect(find.textContaining('第 '), findsNothing,
        reason: 'nothing is being uploaded, so there is no current file');

    // The store moves the message to `done` — the transition the receiver's
    // ack produces — and the bar must be gone rather than parked at 100 %.
    thread.backend.repo.markSendSucceeded(messageId: _messageId);
    await tester.pumpAndSettle();

    expect(_barValue(tester), isNull);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('第 '), findsNothing);

    thread.dispose();
  });

  testWidgets(
      '判据 1（续）：批处理走到 65% 时**不显示**「即将完成」——'
      '改动前把第一个文件的 100% 喂给进度条，屏幕上写的是「即将完成」',
      (WidgetTester tester) async {
    // The bar's ETA needs a *history*, and a history needs a clock the test can
    // advance (the thread hands the bubble the system clock, which no widget test
    // can move). So this one drives `MessageBubble` directly — but with the value
    // the **production** path now produces, i.e. the aggregate from
    // `MessageTransferProgress.of`, not a hand-picked number. The three instants
    // are the three ticks of one batch: file 1 half way, file 1 home, file 2 at
    // 30 %.
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    final FixedClock clock = FixedClock(DateTime.utc(2026, 1, 7, 12));
    final List<FileAttachment> files = _files(2);

    const List<List<int>> ticks = <List<int>>[
      <int>[500, 0],
      <int>[1000, 0],
      <int>[1000, 300],
    ];
    for (final List<int> donePair in ticks) {
      final MessageTransferProgress aggregate = MessageTransferProgress.of(
        files,
        progressOf: (String fileId) {
          final int index = files.indexWhere((FileAttachment f) => f.id == fileId);
          return TransferProgress(
            fileId: fileId,
            bytesDone: donePair[index],
            bytesTotal: _size,
          );
        },
      );
      await tester.pumpWidget(
        appWithScope(
          deps: testDeps(backend),
          child: Scaffold(
            body: MessageBubble(
              message: ChatMessage(
                id: _messageId,
                conversationId: _conversationId,
                direction: MessageDirection.outgoing,
                kind: MessageKind.file,
                createdAt: fixedEpoch,
                updatedAt: fixedEpoch,
                status: MessageStatus.transferring,
              ),
              files: files,
              progress: aggregate.bar,
              progressOrdinal: aggregate.ordinal,
              clock: clock,
            ),
          ),
        ),
      );
      await tester.pump();
      clock.advance(const Duration(seconds: 1));
    }

    expect(find.textContaining('· 65%'), findsOneWidget);
    expect(find.text('第 2/2 个'), findsOneWidget);
    // ★ The report, in one line: 700 bytes of 2000 are still missing, so the
    // batch is **not** about to finish. 0.2.48 printed 「即将完成」 here, because
    // the ETA was computed from file 1's `1000/1000`.
    expect(
      find.text('即将完成'),
      findsNothing,
      reason: 'the first file being home is not the batch being nearly home',
    );
    // …and it does print an honest forecast for the whole batch: 700 B left at
    // the 400 B/s the 2 s window measured.
    expect(find.text('剩 1 秒'), findsOneWidget);
  });
}
