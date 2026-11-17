/// **A batch of N files must not cost N × (the whole conversation)** (0.2.50).
///
/// The report: *多选发送 30–80 个文件给电脑，电脑端明显卡顿*. The root cause was not
/// Flutter's frame budget but the **shape of the work per arrival**:
/// `ConversationThread._probeSources` re-walked **every message of the
/// conversation**, called `filesOf` for each of them and stat'ed every one of
/// their attachment paths — once per arriving file. With K messages already in
/// the thread and N files arriving, that is O(N × (K + N)) `exists` calls: the
/// batch is quadratic in its own size.
///
/// This file pins the **counts**, not the timings. Durations on this machine
/// swing by 2× between runs and are therefore not a judge; a call count is
/// exact and cannot be fooled by a fast machine.
///
/// The four criteria, in the order the tests appear:
///
/// 1. `exists` calls over one batch are **O(N + K)**: entering the thread probes
///    the K historical attachments once, and each arriving file adds exactly
///    one — 10 / 40 / 80 arrivals all grow **linearly**;
/// 2. entering the thread still probes the history (the first visit must be
///    right — a cache that skipped it would report 「no file is missing」 for
///    ever);
/// 3. a file that arrives **now** still gets its disk answer **now** — the
///    incremental probe must not swallow a new attachment (that would show a
///    missing file as available, the opposite failure);
/// 4. what the fix must not break: the old numbers are the *red* evidence for
///    (1) — before the fix, the same 80 arrivals over 40 history messages cost
///    ~6 440 `exists` calls instead of 120.
///
/// "The 80 messages of `_batch` are one attachment each", and that is now a
/// **deliberate fixture**, not a description of production (0.2.51 changed it:
/// a multi-select arriving through the orchestrator is one message with N
/// attachments, because one `prepare` = one session = one bubble). This file
/// drives `SessionRepository.recordIncoming` directly — the port that is still
/// exactly "one file, one message" — so the thing being measured stays the same
/// shape it has always measured: **N separate arrivals, each one a new row**,
/// which is the worst case for `_probeSources` (it is the folder/batch case that
/// got cheaper, not this one). The per-arrival cost pinned here — one `exists`
/// per new path, never a re-walk — is what an append on the aggregated path pays
/// too, so the bound still guards 0.2.51's growing bubble.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/bootstrap/app_deps.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/data/fake/fake_platform_ports.dart';
import 'package:lanlink_app/data/fake/fake_session_repository.dart';
import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/id_factory.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/platform_ports.dart';
import 'package:lanlink_app/domain/session_repository.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

const String _conv = 'c-batch';
const String _fingerprint = 'BA7C';

/// The row text a bubble prints when its attachment is not on disk.
const String _kUnavailable = '源文件不可用';

/// How many messages the thread already holds when the batch starts — the `K`
/// of O(N + K). 40 is the user's own floor (`30–80 个文件`), so the numbers below
/// are about the reported batch and not about a toy fixture.
const int _kHistory = 40;

/// A `PlatformPorts` that **counts** its existence probes.
///
/// `exists` is the only disk read the availability probe makes, so its call
/// count *is* the cost of `_probeSources` — the number this whole file exists to
/// bound. Everything else is inherited from [FakePlatformPorts] unchanged.
class _CountingPlatform extends FakePlatformPorts {
  _CountingPlatform({super.settings});

  /// How many times [exists] has been called since the last [resetCounts].
  int existsCalls = 0;

  /// The paths [exists] was asked about, in order — read when a count alone
  /// cannot say *what* was probed (criterion 3's "the new file was probed").
  final List<String> existsPaths = <String>[];

  void resetCounts() {
    existsCalls = 0;
    existsPaths.clear();
  }

  @override
  Future<bool> exists(String path) {
    existsCalls++;
    existsPaths.add(path);
    return super.exists(path);
  }
}

/// A [SessionRepository] that counts the two reads the probe makes.
///
/// `filesOf` is what the old `_probeSources` called **once per message per
/// arrival**; `history` is what the controller (and the recent-files page) read.
/// Both are counted so the same run can report both halves of the fix.
class _CountingRepo extends FakeSessionRepository {
  _CountingRepo({required super.clock, required super.ids});

  int filesOfCalls = 0;

  void resetCounts() {
    filesOfCalls = 0;
  }

  @override
  List<FileAttachment> filesOf(String messageId) {
    filesOfCalls++;
    return super.filesOf(messageId);
  }
}

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Owns one `ConversationController` for the length of one test — the same
/// ownership `DetailPane` has in production, so the controller's 1 Hz progress
/// ticker is cancelled by `dispose` **before** `flutter_test` checks for
/// leftover timers.
class _BatchHost extends StatefulWidget {
  const _BatchHost({
    required this.repo,
    required this.transfer,
    required this.platform,
    required this.clock,
    required this.ids,
  });

  final SessionRepository repo;
  final TransferService transfer;
  final PlatformPorts platform;
  final Clock clock;
  final IdFactory ids;

  @override
  State<_BatchHost> createState() => _BatchHostState();
}

class _BatchHostState extends State<_BatchHost> {
  late final ConversationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConversationController(
      repo: widget.repo,
      orchestrator: TransferOrchestrator(
        repo: widget.repo,
        transfer: widget.transfer,
      ),
      platform: widget.platform,
      ids: widget.ids,
      clock: widget.clock,
      conversationId: _conv,
      drafts: ComposerDraftStore(),
    );
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ConversationThread(controller: _controller, peer: _peer()),
      );
}

/// One mounted thread over a fresh counting fake pair.
class _Harness {
  _Harness({
    required this.backend,
    required this.repo,
    required this.platform,
  });

  final FakeBackend backend;
  final _CountingRepo repo;
  final _CountingPlatform platform;

  /// Total `exists` calls observed over the whole test, for the printed report.
  int get existsCalls => platform.existsCalls;
}

/// Seeds K history messages (one attachment each, all present on disk), mounts
/// the timeline and lets the first fill settle.
///
/// Returns the harness with the counts **already reset**, so whatever a test
/// measures is `arrivals only` — the history probe is counted by
/// [_pumpThread] itself and asserted by the caller that cares (criterion 2).
Future<_Harness> _pumpThread(
  WidgetTester tester, {
  int history = _kHistory,
  List<String> missing = const <String>[],
}) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);

  final _CountingPlatform platform =
      _CountingPlatform(settings: backend.platform.presetSettings);
  final _CountingRepo repo =
      _CountingRepo(clock: backend.clock, ids: backend.ids);

  // Seeded through the **counting** repository: it is the one the thread and its
  // controller read (`AppDeps.repo`), so `filesOf` is counted on every path.
  repo.addConversation(
    id: _conv,
    deviceFingerprint: _fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  for (int i = 0; i < history; i++) {
    final String path = _historyPath(i);
    repo.addMessage(
      id: _historyId(i),
      conversationId: _conv,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[_file(_historyId(i), i, path)],
    );
  }
  for (final String path in missing) {
    platform.setExists(path, false);
  }

  await tester.pumpWidget(
    appWithScope(
      deps: AppDeps(
        repo: repo,
        discovery: backend.discovery,
        transfer: backend.transfer,
        platform: platform,
        clock: backend.clock,
        ids: backend.ids,
        config: testAppConfig,
      ),
      child: _BatchHost(
        repo: repo,
        transfer: backend.transfer,
        platform: platform,
        clock: backend.clock,
        ids: backend.ids,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(backend: backend, repo: repo, platform: platform);
}

String _historyId(int i) => 'hist-$i';
String _historyPath(int i) => r'C:\incoming\hist-' '$i.bin';
String _batchId(int i) => 'batch-$i';
String _batchPath(int i) => r'C:\incoming\batch-' '$i.bin';

FileAttachment _file(String messageId, int index, String path) => FileAttachment(
      id: 'f-$messageId',
      messageId: messageId,
      fileName: 'file-$index.bin',
      size: 1024,
      sha256: 'AA',
      localPath: path,
    );

/// Delivers [count] arriving files, **one message each**, and lets the thread
/// react to every one of them (that "react" is the code under measurement).
///
/// The arrival goes through [SessionRepository.recordIncoming], which is the
/// only path that both writes the row **and** emits `MessageAdded` — the seeding
/// helper `addMessage` deliberately emits nothing, so driving the batch with it
/// would measure a thread that is never told anything (and "0 probes" would look
/// like success).
///
/// Two pumps per arrival: the first delivers the repository event to the
/// controller, the second lets the probe's `await platform.exists` and its
/// `setState` land.
Future<void> _arrive(WidgetTester tester, _Harness harness, int count) async {
  for (int i = 0; i < count; i++) {
    harness.repo.recordIncoming(
      sender: _peer(),
      file: IncomingFile(
        fileId: _batchId(i),
        fileName: 'file-$i.bin',
        size: 1024,
        sha256: 'AA',
        savedPath: _batchPath(i),
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

void main() {
  // ── criterion 1 + 5: the count is linear in the batch size ─────────────────
  for (final int n in <int>[10, 40, 80]) {
    testWidgets(
        '★ criterion 1: $n arriving files over $_kHistory history messages cost '
        'exactly ${_kHistory + n} existence probes (O(N + K), not O(N×(K+N)))',
        (WidgetTester tester) async {
      final _Harness harness = await _pumpThread(tester);

      // Criterion 2 first (the first visit does probe history): the mount spent
      // exactly one probe per historical path.
      expect(
        harness.platform.existsCalls,
        _kHistory,
        reason: 'entering the thread must probe each historical attachment once '
            '— a cache that starts "everything is fine" would leave every old '
            'row clickable and wrong',
      );
      harness.platform.resetCounts();
      harness.repo.resetCounts();

      await _arrive(tester, harness, n);

      // What the fix is worth, printed so the report can quote real numbers
      // instead of a claim.
      // ignore: avoid_print
      print('ARRIVALS n=$n over K=$_kHistory: exists=${harness.existsCalls} '
          '(re-walking the whole conversation would be '
          '${n * _kHistory + n * (n + 1) ~/ 2}), '
          'filesOf=${harness.repo.filesOfCalls}');

      expect(
        harness.existsCalls,
        n,
        reason: 'each arriving file is probed exactly once, and **only** it: '
            'the K history paths were already answered on mount. '
            '${n * (_kHistory + n)}-ish calls would mean the whole conversation '
            'is re-walked per file — the reported 卡顿',
      );
    });
  }

  // ── criterion 3: a new attachment is still judged when it arrives ──────────
  testWidgets(
      '★ criterion 3: a file that arrives **now** still gets its disk answer '
      'now — an incremental probe must not swallow the new path',
      (WidgetTester tester) async {
    const String missingPath = r'C:\incoming\batch-0.bin';
    final _Harness harness = await _pumpThread(
      tester,
      history: 3,
      missing: <String>[missingPath],
    );
    harness.platform.resetCounts();

    // One arrival whose file is **not** on disk: the row must dim to
    // 「源文件不可用」 on the same frames that follow, which can only happen if
    // the probe actually asked about this path.
    await _arrive(tester, harness, 1);

    expect(harness.platform.existsPaths, contains(missingPath),
        reason: 'the arriving attachment is the one thing the probe must ask '
            'about — skipping it is the silent half of the same bug');
    expect(find.text(_kUnavailable), findsOneWidget,
        reason: 'and the answer must reach the row: a missing file that looks '
            'available is the failure mode of "only probe once"');
  });

  // ── criterion 3b: an arrival that IS there must not be accused ─────────────
  testWidgets(
      '★ criterion 3b: an arriving file that is on disk shows no warning',
      (WidgetTester tester) async {
    final _Harness harness = await _pumpThread(tester, history: 3);
    harness.platform.resetCounts();

    await _arrive(tester, harness, 4);

    expect(find.text(_kUnavailable), findsNothing,
        reason: 'the probe must not turn a present file into a greyed row');
    expect(harness.platform.existsCalls, 4,
        reason: 'four arrivals, four probes — no more, no fewer (the mount\'s '
            'three history probes were reset above)');
  });

  // ── an arrival with nothing to judge costs nothing ─────────────────────────
  testWidgets(
      '★ a text message arriving mid-batch costs zero probes',
      (WidgetTester tester) async {
    final _Harness harness = await _pumpThread(tester, history: 2);
    await _arrive(tester, harness, 1);
    harness.platform.resetCounts();

    // A text message changes the message **count** (so the probe does run) but
    // carries no attachment: there is nothing new to ask the disk about, and
    // asking about the conversation again would be the same O(history) sweep
    // under a different name.
    harness.repo.recordIncomingText(
      sender: _peer(),
      text: '一条文字',
      nonce: 'text-1',
    );
    await tester.pump();
    await tester.pump();

    expect(harness.platform.existsCalls, 0,
        reason: 'nothing new to judge ⇒ no stat at all');
  });
}
