/// 0.2.63 — 「改发到…」: a staged share can be re-pointed at another device.
///
/// 0.2.62 made the destination a question ("先问发给谁"), but the answer was
/// final: the 待发送 row offered only 发送 and 取消, so picking the wrong device
/// meant cancel-and-share-again. This release adds one control to that row, and
/// the rules these tests pin are its whole contract:
///
///  1. the row **names the target** (`发到 手机 · 3 个文件`) — before this, the
///     destination the user had just chosen was nowhere on screen, so a wrong
///     pick looked exactly like a right one;
///  2. tapping 「改发到…」 asks the same single-select sheet and **moves the same
///     draft** — it does not copy the files, does not re-import them, and
///     ★ never sends anything (`prepareCalls == 0`, every history empty);
///  3. 取消 on that sheet is a **no-op**: the draft keeps the device it had
///     (the opposite of `_askShareTarget`'s 取消, where no device is bound yet);
///  4. the button is **disabled while a send is being prepared** — the target
///     must not change under an in-flight send — and it is **not drawn at all**
///     when the host hands the thread no callback (a thread mounted on its own,
///     as most widget tests do, keeps the one-line row);
///  5. the 0.2.62 rule survives the new door: `attachTo` is still bind-once, so
///     after a deliberate move a later inferred binding cannot move it again.
///
/// The end-to-end cases mount the **whole shell** (`pumpShell`), because the
/// point is the wiring: intake → shell → picker → selection → thread.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:lanlink_app/domain/share_inbox.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';
import 'package:lanlink_app/ui/notices.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/shell/share_intake.dart';
import 'package:lanlink_app/ui/shell/shell_controller.dart';

import '../support/pump_app.dart';

/// The 待发送 row's own sentence. Anchored at the start so it cannot be
/// confused with the 「转发到…」 menu entry, which also contains 「发到」.
final RegExp _draftRow = RegExp(r'^发到 ');

/// The 「改发到…」 button of the row.
final Finder _retargetButton =
    find.byKey(const ValueKey<String>('share-draft-retarget'));

/// A share inbox that hands over exactly one launch payload.
class _OneShotInbox implements ShareInboxPort {
  _OneShotInbox(this.uris);

  /// The URIs the launch share carries.
  final List<String> uris;
  final StreamController<SharedPayload> _incoming =
      StreamController<SharedPayload>.broadcast();
  bool _taken = false;

  @override
  bool get isSupported => true;

  @override
  Stream<SharedPayload> get incoming => _incoming.stream;

  @override
  Future<SharedPayload?> takeInitial() async {
    if (_taken) {
      return null;
    }
    _taken = true;
    return SharedPayload(uris: uris, mime: 'image/*', multiple: uris.length > 1);
  }

  @override
  Future<ShareImport> materialize(SharedPayload payload) async => ShareImport(
        paths: <String>[
          for (final String uri in payload.uris)
            '/share-cache/${uri.split('/').last}',
        ],
        failures: const <ShareImportFailure>[],
      );

  void dispose() => _incoming.close();
}

/// A cleaner that must never be asked to delete anything on a move.
class _RecordingCache implements PickedCachePort {
  /// Every path handed to [discard], flattened.
  final List<String> discarded = <String>[];

  @override
  Future<void> discard(Iterable<String> paths) async {
    discarded.addAll(paths);
  }

  @override
  Future<void> clear({Set<String> keep = const <String>{}}) async {}
}

PeerDevice _peer(String fingerprint, String alias, DeviceKind kind) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: kind,
      isOnline: true,
      lastPort: 53317,
    );

/// 「手机」 (EE20) — the device the draft is first pointed at — and 「平板」
/// (EE21) — the device it is moved to.
const String _kPhone = 'EE20';
const String _kTablet = 'EE21';

/// Seeds both devices and the discovery list, so the picker has two real rows.
void _twoDevices(FakeBackend backend) {
  backend.repo.addDevice(_peer(_kPhone, '手机', DeviceKind.mobile));
  backend.repo.addDevice(_peer(_kTablet, '平板', DeviceKind.mobile));
  backend.discovery.setOnline(<DiscoveredPeer>[
    DiscoveredPeer(
      fingerprint: _kPhone,
      alias: '手机',
      kind: DeviceKind.mobile,
      address: '192.168.1.20',
      port: 53317,
      isOnline: true,
      lastSeen: fixedEpoch,
    ),
    DiscoveredPeer(
      fingerprint: _kTablet,
      alias: '平板',
      kind: DeviceKind.mobile,
      address: '192.168.1.21',
      port: 53317,
      isOnline: true,
      lastSeen: fixedEpoch,
    ),
  ]);
}

/// The chooser row of [fingerprint] (the same key in both picker modes).
Finder _targetRow(String fingerprint) =>
    find.byKey(ValueKey<String>('forward-target-$fingerprint'));

/// Mounts the shell, lets the launch share arrive, and answers the chooser with
/// 「手机」 — the state every case below starts from: one bound draft.
Future<FakeBackend> _pumpBoundToPhone(
  WidgetTester tester, {
  _OneShotInbox? inbox,
  _RecordingCache? cache,
  Size size = const Size(1200, 900),
}) async {
  useSurfaceSize(tester, size);
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setExists('/share-cache/a', true);
  backend.platform.setExists('/share-cache/b', true);
  backend.platform.setExists('/share-cache/c', true);
  _twoDevices(backend);

  final _OneShotInbox shareInbox = inbox ??
      _OneShotInbox(const <String>[
        'content://p/a',
        'content://p/b',
        'content://p/c',
      ]);
  addTearDown(shareInbox.dispose);

  await pumpShell(
    tester,
    backend: backend,
    shareInbox: shareInbox,
    pickedCache: cache,
    settle: true,
  );
  // The launch share asks 「发给谁」; answer it.
  expect(find.text('把 3 个文件发给谁'), findsOneWidget);
  await tester.tap(_targetRow(_kPhone));
  await tester.pumpAndSettle();
  // The import notice ("已收到 3 个文件…") floats over the bottom of the shell
  // for [kNoticeDuration] and would swallow taps aimed at the row underneath it,
  // so every case below starts after it has expired.
  await tester.pump(kNoticeDuration + const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  return backend;
}

/// The conversation id the shell opened for [fingerprint].
String _conversationFor(FakeBackend backend, String fingerprint) {
  for (final Conversation conversation in backend.repo.conversations()) {
    if (conversation.deviceFingerprint == fingerprint) {
      return conversation.id;
    }
  }
  fail('no conversation for $fingerprint');
}

void main() {
  // ── The unit contract of ShareIntake.retarget ────────────────────────────

  group('ShareIntake.retarget (0.2.63)', () {
    late FakeBackend backend;
    late _OneShotInbox inbox;
    late _RecordingCache cache;
    late ShellController shell;
    late ShareIntake intake;

    setUp(() async {
      backend = FakeBackend();
      cache = _RecordingCache();
      inbox = _OneShotInbox(const <String>['content://media/1']);
      final Conversation conversation = backend.repo.addConversation(
        id: 'c-phone',
        deviceFingerprint: _kPhone,
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );
      shell = ShellController(
        repo: backend.repo,
        initialPeer: PeerDevice(
          fingerprint: _kPhone,
          alias: '手机',
          kind: DeviceKind.mobile,
          isOnline: true,
          lastPort: 53317,
          conversationId: conversation.id,
        ),
      );
      intake = ShareIntake(inbox: inbox, shell: shell, pickedCache: cache);
      await intake.start();
      await pumpEventQueue();
    });

    tearDown(() {
      intake.dispose();
      shell.dispose();
      inbox.dispose();
      backend.dispose();
    });

    test('★ moves a BOUND draft to the new conversation, keeping the files', () {
      intake.attachTo('c-phone');
      expect(intake.draft!.conversationId, 'c-phone',
          reason: 'precondition: the draft is bound');

      intake.retarget('c-tablet');

      expect(intake.draft!.conversationId, 'c-tablet',
          reason: '★ 用户显式改投 —— 这一条必须能穿过 attachTo 的 bind-once');
      expect(intake.draft!.paths, <String>['/share-cache/1'],
          reason: 'a move is the same path list, not a new import');
      expect(cache.discarded, isEmpty,
          reason: 'the copies are still needed — nothing was cancelled');
    });

    test('a draft the user just moved is not re-pointed by a later selection',
        () {
      // The 0.2.62 rule has to survive the new door: an *inferred* binding never
      // overwrites an answer, and a deliberate move is still an answer.
      intake.attachTo('c-phone');
      intake.retarget('c-tablet');
      intake.attachTo('c-phone');

      expect(intake.draft!.conversationId, 'c-tablet',
          reason: 'attachTo is still bind-once — it may not undo a move');
    });

    test('an empty draft is a no-op, and nothing is thrown', () {
      intake.discardDraft();
      expect(intake.draft, isNull);

      intake.retarget('c-tablet');

      expect(intake.draft, isNull);
      expect(cache.discarded, <String>['/share-cache/1'],
          reason: 'a retarget on no draft must not resurrect or re-discard');
    });

    test('a move consumes the one-shot 「发给谁」 request, so no sheet re-opens',
        () {
      // Fresh draft: the shell has not taken the request yet.
      expect(intake.takeTargetRequest(), isTrue,
          reason: 'precondition: the launch share raised the question');

      // Re-arm it the way a second share would, then answer by hand.
      intake.attachTo('c-phone');
      expect(intake.needsTarget, isFalse);
      intake.retarget('c-tablet');

      expect(intake.takeTargetRequest(), isFalse,
          reason: '★ 改投是回答，不是新问题 —— 不能再弹一次选择器');
    });
  });

  // ── The row itself ───────────────────────────────────────────────────────

  testWidgets('★ the row names the device the draft is bound to (0.2.63)',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpBoundToPhone(tester);

    expect(find.text('发到 手机 · 3 个文件'), findsOneWidget,
        reason: '★ 用户刚选的设备必须在条上看得见 —— 选错才看得出来选错了');
    expect(find.textContaining('待发送'), findsNothing,
        reason: 'the old wording answered "what" but never "to whom"');
    expect(_retargetButton, findsOneWidget);
    expect(backend.transfer.prepareCalls, 0,
        reason: 'binding is not sending');
  });

  testWidgets(
      '★ 改发到… → another device moves the draft there and sends NOTHING',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpBoundToPhone(tester);
    final String phoneConversation = _conversationFor(backend, _kPhone);

    await tester.tap(_retargetButton);
    await tester.pumpAndSettle();

    // The same single-select sheet, with its own question.
    expect(find.text('把这 3 个文件改发给谁'), findsOneWidget);
    expect(find.text('手机'), findsWidgets,
        reason: 'the current target is offered too — a move back is legitimate');

    await tester.tap(_targetRow(_kTablet));
    await tester.pumpAndSettle();

    expect(find.text('把这 3 个文件改发给谁'), findsNothing,
        reason: 'single-select: a row tap is the answer, no confirm button');
    // The shell jumped to 平板's thread, and the draft is on its row.
    expect(find.text('发到 平板 · 3 个文件'), findsOneWidget,
        reason: '★ 草稿整体改投，跟着用户跳到那台设备');

    // ★ And it is genuinely *gone* from 手机 — not copied to both.
    await tester.tap(find.text('手机').first);
    await tester.pumpAndSettle();
    expect(find.textContaining(_draftRow), findsNothing,
        reason: '★ 一份草稿只有一个目的地 —— 原来的会话不能再挂着它');

    // Nothing was sent and nothing was re-copied anywhere along the way.
    expect(backend.transfer.prepareCalls, 0,
        reason: '★ 改投不是发送');
    expect(backend.repo.history(phoneConversation), isEmpty);
    for (final Conversation conversation in backend.repo.conversations()) {
      expect(backend.repo.history(conversation.id), isEmpty,
          reason: 'no conversation may gain a message from a move');
    }
  });

  testWidgets(
      '★ 取消 on the 改发到 sheet changes nothing — the draft keeps its device',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpBoundToPhone(tester);

    await tester.tap(_retargetButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('forward-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('把这 3 个文件改发给谁'), findsNothing);
    expect(find.text('发到 手机 · 3 个文件'), findsOneWidget,
        reason: '★ 打开又关掉不该丢掉已经给出的答案');
    expect(_retargetButton, findsOneWidget,
        reason: 'and the way back is still there');
    expect(backend.transfer.prepareCalls, 0);
  });

  testWidgets(
      '★ while a send is being prepared the 改发到… button is disabled',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpBoundToPhone(tester);
    // Park the send inside `prepare`, which is exactly the window where
    // `_preparing` is true and the target must not move.
    final Completer<void> gate = Completer<void>();
    backend.transfer.holdNextPrepare(gate);

    await tester.tap(find.text('发送'));
    await tester.pump();

    final OutlinedButton held = tester.widget<OutlinedButton>(_retargetButton);
    expect(held.onPressed, isNull,
        reason: '★ 准备/发送中不给点 —— 目标不能从正在进行的发送底下被换走');
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '发送')).onPressed, isNull,
        reason: 'the two primary actions are held by the same guard');

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'a host that hands the thread no callback gets no 改发到… (0.2.63 shape '
      'stays opt-in)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-solo',
      deviceFingerprint: _kPhone,
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addDevice(_peer(_kPhone, '手机', DeviceKind.mobile));
    final TransferOrchestrator orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
    addTearDown(orchestrator.dispose);
    final ConversationController controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: 'c-solo',
      dismissals: UnsentDismissalStore(),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await pumpApp(
      tester,
      Scaffold(
        body: ConversationThread(
          controller: controller,
          peer: _peer(_kPhone, '手机', DeviceKind.mobile),
          sharedPaths: const <String>['/share/photo.png'],
          // No `onRetargetDraft`: this host has no chooser to offer.
        ),
      ),
      backend: backend,
      settle: true,
    );

    expect(find.text('发到 手机 · photo.png'), findsOneWidget,
        reason: 'the target-naming label does not depend on the callback');
    expect(_retargetButton, findsNothing,
        reason: '★ onRetargetDraft == null → 不渲染，而不是画一个点不动的按钮');
  });
}
