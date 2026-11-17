/// **转发到… from one bubble, to several devices** (0.2.46) — the UI half.
///
/// The user's request, verbatim: *"右键一条消息就能转发"* and *"转给两台怎么办"*.
/// Until this release forwarding was only reachable through 「⋯ → 多选 → 勾选 →
/// 转发」, one device per run; the entry now lives in the message's own desktop
/// menu and the picker takes a **set** of devices.
///
/// What these cases pin, each against a way it could be wrong:
///
/// * **1** — right-clicking a text bubble with nothing selected offers 「转发到…」,
///   and it opens a device list that contains an **online** and an **offline**
///   device (the offline one is not disabled — the send queues, it does not fail);
/// * **2** — picking **two** devices writes one outgoing message into **each**
///   target conversation, identical text, and the source conversation is
///   untouched;
/// * **3** — picking **one** device writes to that one only (the fan-out must not
///   degenerate into "always everybody");
/// * **4** — picking **zero** (cancel, or the disabled confirm) sends nothing at
///   all: "no choice" is never read as "all";
/// * **6** — an offline device's copy is `pending` (queued), **not** `failed`,
///   while the online one's is `done`;
/// * **7** — the notice lists **each** device with its own verdict.
///
/// Every case runs on the **real desktop platform** (`TargetPlatform.windows`):
/// the menu is `SelectableRegion`'s, whose right-click branch is per platform —
/// proving it on the default (android) target would be proving the wrong branch.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/forward_target_picker.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _body = '这句话要转给两台设备';
const String _conversationId = 'c-fwd';

/// The device this conversation belongs to (the source).
PeerDevice _source() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小k',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A second, **online** device — a real forward target.
PeerDevice _online() => const PeerDevice(
      fingerprint: 'EE02',
      alias: '台式机',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53318,
    );

/// A third device that is **offline right now** but dialable when back: a stored
/// row with a port and no live discovery entry, which is the state that queues a
/// send instead of failing it (Q9).
PeerDevice _offline() => const PeerDevice(
      fingerprint: 'DD03',
      alias: '笔记本',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53319,
    );

/// Mounts the thread (desktop) with one text message and three devices.
Future<FakeBackend> _pump(
  WidgetTester tester, {
  String text = _body,
  MessageStatus status = MessageStatus.done,
}) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setMobile(false);
  backend.repo.addDevice(_source());
  backend.repo.addDevice(_online());
  backend.repo.addDevice(_offline());
  // ★ `mergeDeviceCards` takes "online" from **discovery**, not from the stored
  // row — a device with a port but no discovery entry is `canSend` yet *offline*,
  // so its forward is queued. Only 台式机 is brought online, on purpose: the two
  // states are what criteria 6 and 7 are about.
  backend.discovery.setOnline(<DiscoveredPeer>[
    DiscoveredPeer(
      fingerprint: 'EE02',
      alias: '台式机',
      kind: DeviceKind.desktop,
      address: '192.168.1.20',
      port: 53318,
      isOnline: true,
      lastSeen: fixedEpoch,
    ),
  ]);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: _conversationId,
    direction: MessageDirection.incoming,
    status: status,
    kind: MessageKind.text,
    textBody: text,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
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
  await pumpApp(
    tester,
    Scaffold(body: ConversationThread(controller: controller, peer: _source())),
    backend: backend,
    settle: true,
  );
  return backend;
}

/// Runs [body] with the **desktop platform** selected, resetting it in a
/// `finally` (the binding rejects a leftover debug override before tear-downs).
Future<void> _onWindows(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// A right click (secondary button down + up) at [at].
Future<void> _rightClickAt(WidgetTester tester, Offset at) async {
  final TestGesture gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Right-clicks the message body and enters 「转发到…」.
Future<void> _openForwardPicker(WidgetTester tester) async {
  await _rightClickAt(tester, tester.getCenter(find.text(_body)));
  await tester.tap(find.text('转发到…'));
  await tester.pumpAndSettle();
}

/// Taps the device rows named [aliases], then the confirm button.
Future<void> _pickAndConfirm(WidgetTester tester, List<String> aliases) async {
  for (final String alias in aliases) {
    await tester.tap(find.text(alias));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey<String>('forward-confirm')));
  await tester.pumpAndSettle();
}

/// Everything recorded in [fingerprint]'s conversation (empty when it has none).
List<ChatMessage> _historyOf(FakeBackend backend, String fingerprint) {
  final Iterable<Conversation> matches = backend.repo.conversations().where(
        (Conversation c) =>
            (c.deviceFingerprint ?? '').toUpperCase() ==
            fingerprint.toUpperCase(),
      );
  if (matches.isEmpty) {
    return const <ChatMessage>[];
  }
  return backend.repo.history(matches.first.id);
}

void main() {
  testWidgets(
      '★ criterion 1: right-clicking a text bubble offers 「转发到…」, and it opens a '
      'device list with an online AND an offline device (the offline one is not '
      'disabled — it queues)', (WidgetTester tester) async {
    await _onWindows(() async {
      await _pump(tester);

      await _rightClickAt(tester, tester.getCenter(find.text(_body)));
      expect(find.text('转发到…'), findsOneWidget,
          reason: '★ the whole point of 0.2.46: one gesture from one bubble');
      expect(find.text('复制文字'), findsOneWidget,
          reason: 'the existing entries are still there');
      expect(find.text('删除消息'), findsOneWidget);

      await tester.tap(find.text('转发到…'));
      await tester.pumpAndSettle();

      // The list: never a single-device prompt.
      expect(find.text('转发到'), findsOneWidget);
      expect(find.text('台式机'), findsOneWidget);
      expect(find.text('笔记本'), findsOneWidget);
      expect(find.text('在线'), findsOneWidget);
      // 小k (this conversation's device) is offline too — it has a stored row but
      // no live discovery entry — so more than one row carries the queue note.
      expect(find.textContaining('离线 · 会排队'), findsWidgets,
          reason: 'an offline device says *queued*, and stays pickable');
      expect(find.text('转发（0）'), findsOneWidget,
          reason: 'the confirm button counts what is picked');
    });
  });

  testWidgets(
      '★ criterion 2 + 6 + 7: picking TWO devices writes into BOTH conversations '
      '(identical text), the offline copy is `pending` not `failed`, and the notice '
      'lists each device', (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester);
      final int sourceBefore =
          backend.repo.history(_conversationId).length;

      await _openForwardPicker(tester);
      await _pickAndConfirm(tester, <String>['台式机', '笔记本']);

      final List<ChatMessage> first = _historyOf(backend, 'EE02');
      final List<ChatMessage> second = _historyOf(backend, 'DD03');
      expect(first, hasLength(1), reason: 'the online device got one message');
      expect(second, hasLength(1), reason: 'the offline device got one too');
      for (final ChatMessage message in <ChatMessage>[first.single, second.single]) {
        expect(message.direction, MessageDirection.outgoing);
        expect(message.kind, MessageKind.text);
        expect(message.textBody, _body, reason: 'verbatim, in both copies');
      }

      // ★ criterion 6: two genuinely different delivery states.
      expect(first.single.status, MessageStatus.done);
      expect(second.single.status, MessageStatus.pending,
          reason: '★ queued, NOT failed — the outbox pump sends it later (Q9)');
      expect(second.single.status, isNot(MessageStatus.failed));

      // The source conversation is unchanged.
      expect(backend.repo.history(_conversationId), hasLength(sourceBefore));

      // ★ criterion 7: one line, one verdict per device, both names present.
      expect(find.text('台式机 成功 · 笔记本 排队'), findsOneWidget,
          reason: '★ a blanket 转发失败 (or a single 已转发) would hide which '
              'device is waiting and which one has it');
    });
  });

  testWidgets(
      '★ criterion 3 (regression): picking ONE device writes to that one only — the '
      'fan-out is not "always everybody"', (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester);

      await _openForwardPicker(tester);
      await _pickAndConfirm(tester, <String>['笔记本']);

      expect(_historyOf(backend, 'DD03'), hasLength(1));
      expect(_historyOf(backend, 'EE02'), isEmpty,
          reason: '★ the device that was NOT picked must gain nothing');
      expect(backend.repo.history(_conversationId), hasLength(1));
      expect(find.text('笔记本 排队'), findsOneWidget);
    });
  });

  testWidgets(
      '★ criterion 4 (red line): picking ZERO devices sends NOTHING — 取消 and the '
      'disabled confirm are both "do nothing", never "send to all"',
      (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester);

      await _openForwardPicker(tester);

      // (a) the confirm button cannot even be pressed at zero picks.
      final Finder confirm =
          find.byKey(const ValueKey<String>('forward-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull,
          reason: '★ no button can turn "I did not choose" into a send');

      // (b)…and cancelling sends nothing at all.
      await tester.tap(find.byKey(const ValueKey<String>('forward-cancel')));
      await tester.pumpAndSettle();

      expect(find.text('转发到'), findsNothing, reason: 'the dialog is gone');
      expect(backend.transfer.sentTexts, isEmpty);
      expect(_historyOf(backend, 'EE02'), isEmpty);
      expect(_historyOf(backend, 'DD03'), isEmpty);
      expect(backend.repo.history(_conversationId), hasLength(1));
    });
  });

  testWidgets(
      'criterion 4 (second door): tapping the DISABLED confirm with zero picks still '
      'sends nothing', (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester);

      await _openForwardPicker(tester);
      // A tap on a disabled button must be a genuine no-op, not a "0 devices"
      // fan-out (an empty list has to stay distinguishable from "everything").
      await tester.tap(
        find.byKey(const ValueKey<String>('forward-confirm')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(find.text('转发到'), findsOneWidget,
          reason: 'the dialog stays open — nothing was confirmed');
      expect(backend.transfer.sentTexts, isEmpty);
      expect(_historyOf(backend, 'EE02'), isEmpty);
      expect(_historyOf(backend, 'DD03'), isEmpty);
    });
  });

  testWidgets(
      'the picker is a real multi-select: two rows can be picked at once and the '
      'button counts them', (WidgetTester tester) async {
    await _onWindows(() async {
      await _pump(tester);

      await _openForwardPicker(tester);
      await tester.tap(find.text('台式机'));
      await tester.pumpAndSettle();
      expect(find.text('转发（1）'), findsOneWidget);

      await tester.tap(find.text('笔记本'));
      await tester.pumpAndSettle();
      expect(find.text('转发（2）'), findsOneWidget);

      // Un-picking one row goes back to 1 — a tap is a toggle, not "select".
      await tester.tap(find.text('笔记本'));
      await tester.pumpAndSettle();
      expect(find.text('转发（1）'), findsOneWidget);
    });
  });

  testWidgets(
      'the picker fits a 320 dp phone — no overflow, the rows and both actions are '
      'all reachable (it is a phone dialog too, not only a desktop one)',
      (WidgetTester tester) async {
    await _onWindows(() async {
      useSurfaceSize(tester, const Size(320, 640));
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      backend.platform.setMobile(true);
      backend.repo.addDevice(_online());
      backend.repo.addDevice(
        // A long alias, the case that would ellipsis or overflow a fixed layout.
        const PeerDevice(
          fingerprint: 'DD03',
          alias: '笔记本这一台名字非常长的设备名称测试用',
          kind: DeviceKind.desktop,
          isOnline: false,
          lastPort: 53319,
        ),
      );
      backend.discovery.setOnline(<DiscoveredPeer>[
        DiscoveredPeer(
          fingerprint: 'EE02',
          alias: '台式机',
          kind: DeviceKind.desktop,
          address: '192.168.1.20',
          port: 53318,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ]);
      List<PeerDevice>? answer;
      await pumpApp(
        tester,
        Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  answer = await showForwardTargetPicker(context);
                },
                child: const Text('开'),
              ),
            ),
          ),
        ),
        backend: backend,
      );

      await tester.tap(find.text('开'));
      await tester.pumpAndSettle();

      // Rendering it at all is the assertion: an overflowing dialog throws in a
      // widget test (the surface is 320 wide, the dialog's content box is 360).
      expect(tester.takeException(), isNull);
      expect(find.text('在线'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('forward-cancel')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('forward-confirm')), findsOneWidget);

      await tester.tap(find.text('在线'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('forward-confirm')));
      await tester.pumpAndSettle();

      expect(answer, isNotNull);
      expect(answer, hasLength(1));
      expect(answer!.single.fingerprint, 'EE02');
    });
  });

  testWidgets(
      '★ 0.2.62: the same sheet answers ONE device in single-select mode (one row '
      'tap, no confirm button) while 转发 still answers MANY',
      (WidgetTester tester) async {
    await _onWindows(() async {
      useSurfaceSize(tester, const Size(1000, 900));
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      backend.platform.setMobile(false);
      backend.repo.addDevice(_online());
      backend.repo.addDevice(_offline());
      // `mergeDeviceCards` reads presence from **discovery**, so 台式机 is only
      // "在线" once it is announced — the two rows then show both states.
      backend.discovery.setOnline(<DiscoveredPeer>[
        DiscoveredPeer(
          fingerprint: 'EE02',
          alias: '台式机',
          kind: DeviceKind.desktop,
          address: '192.168.1.20',
          port: 53318,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ]);
      List<PeerDevice>? single;
      List<PeerDevice>? multi;
      await pumpApp(
        tester,
        Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ElevatedButton(
                    onPressed: () async {
                      single = await showForwardTargetPicker(
                        context,
                        singleSelect: true,
                        title: '把 2 个文件发给谁',
                      );
                    },
                    child: const Text('单选'),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      multi = await showForwardTargetPicker(context);
                    },
                    child: const Text('多选'),
                  ),
                ],
              ),
            ),
          ),
        ),
        backend: backend,
      );

      // ── 分享's question: one row = one answer = the sheet closes ───────────
      await tester.tap(find.text('单选'));
      await tester.pumpAndSettle();
      expect(find.text('把 2 个文件发给谁'), findsOneWidget,
          reason: 'the caller names the question');
      expect(find.byKey(const ValueKey<String>('forward-confirm')), findsNothing,
          reason: '★ 单选没有第二个确认按钮 —— 点一行就是答案');
      // The same rule as 转发: an offline device is explained, not banned.
      expect(find.textContaining('离线 · 会排队'), findsOneWidget);

      await tester.tap(find.text('台式机'));
      await tester.pumpAndSettle();
      expect(find.text('把 2 个文件发给谁'), findsNothing,
          reason: '★ a row tap closes it — there is nothing left to confirm');
      expect(single, hasLength(1),
          reason: 'a draft has ONE destination, so the answer is 0 or 1');
      expect(single!.single.alias, '台式机');

      // ── 转发 is untouched: checkboxes, a count, and two picks come back ─────
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.text('转发到'), findsOneWidget,
          reason: 'the default title is still the 转发 one');
      expect(find.byKey(const ValueKey<String>('forward-confirm')), findsOneWidget);

      await _pickAndConfirm(tester, <String>['台式机', '笔记本']);
      expect(multi, hasLength(2),
          reason: '★ multi-select must stay multi-select — 0.2.46 is not undone');
      expect(
        <String>[for (final PeerDevice d in multi!) d.alias],
        <String>['台式机', '笔记本'],
        reason: 'and in the order the user picked them',
      );
    });
  });
}
