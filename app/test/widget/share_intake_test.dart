/// Widget tests for the inbound-share interaction (0.2.18) — "分享进来的文件接住，
/// 但绝不替用户按发送".
///
/// The rules these pin (the change's "能抓错" criteria):
///
///  1. a share **always** starts as an **unsent, unbound** draft: even with a
///     conversation open, the destination is a question (0.2.62), and no message
///     is recorded;
///  2. the answer to that question — tapping a device in the chooser, or a device
///     row in the list — only **binds** the draft; sending still happens *only*
///     on a tap of 发送, through the same `ConversationController.sendPaths` a
///     picked file uses;
///  3. 取消 on the chooser binds **nothing** and deletes **nothing**: the draft and
///     the temporary copies both survive, and the list is where the user can still
///     answer;
///  4. a partially failed import still stages what made it and says how many
///     failed — a share must never fail silently.
///
/// They mount the **whole shell** (through `pumpShell`), because the point is the
/// wiring: intake → shell → chooser → detail pane → thread → composer.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:lanlink_app/domain/share_inbox.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/pump_app.dart';

/// The 待发送 row's sentence, matched by its **shape** rather than one exact
/// string.
///
/// 0.2.63 renamed it from 「待发送 · 3 个文件」 to 「发到 手机 · 3 个文件」: the
/// destination the user chose is now part of the line, which is what these cases
/// are really about ("the draft is waiting **in the right conversation**"). The
/// regex is anchored at the start so it cannot be satisfied by the 「转发到…」
/// menu entry, which also contains 「发到」.
final RegExp _draftRow = RegExp(r'^发到 ');

/// A controllable [ShareInboxPort]: it answers a fixed launch share and records
/// what the intake asked it to copy.
class _FakeShareInbox implements ShareInboxPort {
  _FakeShareInbox({
    this.initial,
    this.supported = true,
    this.failOn = const <String>{},
  });

  /// The share that "launched the app" (returned by [takeInitial] once).
  final SharedPayload? initial;

  /// Whether this platform claims the capability.
  final bool supported;

  /// URIs whose copy must fail (to exercise the per-URI failure report).
  final Set<String> failOn;

  /// Every payload passed to [materialize], in order.
  final List<SharedPayload> materialized = <SharedPayload>[];

  int takeInitialCalls = 0;

  bool _answered = false;

  final StreamController<SharedPayload> _incoming =
      StreamController<SharedPayload>.broadcast();

  @override
  bool get isSupported => supported;

  @override
  Stream<SharedPayload> get incoming => _incoming.stream;

  @override
  Future<SharedPayload?> takeInitial() async {
    takeInitialCalls++;
    if (_answered) {
      return null;
    }
    _answered = true;
    return initial;
  }

  @override
  Future<ShareImport> materialize(SharedPayload payload) async {
    materialized.add(payload);
    final List<String> paths = <String>[];
    final List<ShareImportFailure> failures = <ShareImportFailure>[];
    for (final String uri in payload.uris) {
      if (failOn.contains(uri)) {
        failures.add(ShareImportFailure(uri: uri, reason: 'test: 已删除'));
        continue;
      }
      paths.add('/share-cache/${uri.split('/').last}');
    }
    return ShareImport(paths: paths, failures: failures);
  }

  /// Pushes a share that arrives while the app is running.
  void push(SharedPayload payload) => _incoming.add(payload);

  void dispose() => _incoming.close();
}

/// Records what was asked of the temporary-copy cleaner (0.2.23).
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

PeerDevice _peer(String fingerprint, {required String alias}) => PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Seeds two sendable devices: `EE09` = Eve (the one with a conversation, so a
/// 0.2.61 build would have put the draft there) and `EE10` = Nina (the one the
/// tests actually pick).
void _twoDevices(FakeBackend backend) {
  backend.repo.addDevice(_peer('EE09', alias: 'Eve'));
  backend.repo.addDevice(_peer('EE10', alias: 'Nina'));
  backend.discovery.setOnline(<DiscoveredPeer>[
    DiscoveredPeer(
      fingerprint: 'EE09',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      address: '192.168.1.10',
      port: 53317,
      isOnline: true,
      lastSeen: fixedEpoch,
    ),
    DiscoveredPeer(
      fingerprint: 'EE10',
      alias: 'Nina',
      kind: DeviceKind.desktop,
      address: '192.168.1.11',
      port: 53318,
      isOnline: true,
      lastSeen: fixedEpoch,
    ),
  ]);
}

/// The row of the chooser for [fingerprint] — the same key in both of the
/// picker's modes, so a test addresses a device the same way either way.
Finder _targetRow(String fingerprint) =>
    find.byKey(ValueKey<String>('forward-target-$fingerprint'));

SharedPayload _video(String uri) =>
    SharedPayload(uris: <String>[uri], mime: 'video/mp4');

void main() {
  testWidgets(
      '★ 0.2.62: a share with a conversation open binds NOTHING — it asks '
      '「发给谁」 first', (WidgetTester tester) async {
    // Wide on purpose: the detail pane is mounted, so a draft wrongly bound to
    // the open conversation would really draw its 待发送 row here.
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-share',
      deviceFingerprint: 'EE09',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.platform.setExists('/share-cache/123', true);
    _twoDevices(backend);

    final _FakeShareInbox inbox = _FakeShareInbox(
      initial: _video('content://media/external/video/media/123'),
    );
    addTearDown(inbox.dispose);

    await pumpShell(
      tester,
      backend: backend,
      shareInbox: inbox,
      settle: true,
      initialPeer: _peer('EE09', alias: 'Eve'),
    );

    // ★ The bug 0.2.62 fixes: Eve's conversation was open, and 0.2.61 silently
    // staged the share THERE — in a thread the user never chose, immovably.
    expect(find.textContaining(_draftRow), findsNothing,
        reason: '★ 会话打开着也不能把分享默默放进去 —— 目的地必须先问');
    expect(backend.repo.history('c-share'), isEmpty,
        reason: 'a share must never send itself');

    // What the user sees instead: the one question, in the device sheet.
    expect(find.text('把 1 个文件发给谁'), findsOneWidget);
    expect(find.textContaining('已收到 1 个文件'), findsOneWidget);
    expect(find.textContaining('选择要发给谁'), findsOneWidget,
        reason: 'the notice repeats the question behind the sheet, for 取消');
  });

  testWidgets(
      '★ picking a device in the chooser binds the draft to that conversation '
      'and sends NOTHING', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-share',
      deviceFingerprint: 'EE09',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.platform.setExists('/share-cache/123', true);
    _twoDevices(backend);

    final _FakeShareInbox inbox = _FakeShareInbox(
      initial: _video('content://media/external/video/media/123'),
    );
    addTearDown(inbox.dispose);

    await pumpShell(
      tester,
      backend: backend,
      shareInbox: inbox,
      settle: true,
      initialPeer: _peer('EE09', alias: 'Eve'),
    );
    expect(find.text('把 1 个文件发给谁'), findsOneWidget);

    // Nina, not Eve — the device that was NOT open. That is the whole point.
    await tester.tap(_targetRow('EE10'));
    await tester.pumpAndSettle();

    expect(find.text('把 1 个文件发给谁'), findsNothing,
        reason: '单选：点一行就是答案，没有第二个确认按钮');
    expect(find.textContaining(_draftRow), findsOneWidget,
        reason: 'the draft now waits in the conversation the user picked');
    expect(find.textContaining('123'), findsOneWidget,
        reason: 'the row names the shared file, so the user can confirm it');

    // ★ Still nothing sent — binding a destination is not sending.
    expect(find.byType(MessageBubble), findsNothing,
        reason: 'a share must never send itself — the user still chooses');
    expect(backend.repo.history('c-share'), isEmpty,
        reason: 'and especially not the conversation that merely happened to be '
            'open');
    for (final Conversation conversation in backend.repo.conversations()) {
      expect(backend.repo.history(conversation.id), isEmpty,
          reason: 'no conversation may gain a message from the answer alone');
    }
    expect(backend.transfer.prepareCalls, 0,
        reason: 'no bytes were prepared — only the destination was chosen');
  });

  testWidgets(
      '★ 取消 binds nothing and frees nothing — the draft and its copies both '
      'survive, and a device row is still a valid answer', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-share',
      deviceFingerprint: 'EE09',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.platform.setExists('/share-cache/123', true);
    _twoDevices(backend);
    final _RecordingCache cache = _RecordingCache();

    final _FakeShareInbox inbox = _FakeShareInbox(
      initial: _video('content://media/external/video/media/123'),
    );
    addTearDown(inbox.dispose);

    await pumpShell(
      tester,
      backend: backend,
      shareInbox: inbox,
      settle: true,
      initialPeer: _peer('EE09', alias: 'Eve'),
      pickedCache: cache,
    );
    await tester.tap(find.byKey(const ValueKey<String>('forward-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('把 1 个文件发给谁'), findsNothing);
    expect(find.textContaining(_draftRow), findsNothing,
        reason: '取消 must not bind a destination either');
    expect(cache.discarded, isEmpty,
        reason: '★ 取消「选择器」不是 取消「收下文件」—— the copies must stay, '
            'the draft is still waiting');
    expect(find.textContaining('选择要发给谁'), findsOneWidget,
        reason: 'the prompt that survives the 取消 says what to do instead');

    // The surviving answer: tap the device row. The draft was never lost, so it
    // binds now — and still sends nothing.
    await tester.tap(find.text('Nina').first);
    await tester.pumpAndSettle();

    expect(find.textContaining(_draftRow), findsOneWidget,
        reason: 'the draft survived 取消 and binds to the device the user taps');
    expect(find.textContaining('123'), findsOneWidget);
    expect(cache.discarded, isEmpty);
    for (final Conversation conversation in backend.repo.conversations()) {
      expect(backend.repo.history(conversation.id), isEmpty,
          reason: 'nothing was sent by any of this');
    }
  });

  testWidgets(
      'a share with nothing selected also asks WHO to send to, and stages '
      'no draft in any thread', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    _twoDevices(backend);

    final _FakeShareInbox inbox = _FakeShareInbox(
      initial: const SharedPayload(
        uris: <String>['content://p/a', 'content://p/b', 'content://p/c'],
        mime: 'image/*',
        multiple: true,
      ),
    );
    addTearDown(inbox.dispose);

    await pumpShell(tester, backend: backend, shareInbox: inbox, settle: true);

    expect(find.text('把 3 个文件发给谁'), findsOneWidget,
        reason: 'the user must pick the recipient; we never guess one');
    expect(find.textContaining('已收到 3 个文件'), findsOneWidget);
    expect(find.textContaining(_draftRow), findsNothing,
        reason: 'no conversation is open, so no thread may show a draft');
    expect(inbox.materialized, hasLength(1),
        reason: 'the files are already copied — only the target is missing');
  });

  testWidgets(
      'a partially failed share still stages the rest and says how many '
      'failed', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    final _FakeShareInbox inbox = _FakeShareInbox(
      initial: const SharedPayload(
        uris: <String>['content://p/ok', 'content://p/gone'],
        mime: 'image/*',
        multiple: true,
      ),
      failOn: <String>{'content://p/gone'},
    );
    addTearDown(inbox.dispose);

    await pumpShell(tester, backend: backend, shareInbox: inbox, settle: true);

    expect(find.textContaining('已收到 1 个文件'), findsOneWidget);
    expect(find.textContaining('1 个失败'), findsOneWidget,
        reason: 'a failed URI is reported, never swallowed');
  });

  testWidgets(
      'a share arriving while running is asked about too (onNewIntent path)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-share2',
      deviceFingerprint: 'EE09',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.platform.setExists('/share-cache/live', true);
    _twoDevices(backend);

    final _FakeShareInbox inbox = _FakeShareInbox();
    addTearDown(inbox.dispose);

    await pumpShell(
      tester,
      backend: backend,
      shareInbox: inbox,
      settle: true,
      initialPeer: _peer('EE09', alias: 'Eve'),
    );

    expect(find.textContaining('待发送'), findsNothing);

    inbox.push(_video('content://media/external/image/media/live'));
    await tester.pumpAndSettle();

    // Same rule as the launch share: a question, not a destination.
    expect(find.text('把 1 个文件发给谁'), findsOneWidget);
    expect(find.textContaining(_draftRow), findsNothing,
        reason: '★ a live share must not land in the open conversation either');

    await tester.tap(_targetRow('EE10'));
    await tester.pumpAndSettle();

    expect(find.textContaining(_draftRow), findsOneWidget);
    expect(find.textContaining('live'), findsOneWidget);
    expect(backend.repo.history('c-share2'), isEmpty,
        reason: 'still nothing sent — the draft only waits');
  });

  testWidgets(
      'the intake reports the launch share only once, so a rebuild '
      'cannot duplicate the draft or the chooser', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-share3',
      deviceFingerprint: 'EE09',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.platform.setExists('/share-cache/once', true);
    _twoDevices(backend);

    final _FakeShareInbox inbox = _FakeShareInbox(
      initial: _video('content://media/external/video/media/once'),
    );
    addTearDown(inbox.dispose);

    await pumpShell(
      tester,
      backend: backend,
      shareInbox: inbox,
      settle: true,
      initialPeer: _peer('EE09', alias: 'Eve'),
    );
    await tester.pumpAndSettle();

    expect(inbox.takeInitialCalls, 1,
        reason: 'the launch share is asked for exactly once per mount');
    expect(find.text('把 1 个文件发给谁'), findsOneWidget,
        reason: '★ one share = one chooser, not a stack of them');

    await tester.tap(_targetRow('EE10'));
    await tester.pumpAndSettle();

    expect(find.textContaining(_draftRow), findsOneWidget,
        reason: 'one share = one row, not two');
  });

  testWidgets(
      'a platform that cannot receive shares (Web / desktop) never even '
      'asks, and stages nothing', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-share4',
      deviceFingerprint: 'EE12',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );

    final _FakeShareInbox inbox = _FakeShareInbox(
      initial: _video('content://media/external/video/media/nope'),
      supported: false,
    );
    addTearDown(inbox.dispose);

    await pumpShell(
      tester,
      backend: backend,
      shareInbox: inbox,
      settle: true,
      initialPeer: _peer('EE12', alias: 'Eve'),
    );

    expect(inbox.takeInitialCalls, 0,
        reason: 'no capability → no channel call at all');
    expect(find.textContaining('待发送'), findsNothing);
    expect(find.textContaining('发给谁'), findsNothing,
        reason: 'no share arrived, so nothing may be asked');
  });
}
