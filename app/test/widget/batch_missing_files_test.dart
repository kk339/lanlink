/// 「N 个未收到」 for a **flat multi-select batch** (0.2.52).
///
/// 0.2.51 folded a multi-select into **one** message: the sender already encodes
/// "8 files selected" as one `prepare` carrying 8 files, so the receiver was
/// right to draw one bubble. But it also made a lost file **invisible**: the
/// batch's row carried no declared count (`folder_files` NULL), the thread only
/// computed the shortfall for `message.isFolder`, and every inbound message is
/// stamped `done`. So "8 selected, 3 arrived" looked *exactly* like "3
/// selected" — before 0.2.51 the user could count five missing bubbles.
///
/// The count was never missing from the wire: every `ReceivedFile` of a
/// `prepare` knows how many files that `prepare` declared
/// (`session.files.length`, `peer_server.dart`). These tests are the four
/// shapes that must now differ:
///
/// 1. 8 declared / 3 arrived / 120 s silent → 「5 个未收到」, and the message is
///    still **not** a folder (no card, no directory page);
/// 2. the same rows at 30 s → **no line** (the peer may still be sending);
/// 3. 8 declared / 8 arrived → no line, however quiet;
/// 4. a **single-file** send declares nothing, so it can never grow the line.
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

const String _conversationId = 'c-batch-missing';
const String _sessionId = 'batch-s-1';
const String _singleFileSessionId = 'single-s-1';

/// The sentence the UI prints, for [count] files.
String _line(int count) => '$count 个未收到';

const PeerDevice _sender = PeerDevice(
  fingerprint: 'CC01',
  alias: '小甲',
  kind: DeviceKind.desktop,
  isOnline: true,
  lastPort: 53317,
);

PeerDevice _peer() => _sender;

/// One arriving file of a batch: flat (no `relativePath`, no folder), 1 MiB.
IncomingFile _arriving(int index) => IncomingFile(
      fileId: 'b-$index',
      fileName: 'clip_$index.mp4',
      size: 1024 * 1024,
      sha256: 'AA',
      savedPath: '/downloads/lanlink/clip_$index.mp4',
    );

/// A backend whose batch message was filled by **real arrivals**: [arrived]
/// files of [declared], the last one landing [quietFor] before the backend's
/// clock stops.
///
/// The rows go through `recordIncomingSessionFile` — the path production uses
/// (`transfer_orchestrator.dart`) — so the activity instant comes from the fake
/// write path, not from a seeded `created_at`, exactly as in
/// `folder_missing_files_test.dart`.
FakeBackend _batchFilledByArrivals({
  required int declared,
  required int arrived,
  required Duration quietFor,
}) {
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
    backend.repo.recordIncomingSessionFile(
      sender: _sender,
      file: _arriving(i),
      sessionId: _sessionId,
      folderFiles: declared,
    );
  }
  backend.clock.advance(quietFor);
  return backend;
}

/// Mounts the thread over [backend] and answers the controller, so a test can
/// assert the message's *shape* (`isFolder`) and not only its pixels.
Future<ConversationController> _mountThread(
  WidgetTester tester,
  FakeBackend backend,
) async {
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
  unawaited(controller.load());
  await tester.pumpWidget(
    appWithScope(
      child: MaterialApp(
        home: Scaffold(
          body: ConversationThread(
            controller: controller,
            peer: _peer(),
          ),
        ),
      ),
      deps: testDeps(backend),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets(
      '★ criterion 1: 8 declared / 3 arrived, 120 s silent → 「5 个未收到」, '
      'and the message is NOT a folder', (WidgetTester tester) async {
    final FakeBackend backend = _batchFilledByArrivals(
      declared: 8,
      arrived: 3,
      quietFor: const Duration(seconds: 120),
    );
    final ConversationController controller = await _mountThread(tester, backend);

    // The three files that did arrive are on screen, as ordinary attachment
    // rows (a batch is not a folder: no card, no 已收到 x/y, no directory page).
    expect(find.text('clip_0.mp4'), findsOneWidget);
    expect(find.text('clip_2.mp4'), findsOneWidget);
    expect(find.textContaining('已收到'), findsNothing,
        reason: 'a flat batch draws rows, never a folder card');

    // …and the shortfall is now visible instead of being absorbed by the fold.
    expect(find.text(_line(5)), findsOneWidget,
        reason: '8 declared - 3 arrived, provable after 120 s of silence');

    // The shape is still a plain multi-attachment message: `folder_name` NULL,
    // `isFolder` false, so nothing grew a folder card or a directory entry.
    final ChatMessage message = controller.messages.valueOrNull!.single;
    expect(message.isFolder, isFalse);
    expect(message.folderName, isNull);
    expect(message.folderFiles, 8,
        reason: 'the declared count is stored, the descriptor is not');
  });

  testWidgets(
      '★ criterion 2: the same rows, only 30 s silent → the line does NOT '
      'appear', (WidgetTester tester) async {
    final FakeBackend backend = _batchFilledByArrivals(
      declared: 8,
      arrived: 3,
      quietFor: const Duration(seconds: 30),
    );
    await _mountThread(tester, backend);

    // The peer may still be uploading files 4…8; saying 「5 个未收到」 here would
    // be a lie that the next arrival disproves.
    expect(find.textContaining('未收到'), findsNothing);
  });

  testWidgets(
      '★ criterion 3: 8 declared / 8 arrived → no line, however quiet',
      (WidgetTester tester) async {
    final FakeBackend backend = _batchFilledByArrivals(
      declared: 8,
      arrived: 8,
      quietFor: const Duration(minutes: 10),
    );
    await _mountThread(tester, backend);

    expect(find.text('clip_7.mp4'), findsOneWidget);
    expect(find.textContaining('未收到'), findsNothing,
        reason: 'a complete batch is complete however long it has been quiet');
  });

  testWidgets(
      '★ criterion 5: a single-file send declares nothing → no line, ever',
      (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend(now: fixedEpoch);
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: _conversationId,
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    // One file, one prepare: `core` fills `folderFiles` 0 for a one-file
    // session, so nothing is declared and nothing can be missing.
    backend.repo.recordIncomingSessionFile(
      sender: _sender,
      file: _arriving(0),
      sessionId: _singleFileSessionId,
    );
    backend.clock.advance(const Duration(hours: 2));

    final ConversationController controller = await _mountThread(tester, backend);

    expect(find.text('clip_0.mp4'), findsOneWidget);
    expect(find.textContaining('未收到'), findsNothing);

    final ChatMessage message = controller.messages.valueOrNull!.single;
    expect(message.folderFiles, 0,
        reason: '`folder_files` stays NULL for a single file send');
  });
}
