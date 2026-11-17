/// 0.2.54 — the **entry points**: the empty device list's 「手动填写 IP 连接」, the
/// dialog behind it, and the 设置 page's 「手动添加的设备」 block.
///
/// ## What these judgements are about
///
/// Not "a button exists". The feature's whole problem was that a user whose
/// network eats multicast *and* broadcast had nothing to press: the address
/// parser, the probe and the heartbeat had all shipped, and none of them was
/// reachable. So the judgements here are the user's path:
///
/// * the **doors**: the empty list's 「手动填写 IP 连接」, the → ⋮ item on **both**
///   shells, and 设置's 「添加设备地址」 row. A populated list still shows no
///   standing button (that would be noise, and would invite skipping the four
///   hints that usually fix discovery) — but since 0.2.56 the ⋮ carries it, so
///   "I already have devices, I want to add one more" stays possible;
/// * the dialog accepts both `IP` and `IP:port` and hands the text on untouched;
/// * connecting from it puts the device in the list, with no second confirmation;
/// * 移除 in 设置 removes the address (and only the address — the device stays,
///   grey, as any peer that stopped answering does).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/manual_targets.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_app/ui/format.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/widgets/manual_peer_dialog.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The peer a probe in these tests reaches.
const String _kFp = 'A1A1A1A1';

/// The address typed.
const String _kHost = '192.168.1.23';

/// The default port, as `core.kDefaultPort`.
const int _kPort = 49494;

/// The entry point's label, as shipped (asserted literally — the wording is the
/// requirement).
const String _kEntryLabel = '手动填写 IP 连接';

void main() {
  group('1. the doors — the empty list (a button) and a used one (the ⋮)', () {
    testWidgets('desktop: an empty device list offers it once', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester, settle: true);

      expect(find.text('还没有发现设备'), findsOneWidget,
          reason: 'precondition: the list really is empty');
      expect(find.text(_kEntryLabel), findsOneWidget);
      expect(find.text('发现被网络挡住时，用这个直接连'), findsOneWidget,
          reason: 'the line under it says *when* to use it — an unexplained '
              'second button is worse than none');
    });

    testWidgets('phone: the same body, the same door', (
      WidgetTester tester,
    ) async {
      // Narrow enough for `PhoneShell` (the shell picks its layout from the
      // window width), which is the shape a phone actually renders.
      useSurfaceSize(tester, const Size(400, 900));
      await pumpShell(tester, settle: true);

      expect(find.text(_kEntryLabel), findsOneWidget,
          reason: 'both layouts share `_ConversationsBody`, and this is what '
              'proves the phone did not end up with a second, silent variant');
    });

    testWidgets('a list with a device reaches it through the ⋮, not a button', (
      WidgetTester tester,
    ) async {
      await pumpShell(
        tester,
        backend: FakeBackend(
          online: <DiscoveredPeer>[
            DiscoveredPeer(
              fingerprint: _kFp,
              alias: 'Alice Phone',
              kind: DeviceKind.mobile,
              address: _kHost,
              port: _kPort,
              isOnline: true,
              lastSeen: fixedEpoch,
            ),
          ],
        ),
        settle: true,
      );

      expect(find.text('Alice Phone'), findsOneWidget, reason: 'precondition');
      // ★ 0.2.56 — 「not in the body」 stopped meaning 「not offered」.
      //
      // A standing 「手动填写 IP」 over a populated list is still noise, and still
      // invites skipping the four hints. But a card outlives discovery, so a list
      // that has ever held one device never empties again: with the button as the
      // only door, a user adding a *second* device by address had no way in at
      // all. The door moved into the header's ⋮ instead.
      expect(find.text(_kEntryLabel), findsNothing,
          reason: 'no standing button over a populated list');
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text(_kEntryLabel), findsOneWidget,
          reason: 'but it is one tap away — otherwise 「再加一台设备」 is impossible '
              'for exactly the users who have been using the app longest');

      // ★ 0.2.57 — and the item must actually **open the dialog**. Until this
      // assertion existed, the menu item was only ever checked for *existence*:
      // emptying `_onConversationsMenu`'s `manualPeer` case left all 1041 tests
      // green. Same shape as the rescan hole next door.
      await tester.tap(find.text(_kEntryLabel));
      await tester.pumpAndSettle();
      expect(find.byType(ManualPeerDialog), findsOneWidget,
          reason: 'tapping the item must reach the dialog, not just close the menu');
    });

    testWidgets('phone: the same item, from the list page ⋮', (
      WidgetTester tester,
    ) async {
      useSurfaceSize(tester, const Size(600, 800));
      await pumpShell(
        tester,
        backend: FakeBackend(
          online: <DiscoveredPeer>[
            DiscoveredPeer(
              fingerprint: _kFp,
              alias: 'Alice Phone',
              kind: DeviceKind.mobile,
              address: _kHost,
              port: _kPort,
              isOnline: true,
              lastSeen: fixedEpoch,
            ),
          ],
        ),
        settle: true,
      );

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_kEntryLabel));
      await tester.pumpAndSettle();
      expect(find.byType(ManualPeerDialog), findsOneWidget,
          reason: 'the phone path is a second copy of the handler (different '
              'enum, different switch) — existence alone proves nothing about it');
    });

    testWidgets('at the cap the ⋮ item is disabled, not a dead-end dialog', (
      WidgetTester tester,
    ) async {
      final List<ManualPeerTarget> full = List<ManualPeerTarget>.generate(
        kMaxManualPeers,
        (int i) => ManualPeerTarget(host: '10.0.0.${i + 1}', port: _kPort),
        growable: false,
      );
      await pumpShell(
        tester,
        backend: FakeBackend(
          settings: AppSettings(
            alias: 'Me',
            saveDirectory: '/received',
            manualPeers: full,
          ),
          online: <DiscoveredPeer>[
            DiscoveredPeer(
              fingerprint: _kFp,
              alias: 'Alice Phone',
              kind: DeviceKind.mobile,
              address: _kHost,
              port: _kPort,
              isOnline: true,
              lastSeen: fixedEpoch,
            ),
          ],
        ),
        settle: true,
      );

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_kEntryLabel));
      await tester.pumpAndSettle();
      expect(find.byType(ManualPeerDialog), findsNothing,
          reason: 'the ninth address can only ever end in 「最多保存 8 个」; the '
              'menu item is disabled for the same reason the 设置 row is');
    });
  });

  group('2. the dialog collects the address and parses nothing', () {
    testWidgets('IP and IP:port are returned exactly as typed', (
      WidgetTester tester,
    ) async {
      final List<String?> answers = <String?>[];
      await pumpApp(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              answers.add(await showManualPeerDialog(context));
            },
            child: const Text('open'),
          ),
        ),
      );

      for (final String typed in <String>['192.168.1.23', '192.168.1.23:5000']) {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('手动添加设备'), findsOneWidget);

        await tester.enterText(find.byType(TextField), typed);
        await tester.tap(find.text('连接'));
        await tester.pumpAndSettle();

        expect(find.byType(ManualPeerDialog), findsNothing,
            reason: 'in pure-input mode 连接 closes immediately: the probe is the '
                'controller\'s job');
        expect(answers.last, typed,
            reason: 'the string must arrive untouched — a port appended here '
                'would be a second parser, and the two would disagree');
      }
      // A cancel answers `null`, never an empty string: "nothing to do" and "the
      // user typed an empty address" are different answers.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(answers.last, isNull);
    });

    testWidgets('an empty field does not submit', (WidgetTester tester) async {
      final List<String?> answers = <String?>[];
      await pumpApp(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              answers.add(await showManualPeerDialog(context));
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();

      expect(find.byType(ManualPeerDialog), findsOneWidget,
          reason: 'a blank field is not an address; closing would hand the '
              'controller a `badInput` about a field the user never filled');
      expect(answers, isEmpty);
    });

    testWidgets('a failure keeps the dialog open and says why', (
      WidgetTester tester,
    ) async {
      // The waiting mode: the callback is the controller's job, and a message
      // keeps the dialog up with the typed address still in the field.
      await pumpApp(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showManualPeerDialog(
              context,
              onConnect: (String input) async => '连不上。',
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '10.0.0.99');

      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();

      expect(find.byType(ManualPeerDialog), findsOneWidget);
      expect(find.text('连不上。'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '10.0.0.99',
        reason: 'the wrong digit is still there to be fixed — reopening the '
            'dialog to retype the whole address is the failure this avoids',
      );
    });
  });

  group('3. connecting from the empty list puts the device in it', () {
    testWidgets('the card appears, and the address is remembered', (
      WidgetTester tester,
    ) async {
      final FakeBackend backend = FakeBackend();
      backend.discovery.setManualProbeOutcome(
        const ManualProbeOk(
          fingerprint: _kFp,
          alias: 'Alice Phone',
          port: _kPort,
          host: _kHost,
        ),
      );
      // The empty state is a scrolling column (the four hints, then the door), so
      // the surface has to be tall enough for the door to be **tappable** — this
      // is a layout fact of the shipped screen, not a workaround.
      useSurfaceSize(tester, const Size(800, 1200));
      await pumpShell(tester, backend: backend, settle: true);
      expect(find.text(_kEntryLabel), findsOneWidget, reason: 'precondition');

      await tester.tap(find.text(_kEntryLabel));
      await tester.pumpAndSettle();
      // By key, not `byType(TextField)`: the shell's device-name search field is
      // still mounted behind the dialog.
      await tester.enterText(
        find.byKey(const ValueKey<String>('manual-peer-input')),
        '$_kHost:$_kPort',
      );
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();

      expect(find.byType(ManualPeerDialog), findsNothing);
      expect(find.text('Alice Phone'), findsOneWidget,
          reason: 'the device appearing is the whole answer — no "连接成功" popup');
      expect(find.text(_kEntryLabel), findsNothing,
          reason: 'and the list is no longer empty');
      expect(backend.discovery.probeHostCalls, <String>['$_kHost:$_kPort']);
      expect(
        backend.platform.presetSettings.manualPeers,
        <ManualPeerTarget>[const ManualPeerTarget(host: _kHost, port: _kPort)],
        reason: 'remembered, so a restart does not ask for the address again',
      );
    });
  });

  group('4. 设置 → 手动添加的设备 (both layouts)', () {
    /// A backend with two stored addresses, one of which is a live peer.
    FakeBackend seeded({required bool mobile}) => FakeBackend(
          mobile: mobile,
          settings: const AppSettings(
            alias: 'Me',
            saveDirectory: '/received',
            manualPeers: <ManualPeerTarget>[
              ManualPeerTarget(host: _kHost, port: _kPort),
              ManualPeerTarget(host: '10.0.0.7', port: 50000),
            ],
          ),
          online: <DiscoveredPeer>[
            DiscoveredPeer(
              fingerprint: _kFp,
              alias: 'Alice Phone',
              kind: DeviceKind.mobile,
              address: _kHost,
              port: _kPort,
              isOnline: true,
              lastSeen: fixedEpoch,
            ),
          ],
        );

    /// Taps 移除 on the first address and judges the three consequences.
    Future<void> judgeRemoval(WidgetTester tester, FakeBackend backend) async {
      expect(find.text('手动添加的设备'), findsOneWidget);
      expect(find.text('$_kHost:$_kPort'), findsOneWidget);
      expect(find.text('10.0.0.7:50000'), findsOneWidget);
      // The live set the heartbeat dials, seeded the way a cold start seeds it.
      backend.discovery.addManualTarget(_kHost, _kPort);
      backend.discovery.addManualTarget('10.0.0.7', 50000);

      await tester.tap(
        find.byKey(const ValueKey<String>('manual-peer-remove-$_kHost:$_kPort')),
      );
      await tester.pumpAndSettle();

      expect(find.text('$_kHost:$_kPort'), findsNothing,
          reason: 'the row goes — that is the visible half of "stop dialling this"');
      expect(find.text('10.0.0.7:50000'), findsOneWidget,
          reason: 'the others stay');
      expect(
        backend.platform.presetSettings.manualPeers,
        <ManualPeerTarget>[const ManualPeerTarget(host: '10.0.0.7', port: 50000)],
        reason: 'the document is edited, so the removal survives a restart',
      );
      expect(
        backend.discovery.removedManualTargets,
        <ManualPeerTarget>[const ManualPeerTarget(host: _kHost, port: _kPort)],
        reason: 'and the heartbeat really stops dialling it',
      );
      expect(backend.discovery.online, hasLength(1),
          reason: 'the device is NOT deleted — forgetting a dial address and '
              'deleting a device are different intentions');
    }

    testWidgets('desktop: rows with a 移除 each', (WidgetTester tester) async {
      final FakeBackend backend = seeded(mobile: false);
      await pumpShell(
        tester,
        backend: backend,
        settle: true,
        initialModule: ShellModule.settings,
      );
      await judgeRemoval(tester, backend);
    });

    testWidgets('phone: the same block in the Flix card shape', (
      WidgetTester tester,
    ) async {
      // Narrow enough for the phone shell **and** tall enough that the block
      // below the settings card is laid out (a lazily-built `ListView` would
      // otherwise not build a row that never came into view).
      useSurfaceSize(tester, const Size(400, 1600));
      final FakeBackend backend = seeded(mobile: true);
      await pumpShell(
        tester,
        backend: backend,
        settle: true,
        initialModule: ShellModule.settings,
      );
      await judgeRemoval(tester, backend);
    });

    testWidgets('with no stored address the block still offers 添加设备地址', (
      WidgetTester tester,
    ) async {
      // ★ Settings must actually be **loaded**, not merely absent: the page shows
      // a loading state until the document arrives, and the previous version of
      // this test ("the block is not drawn") was passing for that reason — it
      // would have kept passing whatever the block did.
      await pumpShell(
        tester,
        backend: FakeBackend(
          settings: const AppSettings(alias: 'Me', saveDirectory: '/received'),
        ),
        settle: true,
        initialModule: ShellModule.settings,
      );
      expect(find.text('正在读取设置…'), findsNothing,
          reason: 'precondition: the document arrived');
      // ★ 0.2.56 — the block is permanent. Hiding it while empty was what made the
      // feature add-only-once: the heading is the one place the count lives, and
      // the row inside it is the door that survives a non-empty device list.
      expect(find.text('手动添加的设备'), findsOneWidget);
      expect(find.text(kManualPeerAddLabel), findsOneWidget);
      expect(find.text('0 / 8'), findsOneWidget,
          reason: 'the count is not decoration — 8 is the most the serial '
              'heartbeat can re-dial inside one 25 s period');

      await tester.tap(find.text(kManualPeerAddLabel));
      await tester.pumpAndSettle();
      expect(find.byType(ManualPeerDialog), findsOneWidget,
          reason: 'same dialog, same controller call as the device list — one '
              'path, three doors');
    });

    testWidgets('at the cap the add row is disabled instead of refusing', (
      WidgetTester tester,
    ) async {
      final List<ManualPeerTarget> full = List<ManualPeerTarget>.generate(
        kMaxManualPeers,
        (int i) => ManualPeerTarget(host: '10.0.0.${i + 1}', port: _kPort),
        growable: false,
      );
      // Tall surface so every row of the block (which sits below the settings
      // card) is laid out; a lazily-built row that never came into view would
      // make this pass for the wrong reason.
      useSurfaceSize(tester, const Size(600, 3000));
      await pumpShell(
        tester,
        backend: FakeBackend(
          settings: AppSettings(
            alias: 'Me',
            saveDirectory: '/received',
            manualPeers: full,
          ),
        ),
        settle: true,
        initialModule: ShellModule.settings,
      );

      expect(find.text(kManualPeerFullLabel), findsOneWidget);
      expect(find.text('$kMaxManualPeers / $kMaxManualPeers'), findsNothing,
          reason: 'a full row that still invites a tap is the 「tappable but '
              'inert」 shape (docs/18 §8.2)');

      await tester.tap(find.text(kManualPeerAddLabel));
      await tester.pumpAndSettle();
      expect(find.byType(ManualPeerDialog), findsNothing,
          reason: 'the dialog could only ever end in the capacity sentence');
    });
  });

  test('the capacity sentences name the number the rule actually uses', () {
    // The cap is stated in **three** places: `kMaxManualPeers` (the rule) plus two
    // sentences in `format.dart` that spell the number out. Widget tests cannot
    // catch drift between them — the assertions that mention `已满` compare two
    // values that are both derived from the same constant on one side, so raising
    // the rule alone would leave the row reading 「已满 8 个」 at 10/10.
    expect(kManualPeerFullLabel, contains('$kMaxManualPeers'),
        reason: 'the row would claim the old limit on screen');
    expect(kManualPeerAtCapacity, contains('$kMaxManualPeers'),
        reason: 'the refusal would quote a number the rule no longer uses');
  });
}
