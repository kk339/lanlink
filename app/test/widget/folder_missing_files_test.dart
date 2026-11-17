/// 「N 个未收到」 — the one line on a folder card that needs a **clock**
/// (0.2.42, `docs/22` §4.4).
///
/// The receiver has no "batch finished" frame: `put` arrives one file at a time,
/// so a folder that stalled with 3 of 5 files missing is indistinguishable from
/// one that is merely between files — **unless you measure silence**. So the
/// rule is: `missing = declared - arrived`, and only once the folder has been
/// quiet for longer than `kFolderQuietPeriod` (90 s).
///
/// These tests exist because the line used to be **structurally** unreachable
/// (`missing` was hard-wired to `0` while the render branch and a test for it
/// were already written — a green that proved nothing). Every case below fails
/// against that version, and each one picks a different way to be wrong:
///
/// 1. 30 s quiet, 5 declared / 2 arrived → `0`, **no line** — a peer may still be
///    uploading, and 「3 个未收到」 there would be a lie a later file disproves;
/// 2. the same data at 200 s quiet → `3`, and the card says so;
/// 3. 5 declared / 5 arrived → `0` **however long** it has been quiet;
/// 4. a message that declared **nothing** (`folderFiles == 0`, e.g. a single-file
///    send) → `0`, always. (Since 0.2.52 a flat *multi-select* does declare a
///    count and is judged by the same rule — `batch_missing_files_test.dart`.)
/// 5. plus the boundary itself (90 s exactly is *not* enough), the "unknown
///    activity" case (claim nothing), and the fake's activity bookkeeping, so the
///    fake cannot be the reason a widget test passes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

const String _conversationId = 'c-missing';
const String _folderName = 'lanlink-素材-0.2.42';
const String _messageId = 'm-folder';
const String _sessionId = 's-1';

/// The sentence the bubble prints, for [count] files (`message_bubble.dart`).
String _line(int count) => '$count 个未收到';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

const PeerDevice _sender = PeerDevice(
  fingerprint: 'CC01',
  alias: '小甲',
  kind: DeviceKind.desktop,
  isOnline: true,
  lastPort: 53317,
);

/// [count] attachments, 1 MiB each, under `data/`.
List<FileAttachment> _files(int count) => <FileAttachment>[
      for (int i = 0; i < count; i++)
        FileAttachment(
          id: 'f-$i',
          messageId: _messageId,
          fileName: 'file_$i.bin',
          size: 1024 * 1024,
          sha256: 'AA',
          localPath: '/downloads/lanlink/file_$i.bin',
          relativePath: 'data/file_$i.bin',
        ),
    ];

/// Seeds one folder message: [declared] files were promised, [arrived] landed.
///
/// The rows are written at [fixedEpoch] (the fake derives activity from
/// `created_at`, exactly as the store falls back to it), so the quiet period is
/// whatever `now` the caller pins — nothing here reads the wall clock.
void _seedFolder(
  FakeBackend backend, {
  required int declared,
  required int arrived,
}) {
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: _messageId,
    conversationId: _conversationId,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: MessageKind.file,
    folderName: _folderName,
    folderFiles: declared,
    files: _files(arrived),
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
}

/// Mounts the thread over [backend] and settles.
Future<void> _mountThread(
  WidgetTester tester,
  FakeBackend backend, {
  Clock? clock,
}) async {
  useSurfaceSize(tester, const Size(600, 1200));
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
          body: ConversationThread(
            controller: controller,
            peer: _peer(),
            clock: clock,
          ),
        ),
      ),
      deps: testDeps(backend),
    ),
  );
  await tester.pumpAndSettle();
}

/// Builds a backend whose **now** is [nowUtc] and mounts one folder message.
Future<FakeBackend> _pumpFolder(
  WidgetTester tester, {
  required int declared,
  required int arrived,
  required DateTime nowUtc,
  Clock? clock,
  /// Also seed a **flat** three-PDF message (criterion 4): a multi-select is not
  /// an incomplete folder and must never grow the line.
  bool flatToo = false,
}) async {
  final FakeBackend backend = FakeBackend(now: nowUtc);
  addTearDown(backend.dispose);
  _seedFolder(backend, declared: declared, arrived: arrived);
  if (flatToo) {
    backend.repo.addMessage(
      id: 'm-flat',
      conversationId: _conversationId,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.file,
      files: <FileAttachment>[
        for (int i = 0; i < 3; i++)
          FileAttachment(
            id: 'flat-$i',
            messageId: 'm-flat',
            fileName: 'loose_$i.pdf',
            size: 2048,
            sha256: 'AA',
            localPath: '/downloads/loose_$i.pdf',
          ),
      ],
      createdAt: fixedEpoch.add(const Duration(minutes: 1)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
    );
  }
  await _mountThread(tester, backend, clock: clock);
  return backend;
}

/// Builds a backend whose folder message was filled by **real arrivals**:
/// [arrived] files of [declared], the last one landing [quietFor] before the
/// backend's clock reads [fixedEpoch] + [quietFor].
///
/// This is the shape the rule actually has to survive: the message is old, but
/// the last `put` was recent. Unlike [_seedFolder] it goes through
/// `recordIncomingFolderFile`, so the activity instant comes from the fake's own
/// write path rather than from a seeded `created_at`.
Future<FakeBackend> _backendFilledByArrivals({
  required int declared,
  required int arrived,
  required Duration quietFor,
}) async {
  final FakeBackend backend = FakeBackend(now: fixedEpoch);
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  for (int i = 0; i < arrived; i++) {
    if (i > 0) {
      // Spread the arrivals out so the *last* one is what the rule must read.
      backend.clock.advance(const Duration(seconds: 5));
    }
    backend.repo.recordIncomingFolderFile(
      sender: _sender,
      file: IncomingFile(
        fileId: 'f-$i',
        fileName: 'file_$i.bin',
        size: 1024 * 1024,
        sha256: 'AA',
        savedPath: '/downloads/lanlink/file_$i.bin',
        relativePath: 'data/file_$i.bin',
      ),
      sessionId: _sessionId,
      folderName: _folderName,
      folderFiles: declared,
    );
  }
  // The last arrival is the newest activity; move the clock to `quietFor` past
  // it so the caller can express "the last put was N seconds ago".
  backend.clock.advance(quietFor);
  return backend;
}

void main() {
  // ── the rule itself ────────────────────────────────────────────────────
  group('missingFolderFiles', () {
    final DateTime t0 = fixedEpoch;

    test('★ criterion 1: 5 declared / 2 arrived, quiet for 30 s → 0 (no guess)',
        () {
      expect(
        missingFolderFiles(
          declaredCount: 5,
          arrivedCount: 2,
          lastActivityAt: t0,
          now: t0.add(const Duration(seconds: 30)),
        ),
        0,
        reason: 'the peer may still be sending; 30 s of silence proves nothing',
      );
    });

    test('★ criterion 2: the same rows at 200 s quiet → 3', () {
      expect(
        missingFolderFiles(
          declaredCount: 5,
          arrivedCount: 2,
          lastActivityAt: t0,
          now: t0.add(const Duration(seconds: 200)),
        ),
        3,
        reason: 'declared - arrived, and now it is provable',
      );
    });

    test('★ criterion 3: 5 declared / 5 arrived → 0 at any age', () {
      expect(
        missingFolderFiles(
          declaredCount: 5,
          arrivedCount: 5,
          lastActivityAt: t0,
          now: t0.add(const Duration(hours: 9)),
        ),
        0,
        reason: 'a complete folder is complete however long it has been quiet',
      );
      expect(
        missingFolderFiles(
          declaredCount: 5,
          arrivedCount: 7,
          lastActivityAt: t0,
          now: t0.add(const Duration(hours: 9)),
        ),
        0,
        reason: 'more rows than declared is not "minus two"',
      );
    });

    test('★ the boundary is strictly greater than 90 s', () {
      int missingAfter(int seconds) => missingFolderFiles(
            declaredCount: 5,
            arrivedCount: 2,
            lastActivityAt: t0,
            now: t0.add(Duration(seconds: seconds)),
          );

      expect(missingAfter(89), 0);
      expect(missingAfter(90), 0,
          reason: 'exactly kFolderQuietPeriod is still "not yet"');
      expect(missingAfter(91), 3);
      expect(kFolderQuietPeriod, const Duration(seconds: 90));
    });

    test('★ criterion 4: no folder descriptor → 0 (a flat send is not a folder)',
        () {
      expect(
        missingFolderFiles(
          declaredCount: 0,
          arrivedCount: 2,
          lastActivityAt: t0,
          now: t0.add(const Duration(hours: 1)),
        ),
        0,
      );
      expect(
        missingFolderFiles(
          declaredCount: -1,
          arrivedCount: 2,
          lastActivityAt: t0,
          now: t0.add(const Duration(hours: 1)),
        ),
        0,
      );
    });

    test('unknown activity, or a clock that stepped backwards → 0 (claim nothing)',
        () {
      expect(
        missingFolderFiles(
          declaredCount: 5,
          arrivedCount: 2,
          lastActivityAt: null,
          now: t0.add(const Duration(hours: 1)),
        ),
        0,
        reason: 'no row, no conclusion — never invent missing files',
      );
      expect(
        missingFolderFiles(
          declaredCount: 5,
          arrivedCount: 2,
          lastActivityAt: t0,
          now: t0.subtract(const Duration(seconds: 5)),
        ),
        0,
        reason: 'a negative quiet period is not "stalled for -5 seconds"',
      );
    });

    test('a folder that keeps arriving is never counted as stalled', () {
      // 200 s of total elapsed time, but only 10 s since the last file landed.
      expect(
        missingFolderFiles(
          declaredCount: 5,
          arrivedCount: 2,
          lastActivityAt: t0.add(const Duration(seconds: 190)),
          now: t0.add(const Duration(seconds: 200)),
        ),
        0,
      );
    });
  });

  // ── the fake's bookkeeping (so a fake-driven green means something) ─────
  group('FakeSessionRepository.lastActivityAt', () {
    IncomingFile file(String id) => IncomingFile(
          fileId: id,
          fileName: '$id.bin',
          size: 1024,
          sha256: 'AA',
          savedPath: '/received/$id.bin',
          relativePath: 'data/$id.bin',
        );

    test('a seeded message answers with its created_at', () {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      _seedFolder(backend, declared: 2, arrived: 1);

      expect(backend.repo.lastActivityAt(_messageId), fixedEpoch);
      expect(backend.repo.lastActivityAt('no-such-message'), isNull);
    });

    test('★ every new arrival of a folder moves the activity forward', () {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);

      final first = backend.repo.recordIncomingFolderFile(
        sender: _sender,
        file: file('a1'),
        sessionId: _sessionId,
        folderName: _folderName,
        folderFiles: 2,
      );
      expect(backend.repo.lastActivityAt(first.messageId), fixedEpoch);

      backend.clock.advance(const Duration(seconds: 40));
      backend.repo.recordIncomingFolderFile(
        sender: _sender,
        file: file('a2'),
        sessionId: _sessionId,
        folderName: _folderName,
        folderFiles: 2,
      );
      expect(
        backend.repo.lastActivityAt(first.messageId),
        fixedEpoch.add(const Duration(seconds: 40)),
        reason: 'the second file is activity — the quiet window restarts',
      );

      // A **re-delivered** file is not: the store's `insertIfAbsent` writes
      // nothing, so a peer re-offering the same bytes must not look alive.
      backend.clock.advance(const Duration(seconds: 40));
      backend.repo.recordIncomingFolderFile(
        sender: _sender,
        file: file('a1'),
        sessionId: _sessionId,
        folderName: _folderName,
        folderFiles: 2,
      );
      expect(
        backend.repo.lastActivityAt(first.messageId),
        fixedEpoch.add(const Duration(seconds: 40)),
        reason: 'a duplicate arrival changes no row, so it changes no activity',
      );
    });

    test('★ transfer-level writes move it too (the live heartbeat)', () {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      _seedFolder(backend, declared: 2, arrived: 1);

      backend.clock.advance(const Duration(seconds: 30));
      backend.repo.markTransferProgress(fileId: 'f-0', bytesDone: 512);
      expect(
        backend.repo.lastActivityAt(_messageId),
        fixedEpoch.add(const Duration(seconds: 30)),
      );

      backend.clock.advance(const Duration(seconds: 30));
      backend.repo.attachSession(fileId: 'f-0', sessionId: 's', token: 't');
      expect(
        backend.repo.lastActivityAt(_messageId),
        fixedEpoch.add(const Duration(seconds: 60)),
      );
    });

    test('a deleted message has no activity (and no stale entry)', () {
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      _seedFolder(backend, declared: 2, arrived: 1);

      expect(backend.repo.deleteMessage(_messageId), isTrue);
      expect(backend.repo.lastActivityAt(_messageId), isNull);
    });
  });

  // ── the card, end to end ───────────────────────────────────────────────
  group('the folder card', () {
    testWidgets(
        '★ criterion 1: 5 declared / 2 arrived, 30 s quiet → the line does NOT '
        'appear', (WidgetTester tester) async {
      await _pumpFolder(
        tester,
        declared: 5,
        arrived: 2,
        nowUtc: fixedEpoch.add(const Duration(seconds: 30)),
      );

      // The card is there and says how far it got…
      expect(find.text(_folderName), findsOneWidget);
      expect(find.text('已收到 2/5'), findsOneWidget);
      // …but it must NOT claim anything is missing: the peer may still be
      // sending, and 「3 个未收到」 would then be a lie a later file disproves.
      expect(find.textContaining('未收到'), findsNothing);
    });

    testWidgets(
        '★ criterion 2: the same data, 200 s quiet → 「3 个未收到」 IS drawn',
        (WidgetTester tester) async {
      await _pumpFolder(
        tester,
        declared: 5,
        arrived: 2,
        nowUtc: fixedEpoch.add(const Duration(seconds: 200)),
      );

      expect(find.text('已收到 2/5'), findsOneWidget);
      expect(find.text(_line(3)), findsOneWidget,
          reason: '5 declared - 2 arrived, provable after 200 s of silence');
    });

    testWidgets(
        '★ the LAST arrival decides, not the message age: three files arrived, '
        'the third one 10 s ago → no line', (WidgetTester tester) async {
      // The message is as old as in criterion 2 (200 s), but the peer uploaded
      // 10 s ago — so nothing is missing yet.
      final FakeBackend backend = await _backendFilledByArrivals(
        declared: 5,
        arrived: 3,
        quietFor: const Duration(seconds: 10),
      );
      await _mountThread(tester, backend);

      expect(find.text('已收到 3/5'), findsOneWidget);
      expect(find.textContaining('未收到'), findsNothing);
    });

    testWidgets(
        '★ …and the same three arrivals, silent for 210 s, DO report 「2 个未收到」',
        (WidgetTester tester) async {
      final FakeBackend backend = await _backendFilledByArrivals(
        declared: 5,
        arrived: 3,
        quietFor: const Duration(seconds: 210),
      );
      await _mountThread(tester, backend);

      expect(find.text('已收到 3/5'), findsOneWidget);
      expect(find.text(_line(2)), findsOneWidget);
    });

    testWidgets(
        '★ criterion 3: 5 declared / 5 arrived → no line, however long it has '
        'been quiet', (WidgetTester tester) async {
      await _pumpFolder(
        tester,
        declared: 5,
        arrived: 5,
        nowUtc: fixedEpoch.add(const Duration(minutes: 10)),
      );

      // `fileSizeText` keeps one decimal below 10 units, hence `5.0 MB`.
      expect(find.text('5.0 MB · 5 个文件'), findsOneWidget);
      expect(find.textContaining('已收到'), findsNothing,
          reason: 'a complete folder does not even print the count');
      expect(find.textContaining('未收到'), findsNothing);
    });

    testWidgets(
        '★ criterion 4: a FLAT message that declares nothing never grows the '
        'line, even when old and quiet', (WidgetTester tester) async {
      // 0.2.52 narrowed this case rather than removing it: a flat **multi-select
      // batch** now carries a declared count of its own (`folder_files` with
      // `folder_name` NULL) and is judged by the same rule — see
      // `batch_missing_files_test.dart`. What is still impossible is judging a
      // message that declared **nothing** (`folderFiles == 0`: a single-file send
      // or a pre-0.2.52 row): there is no count to subtract from.
      await _pumpFolder(
        tester,
        declared: 2,
        arrived: 2,
        nowUtc: fixedEpoch.add(const Duration(hours: 2)),
        flatToo: true,
      );

      // The flat bubble is still a pile of rows, and it declared no count — so
      // 「N 个未收到」 cannot appear there.
      expect(find.text('loose_0.pdf'), findsOneWidget);
      expect(find.textContaining('未收到'), findsNothing);
    });

    testWidgets(
        'the clock is injectable: the thread\'s own clock decides, not the '
        'container\'s', (WidgetTester tester) async {
      // The container's clock says "just now" — which alone would draw nothing —
      // while the thread is handed a **later** instant. The injected clock is what
      // the rule reads (`ConversationThread.clock`).
      await _pumpFolder(
        tester,
        declared: 5,
        arrived: 2,
        nowUtc: fixedEpoch,
        clock: FixedClock(fixedEpoch.add(const Duration(seconds: 200))),
      );

      expect(find.text(_line(3)), findsOneWidget);
    });
  });
}
