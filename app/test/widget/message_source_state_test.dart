/// **「文件没了」 and 「这是我们自己删的」 are two different things** (0.2.49).
///
/// The user, on an Android phone:
///
/// > 手机现在发送成功后，已完成旁边却会显示离线的那个红色图标，下面还有重新发送。
/// > 但实际上已经传输好了。
///
/// Root cause — a **semantics** bug, not a rendering one. 0.2.48 handed the bubble
/// one bool, `sourceUnavailable: _sources.anyUnavailable(files)`, and let it drive
/// three places at once (the red marker, the row's 「源文件不可用」, the thumbnail).
/// On Android a picked or shared file is a **cache copy**
/// (`cache/lanlink-picked/<uuid>/…`) that `ConversationController._discardPickedCopies`
/// deletes the moment the send succeeds — so for **every** file that arrived:
///
/// ```
/// 发送成功 → 副本被清理 → anyUnavailable == true
///         → 红 link_off 图标 + 灰掉的「重新发送」 + 行里「源文件不可用」
/// ```
///
/// i.e. **normal cleanup was being read as file loss**.
///
/// ## The rule this file pins: ask *who* removed the file, not what status it has
///
/// The tempting fix is "outgoing + `done` → say nothing", and it is **wrong**: it
/// also silences the desktop case where the user deletes or moves *their own*
/// source file after sending — a real loss. A `done` message can be either state;
/// status is not the answer to "who deleted this?". What is:
///
/// | who removed it | example | 源文件不可用 / red icon | 重新发送 |
/// |---|---|---|---|
/// | **we did** (post-send cache cleanup) | Android, every delivered file | **no** | **no** |
/// | **someone else did** | desktop: the source was deleted/moved | yes | **no button on `done`**; greyed on `failed` / `canceled` |
///
/// The last cell is 0.2.49 too, and it is the second thing this file pins: a
/// `done` row offers **no** 重新发送, not even a grey one — `canResend` refuses
/// anything that is not `failed` / `canceled`, so that button could only ever be
/// pressed zero times. (`drag_out_test` used to assert the grey button existed; that
/// assertion was over-specified — its real subject was "the mark survives a tab
/// switch".)
///
/// **The rule this round taught, and it is worth keeping at the top of the file:**
///
/// > 测试可以钉住"我已经决定的"，不能决定"我该决定什么"。
/// > 当一条断言逼着我加一个永远点不动的控件时，该改的是断言。
///
/// Two kinds of evidence, and both are exercised below:
///
/// 1. the cleanup **records the paths it deleted** — `discardedByUs` (test
///    `★ the record`, and the end-to-end widget case that sends a real file);
/// 2. after a **restart** that record is empty, so a path under `lanlink-picked/`
///    that is gone from a *delivered* message is inferred to be ours (test
///    `★ post-restart`) — without this the red icon would come back on every
///    launch, which is the user's complaint all over again.
///
/// What cannot be checked here: a real Android device. The widget tree runs with
/// the phone flag on (same code path), and `picked_cache_after_send_test` pins the
/// controller half (the deleter only runs on success).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/pump_app.dart';

const String _conv = 'c-src-state';
const String _fingerprint = 'EE21';

/// The shape Android really leaves behind: a per-send directory under the app
/// cache, deleted by `_discardPickedCopies` as soon as the transfer succeeds.
const String _pickedCopy =
    '/data/user/0/io.github.kk339.lanlink/cache/lanlink-picked/8f2c/picked-copy.bin';

/// The same copy after a restart — the record is empty, the path still says whose
/// it was.
const String _pickedCopyVideo =
    '/data/user/0/io.github.kk339.lanlink/cache/lanlink-picked/1a7d/clip.mp4';

/// A file that was **never ours**: the desktop picks in place, so this is the
/// user's own document. If it disappears, *they* lost it.
const String _userSource = r'C:\Users\k\Desktop\report.pdf';

/// The same, on a phone-shaped path that is still not a cache copy of ours.
const String _userSourceMobile = '/storage/emulated/0/Download/notes.bin';

/// What an outgoing row says when its source is missing **and that is news**.
const String _kUnavailable = '源文件不可用';

/// The action that must never appear for a file **we** cleaned up.
const String _kResend = '重新发送';

/// What a tap on a missing row answers — the "不静默" half of criterion 4.
const String _kTapNotice = '文件已不在原位置，无法打开';

/// The status chip's label for `done`.
const String _kDone = '已完成';

/// 2048 bytes — the size line `FileTile` replaces with [_kUnavailable].
const String _kSize = '2.0 KB';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Owns one `ConversationController` for the length of one test — **the same
/// ownership `DetailPane` has in production**, and the reason this exists rather
/// than an `addTearDown(controller.dispose)`:
///
/// `flutter_test` requires that no timer outlives the test body, and the
/// controller's 1 Hz progress ticker is a timer. A tear-down runs *after* that
/// check; a `State.dispose` runs when the tree is torn down at the end of the
/// body, i.e. **before** it.
class _ThreadHost extends StatefulWidget {
  const _ThreadHost({
    required this.backend,
    required this.peer,
    this.onController,
  });

  final FakeBackend backend;
  final PeerDevice peer;

  /// Hands the controller to the test, so a case can drive a **real send** (the
  /// only way the cleanup record is written).
  final void Function(ConversationController controller)? onController;

  @override
  State<_ThreadHost> createState() => _ThreadHostState();
}

class _ThreadHostState extends State<_ThreadHost> {
  late final ConversationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConversationController(
      repo: widget.backend.repo,
      orchestrator: TransferOrchestrator(
        repo: widget.backend.repo,
        transfer: widget.backend.transfer,
      ),
      platform: widget.backend.platform,
      ids: widget.backend.ids,
      clock: widget.backend.clock,
      conversationId: _conv,
      drafts: ComposerDraftStore(),
    );
    unawaited(_controller.load());
    widget.onController?.call(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: ConversationThread(controller: _controller, peer: widget.peer));
}

/// Mounts the timeline on one conversation, optionally holding one file message.
///
/// [mobile] `true` is the surface the defect was reported on; it is not cosmetic,
/// because the phone draws its status/actions in the bubble's footer while the
/// desktop draws them in a row **below** the card.
///
/// [fileOnDisk] `false` is the state under test — the attachment still points at
/// its `localPath`, and nothing is there.
///
/// [alsoAttached] adds further attachments to the **same message** (each also
/// reported missing), which is what the "one file of ours, one file of the user's"
/// case needs: the verdict is message-level, so any non-routine loss has to win.
Future<FakeBackend> _pump(
  WidgetTester tester, {
  String path = _pickedCopy,
  String fileName = 'picked-copy.bin',
  MessageDirection direction = MessageDirection.outgoing,
  MessageStatus status = MessageStatus.done,
  bool fileOnDisk = false,
  bool seedMessage = true,
  bool mobile = true,
  List<(String path, String fileName)> alsoAttached =
      const <(String, String)>[],
  void Function(ConversationController controller)? onController,
}) async {
  useSurfaceSize(tester, mobile ? const Size(600, 1200) : const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setMobile(mobile);
  backend.platform.setExists(path, fileOnDisk);
  for (final (String gone, String _) in alsoAttached) {
    backend.platform.setExists(gone, false);
  }
  backend.repo.addConversation(
    id: _conv,
    deviceFingerprint: _fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  if (seedMessage) {
    backend.repo.addMessage(
      id: 'm-1',
      conversationId: _conv,
      direction: direction,
      status: status,
      kind: MessageKind.file,
      files: <FileAttachment>[
        FileAttachment(
          id: 'f-1',
          messageId: 'm-1',
          fileName: fileName,
          size: 2048,
          sha256: 'AA',
          localPath: path,
        ),
        for (final (String otherPath, String otherName) in alsoAttached)
          FileAttachment(
            id: 'f-$otherName',
            messageId: 'm-1',
            fileName: otherName,
            size: 2048,
            sha256: 'BB',
            localPath: otherPath,
          ),
      ],
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
  }
  await pumpApp(
    tester,
    _ThreadHost(backend: backend, peer: _peer(), onController: onController),
    backend: backend,
    settle: true,
  );
  return backend;
}

/// The 重新发送 button as a widget, so its `onPressed` can be inspected.
TextButton _resendButton(WidgetTester tester) =>
    tester.widget<TextButton>(find.widgetWithText(TextButton, _kResend));

/// A [PickedCachePort] that records the calls it was asked to make (and deletes
/// nothing — the fake tree has no disk).
class _RecordingCache implements PickedCachePort {
  final List<List<String>> discarded = <List<String>>[];

  @override
  Future<void> discard(Iterable<String> paths) async =>
      discarded.add(paths.toList());

  @override
  Future<void> clear({Set<String> keep = const <String>{}}) async {}
}

void main() {
  // ── criterion 1: the success path that produced the report ──────────────────
  testWidgets(
      '★ criterion 1 (end to end): a delivered send deletes its own cache copy — '
      'NO red icon, NO 重新发送, a plain completed bubble',
      (WidgetTester tester) async {
    late ConversationController controller;
    final FakeBackend backend = await _pump(
      tester,
      // No seeded message: the send below creates it, exactly as the app does.
      seedMessage: false,
      onController: (ConversationController c) => controller = c,
    );
    // The copy is already gone when the send finishes, because the cleanup ran —
    // and the fake cache does not really delete anything, which is why the probe
    // finding it missing is what we assert on, not the deletion itself.
    backend.platform.setExists(_pickedCopy, false);

    await controller.sendPaths(peer: _peer(), paths: <String>[_pickedCopy]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // (a) the **record** this release adds: the controller knows it was us.
    expect(controller.discardedByUs(_pickedCopy), isTrue,
        reason: 'the send freed this path — that is direct evidence of who '
            'removed it, and it is what the bubble must consult');

    // (b) the reported bug, assertion by assertion.
    expect(find.byIcon(Icons.link_off), findsNothing,
        reason: 'the red broken-link icon beside 已完成 — the user\'s complaint');
    expect(find.text(_kResend), findsNothing,
        reason: 'and the greyed-out 重新发送 that came with it');
    expect(find.text(_kUnavailable), findsNothing,
        reason: 'nor the row-level 「源文件不可用」: the copy went *because* the '
            'send worked');

    // (c) …and it is not merely blank.
    expect(find.text(_kDone), findsOneWidget);
    final FileTile tile = tester.widget<FileTile>(find.byType(FileTile).first);
    expect(tile.unavailable, isFalse,
        reason: 'the row keeps its normal shape — name + size, not dimmed, not '
            '「源文件不可用」, and its own tap handler');
    expect(tile.onTap, isNotNull);
  });

  testWidgets(
      '★ criterion 1 (post-restart): the record is empty, the path still says the '
      'copy was ours — a delivered message stays silent',
      (WidgetTester tester) async {
    // Nothing is persisted, so this is exactly what the app looks like after being
    // killed and reopened: no record, a `done` message, a `lanlink-picked/` path
    // that no longer exists. If the record were the only evidence, every sent file
    // would go red again on every launch.
    await _pump(tester, path: _pickedCopy, fileOnDisk: false);

    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(find.text(_kResend), findsNothing);
    expect(find.text(_kUnavailable), findsNothing);
    expect(find.text(_kDone), findsOneWidget);
  });

  // ── criterion 3 / 5: the real loss that must keep being reported ────────────
  testWidgets(
      '★ criterion 3+5 (desktop): a `done` message whose **user-owned** source was '
      'deleted is STILL reported — this is the case the status-based rule silenced',
      (WidgetTester tester) async {
    await _pump(
      tester,
      path: _userSource,
      fileName: 'report.pdf',
      fileOnDisk: false,
      mobile: false,
    );

    expect(find.text(_kUnavailable), findsWidgets,
        reason: 'the desktop picked in place: that path is the user\'s own file, '
            'and its disappearance is a real loss — never "our cleanup"');
    expect(find.byIcon(Icons.link_off), findsOneWidget);
    expect(find.text(_kSize), findsNothing);

    // ★ 0.2.49 — **no button on a `done` row, not even a grey one.**
    // `ConversationController.canResend` refuses anything that is not `failed` /
    // `canceled`, so a 重新发送 here could only ever be pressed zero times: a dead
    // control, which this project deletes on sight (docs/18 §8.2). The loss is
    // already said twice — the red mark above and 「源文件不可用」 in the row.
    // (0.2.48 drew it; `drag_out_test` used to pin that, and that one assertion was
    // over-specified — it was really testing "the mark survives a tab switch".)
    expect(find.text(_kResend), findsNothing,
        reason: 'a delivered message offers no re-send it cannot perform');
  });

  // ── criterion 2: what the mark was built for ────────────────────────────────
  testWidgets(
      '★ criterion 2: outgoing `failed` + the source is gone → still marked, still '
      'offers a DISABLED 重新发送',
      (WidgetTester tester) async {
    await _pump(
      tester,
      path: _userSourceMobile,
      fileName: 'notes.bin',
      status: MessageStatus.failed,
      fileOnDisk: false,
    );

    expect(find.text(_kUnavailable), findsWidgets);
    expect(find.byIcon(Icons.link_off), findsOneWidget,
        reason: 'a failed send whose source is gone is exactly what the mark is for');
    expect(find.text(_kSize), findsNothing);
    expect(find.text(_kResend), findsOneWidget);
    expect(_resendButton(tester).onPressed, isNull);
  });

  // ── criterion 4: received + deleted ─────────────────────────────────────────
  testWidgets(
      '★ criterion 4: incoming + the received file was deleted → no 重新发送 (it never '
      'had one), the row still says so, and the tap answers instead of dying',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      path: _userSourceMobile,
      fileName: 'notes.bin',
      direction: MessageDirection.incoming,
      fileOnDisk: false,
    );

    expect(find.text(_kResend), findsNothing,
        reason: '入向 has nothing to re-send, before and after this change');
    expect(find.text(_kUnavailable), findsWidgets,
        reason: 'the received copy really is the only one the app holds — say so');
    expect(find.byIcon(Icons.link_off), findsOneWidget,
        reason: 'a received file that vanished is a loss too; only *our own* '
            'cleanup is exempt');

    await tester.tap(find.text('notes.bin'));
    await tester.pumpAndSettle();
    expect(find.text(_kTapNotice), findsOneWidget);
    expect(backend.platform.opened, isEmpty,
        reason: 'and it must not call the platform with a path we know is gone');

    await tester.pump(const Duration(seconds: 3));
  });

  // ── criterion 6: one verdict, three places ──────────────────────────────────
  testWidgets(
      '★ criterion 6a: a video whose copy WE cleaned up → thumbnail, row and marker '
      'all agree that nothing is wrong',
      (WidgetTester tester) async {
    await _pump(
      tester,
      path: _pickedCopyVideo,
      fileName: 'clip.mp4',
      fileOnDisk: false,
      mobile: true,
    );

    final FileThumbnail thumb =
        tester.widget<FileThumbnail>(find.byType(FileThumbnail).first);
    expect(thumb.unavailable, isFalse,
        reason: 'the thumbnail is the third reader of the same bool — leaving it '
            'on made a cleaned-up video fall back to a type icon');
    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(find.text(_kResend), findsNothing);
  });

  testWidgets(
      '★ criterion 6b: a video whose source someone ELSE removed → thumbnail, row '
      'and marker all agree that it is gone',
      (WidgetTester tester) async {
    await _pump(
      tester,
      path: r'C:\Users\k\Videos\clip.mp4',
      fileName: 'clip.mp4',
      fileOnDisk: false,
      mobile: false,
    );

    final FileThumbnail thumb =
        tester.widget<FileThumbnail>(find.byType(FileThumbnail).first);
    expect(thumb.unavailable, isTrue);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  // ── criterion 6 (new): a message may be *partly* our doing ──────────────────
  testWidgets(
      '★ criterion 6: one attachment we cleaned up + one the user lost → the message '
      'IS reported (any non-routine loss wins; the verdict is message-level)',
      (WidgetTester tester) async {
    await _pump(
      tester,
      // Our cache copy, freed by a delivered send…
      path: _pickedCopy,
      fileName: 'picked-copy.bin',
      // …plus the user's own file in the same message, deleted outside the app.
      alsoAttached: <(String, String)>[
        (_userSourceMobile, 'notes.bin'),
      ],
    );

    expect(find.text(_kUnavailable), findsWidgets,
        reason: 'the message owns a file that was genuinely lost; staying silent '
            'would hide it behind the one we cleaned up');
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  // ── the record itself, and the path predicate it is backed by ───────────────
  group('★ the record of what we deleted', () {
    late FakeBackend backend;
    late _RecordingCache cache;
    late ConversationController controller;

    setUp(() {
      backend = FakeBackend();
      cache = _RecordingCache();
      backend.platform.setExists(_userSource, true);
      final Conversation conversation = backend.repo.addConversation(
        id: 'c-record',
        deviceFingerprint: _fingerprint,
        createdAt: fixedEpoch,
      );
      controller = ConversationController(
        repo: backend.repo,
        orchestrator: TransferOrchestrator(
          repo: backend.repo,
          transfer: backend.transfer,
        ),
        platform: backend.platform,
        ids: backend.ids,
        clock: backend.clock,
        conversationId: conversation.id,
        pickedCache: cache,
      );
    });

    tearDown(() {
      controller.dispose();
      backend.dispose();
    });

    test('a delivered send records the paths it freed', () async {
      final SendOutcome? outcome =
          await controller.sendPaths(peer: _peer(), paths: <String>[_userSource]);

      expect(outcome!.delivered, isTrue);
      expect(cache.discarded, hasLength(1));
      // The **record**, not the path: `_userSource` is a desktop-looking path that
      // `isPickedCachePath` refuses, so only the evidence we wrote can answer this.
      expect(controller.discardedByUs(_userSource), isTrue);
      expect(isPickedCachePath(_userSource), isFalse,
          reason: 'the two mechanisms must be independent, or this test proves '
              'nothing about the record');
    });

    test('a FAILED send records nothing — we did not delete anything', () async {
      backend.transfer.failNextUpload(StateError('link went away'));

      await controller.sendPaths(peer: _peer(), paths: <String>[_userSource]);

      expect(cache.discarded, isEmpty);
      expect(controller.discardedByUs(_userSource), isFalse,
          reason: 'a failed row still needs that file for 重新发送, and its loss '
              '(if it happens) is not ours to dismiss');
    });

    test('a path we never touched is never "ours"', () {
      expect(controller.discardedByUs(_userSource), isFalse);
      expect(controller.discardedByUs(''), isFalse);
      expect(controller.discardedByUs(null), isFalse);
    });
  });

  group('★ isPickedCachePath — recognition, not a deletion guard', () {
    test('an Android per-send copy is recognised', () {
      expect(isPickedCachePath(_pickedCopy), isTrue);
      expect(isPickedCachePath(_pickedCopyVideo), isTrue);
      // Windows separators, should the host ever produce them.
      expect(isPickedCachePath(r'C:\cache\lanlink-picked\8f2c\x.bin'), isTrue);
    });

    test('a user file is not — including the ones the other tests use', () {
      expect(isPickedCachePath(_userSource), isFalse);
      expect(isPickedCachePath(_userSourceMobile), isFalse);
      // The paths the 0.2.48 sentinels use: if either of these were "ours", those
      // three tests would go green for the wrong reason.
      expect(isPickedCachePath('/cache/picked-copy.bin'), isFalse);
      expect(isPickedCachePath(r'C:\received\a.bin'), isFalse);
      expect(isPickedCachePath('/gone.bin'), isFalse);
    });

    test('the last segment is a file name, not the directory', () {
      expect(isPickedCachePath('/home/k/lanlink-picked'), isFalse,
          reason: 'a *file* the user happens to call that is not our directory');
      expect(isPickedCachePath('lanlink-picked'), isFalse);
      expect(isPickedCachePath(''), isFalse);
    });
  });
}
