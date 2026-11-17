/// 0.2.58 — **「what am I?」 must be answerable on the machine you are sitting at.**
///
/// ## The two gaps this file judges
///
/// 1. **The desktop could not see its own address at all.** `NetworkStatusRow` —
///    the only door to `LocalInfoSheet` — is drawn `if (carded)`, and `carded` is
///    `!showHeader`, which only `PhoneShell` passes. The single port the desktop
///    ever printed was `about_page.dart`'s hardcoded 49494. So "connect by hand
///    from the computer" required walking to the phone first to read *its*
///    address.
/// 2. **「手动添加设备」 asked for the peer's address and said nothing about this
///    device** — so the user had to know a fact the app never showed them.
///
/// ## What is asserted, and why it can go red
///
/// * the dialog **shows** both values when it is given them;
/// * the copy buttons really write the clipboard — captured at the
///   `SystemChannels.platform` boundary, so "the button was tapped" is not
///   mistaken for "the value is on the clipboard", and the address copy is
///   asserted to be the **bare IP** (a `:49494` glued on would have to be edited
///   out by hand at the other end);
/// * with no address, the block is **absent** and no `192.168…` string appears
///   anywhere in the dialog — "do not invent an address" is judged as "there is
///   no such string", not merely "the block is missing";
/// * each of the **four doors** (empty list, desktop header ⋮, phone ⋮, 设置's add
///   row) opens the dialog with the address wired in — the wiring is per call
///   site, so one door proves nothing about the others;
/// * 设置 → 本机信息 exists on **both** layouts and opens the real sheet with the
///   real values.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/peer_discovery.dart';
import 'package:lanlink_app/ui/format.dart';
import 'package:lanlink_app/ui/panes/settings_body.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/widgets/local_info_sheet.dart';
import 'package:lanlink_app/ui/widgets/manual_peer_dialog.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The address and port the fixture's device reports as **its own**.
const String _selfAddress = '10.1.2.3';
const int _selfPort = 49494;

/// The dialog's keys (see `manual_peer_dialog.dart`).
const Key _kBlock = ValueKey<String>('manual-peer-local-address');
const Key _kCopyAddress = ValueKey<String>('manual-peer-copy-address');
const Key _kCopyPort = ValueKey<String>('manual-peer-copy-port');
const Key _kMissing = ValueKey<String>('manual-peer-local-address-missing');
const Key _kInput = ValueKey<String>('manual-peer-input');

/// The peer a populated list shows, so the ⋮ doors are reachable.
const String _kPeerFp = 'A1A1A1A1';

/// Records everything written to the clipboard through the platform channel.
///
/// `Clipboard.setData` never touches the widget tree — it is a `MethodCall` on
/// `SystemChannels.platform` — so the only way to judge "the value really went to
/// the clipboard" is to sit on that channel. The framework's own clipboard tests
/// mock it exactly this way; the handler is cleared afterwards so no later test
/// inherits it.
List<String> recordClipboard(WidgetTester tester) {
  final List<String> written = <String>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        final Map<Object?, Object?> args =
            call.arguments as Map<Object?, Object?>;
        written.add(args['text'] as String);
      }
      return null;
    },
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return written;
}

/// A backend whose discovery status names this device [address] / [port].
///
/// The real `DiscoveryStatus` only carries an address once the NIC is chosen; the
/// fake's default is a different address on purpose, so a test that reads the
/// fixture's value cannot pass by accidentally matching a constant.
///
/// [withPeer] decides whether the device list has a row: the list header's ⋮ door
/// only exists over a populated list, the 手动填写 IP 连接 button only over an
/// empty one.
FakeBackend backendWith({
  String? address = _selfAddress,
  int? port = _selfPort,
  bool withPeer = true,
}) =>
    FakeBackend(
      status: DiscoveryStatus(
        phase: DiscoveryPhase.running,
        selfAlias: 'Workstation',
        selfAddress: address,
        selfPort: port,
        selfFingerprint: 'AB12CD34',
      ),
      online: withPeer
          ? <DiscoveredPeer>[
              DiscoveredPeer(
                fingerprint: _kPeerFp,
                alias: 'Alice Phone',
                kind: DeviceKind.mobile,
                address: '192.168.1.10',
                port: 53317,
                isOnline: true,
                lastSeen: fixedEpoch,
              ),
            ]
          : const <DiscoveredPeer>[],
    );

/// Any widget inside [root] whose text **is** an IPv4 address.
///
/// Used for the "do not invent one" judgement. A plain `textContaining('192.168')`
/// cannot carry that judgement: the peer field's own hint is
/// `192.168.1.23 或 192.168.1.23:49494`, an *example* the dialog may show. What
/// must not exist is a string that reads as **this device's** address, i.e. one
/// that is nothing but four octets.
Finder ipTextInside(Finder root) => find.descendant(
      of: root,
      matching: find.byWidgetPredicate(
        (Widget widget) =>
            widget is Text &&
            RegExp(r'^(\d{1,3}\.){3}\d{1,3}$')
                .hasMatch((widget.data ?? '').trim()),
      ),
    );

void main() {
  group('1. the dialog states this device\'s own address', () {
    testWidgets('both values are visible, and the block says what it is for', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        const ManualPeerDialog(localAddress: _selfAddress, localPort: _selfPort),
        settle: true,
      );

      expect(find.text(kManualPeerLocalAddressTitle), findsOneWidget,
          reason: 'the heading must say this is the string the *other* machine '
              'wants — otherwise the block reads as "your address, FYI"');
      expect(find.text(_selfAddress), findsOneWidget);
      expect(find.text('$_selfPort'), findsOneWidget);
      expect(find.byKey(_kBlock), findsOneWidget);
      // The peer's field is still the point of the dialog.
      expect(find.byKey(_kInput), findsOneWidget);
    });

    testWidgets('copy really writes the clipboard — bare IP, then the port', (
      WidgetTester tester,
    ) async {
      final List<String> clipboard = recordClipboard(tester);
      await pumpApp(
        tester,
        const ManualPeerDialog(localAddress: _selfAddress, localPort: _selfPort),
        settle: true,
      );

      await tester.tap(find.byKey(_kCopyAddress));
      await tester.pumpAndSettle();
      expect(clipboard, <String>[_selfAddress],
          reason: 'the address copy must be the **bare IP**: the peer types into '
              'an address field, and a `:49494` appended here would have to be '
              'deleted by hand at the other end');

      await tester.tap(find.byKey(_kCopyPort));
      await tester.pumpAndSettle();
      expect(clipboard, <String>[_selfAddress, '$_selfPort'],
          reason: 'and the port is copied on its own, as digits');

      // The in-place ✓ is the only confirmation a dialog can show without a
      // SnackBar (the route's barrier would dim it): prove the icon changed, so a
      // handler that copied but never acknowledged cannot pass.
      expect(
        find.descendant(
          of: find.byKey(_kCopyAddress),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_kCopyPort),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no address → no block, a reason instead, and NO invented IP', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        const ManualPeerDialog(localAddress: null, localPort: null),
        settle: true,
      );

      expect(find.byKey(_kBlock), findsNothing);
      expect(find.byKey(_kMissing), findsOneWidget);
      expect(find.text(kManualPeerLocalAddressMissing), findsOneWidget);
      expect(find.byKey(_kCopyAddress), findsNothing,
          reason: 'there is nothing to copy, so there must be nothing to press');
      // The judgement that matters: **a made-up address is the one failure the
      // user cannot detect**. Nothing in the dialog may read as an address — not
      // the block, not the missing line, not anywhere else.
      expect(ipTextInside(find.byType(AlertDialog)), findsNothing,
          reason: 'the dialog must say it does not know, never guess');
    });

    testWidgets('the placeholder counts as "not known", not as an address', (
      WidgetTester tester,
    ) async {
      // `DiscoveryStatus.selfAddress` arrives here as `null` from the controller,
      // but the 本机信息 sheet's own fallback (`（未获取）`) is a string a caller can
      // hand over by mistake. Printing it as an address would be worse than the
      // grey line.
      await pumpApp(
        tester,
        const ManualPeerDialog(localAddress: kSelfAddressUnknown),
        settle: true,
      );

      expect(find.byKey(_kBlock), findsNothing);
      expect(find.byKey(_kMissing), findsOneWidget);
      expect(find.text(kSelfAddressUnknown), findsNothing);
    });

    testWidgets('an address with no port still shows — the copy button waits', (
      WidgetTester tester,
    ) async {
      final List<String> clipboard = recordClipboard(tester);
      await pumpApp(
        tester,
        const ManualPeerDialog(localAddress: _selfAddress),
        settle: true,
      );

      expect(find.text(_selfAddress), findsOneWidget);
      expect(find.text(kManualPeerLocalPortMissing), findsOneWidget,
          reason: 'a port that is not known says so; the row is not hidden, '
              'because "the port" is the second half of the answer');
      expect(
        tester.widget<IconButton>(find.byKey(_kCopyPort)).onPressed,
        isNull,
        reason: 'copying the string 「未获取」 would be a lie the user can only '
            'discover by pasting',
      );
      expect(clipboard, isEmpty);
    });
  });

  group('2. every door passes this device\'s address in (four call sites)', () {
    /// Asserts the dialog is up **and carries the block** with [address].
    ///
    /// Scoped to the dialog: 设置's own 「本机信息」 row shows the same address
    /// behind it, so an unscoped `find.text` would be counting the page, not the
    /// dialog, and would pass even if the caller dropped `localAddress`.
    void judgeDialog(String address) {
      expect(find.byType(ManualPeerDialog), findsOneWidget);
      expect(find.byKey(_kBlock), findsOneWidget,
          reason: 'the dialog is open but says nothing about this device — the '
              'caller dropped localAddress, which is exactly the 0.2.58 gap');
      expect(
        find.descendant(
          of: find.byType(ManualPeerDialog),
          matching: find.text(address),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ManualPeerDialog),
          matching: find.text('$_selfPort'),
        ),
        findsOneWidget,
      );
    }

    testWidgets('door ①: the empty device list', (WidgetTester tester) async {
      useSurfaceSize(tester, const Size(800, 1200));
      // No peers: this is the *empty list*, whose footer carries the button.
      final FakeBackend backend = backendWith(withPeer: false);
      addTearDown(backend.dispose);
      await pumpShell(tester, backend: backend, settle: true);

      await tester.tap(find.byKey(const ValueKey<String>('manual-peer-entry')));
      await tester.pumpAndSettle();
      judgeDialog(_selfAddress);
    });

    testWidgets('door ②: the desktop list header ⋮', (
      WidgetTester tester,
    ) async {
      final FakeBackend backend = backendWith();
      addTearDown(backend.dispose);
      await pumpShell(tester, backend: backend, settle: true);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kManualPeerActionLabel));
      await tester.pumpAndSettle();
      judgeDialog(_selfAddress);
    });

    testWidgets('door ③: the phone top-bar ⋮', (WidgetTester tester) async {
      useSurfaceSize(tester, const Size(400, 900));
      final FakeBackend backend = backendWith();
      addTearDown(backend.dispose);
      await pumpShell(tester, backend: backend, settle: true);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kManualPeerActionLabel));
      await tester.pumpAndSettle();
      judgeDialog(_selfAddress);
    });

    testWidgets('door ④: 设置 → 添加设备地址', (WidgetTester tester) async {
      useSurfaceSize(tester, const Size(600, 1200));
      final FakeBackend backend = backendWith();
      addTearDown(backend.dispose);
      await pumpShell(
        tester,
        backend: backend,
        settle: true,
        initialModule: ShellModule.settings,
      );

      await tester.tap(find.text(kManualPeerAddLabel));
      await tester.pumpAndSettle();
      judgeDialog(_selfAddress);
    });
  });

  group('3. 设置 → 本机信息 (both layouts)', () {
    /// Opens the row and judges the sheet behind it.
    Future<void> judgeSheet(WidgetTester tester, FakeBackend backend) async {
      expect(find.text(kLocalInfoTitle), findsOneWidget,
          reason: 'the row itself must be on the settings page');
      // The row's grey value is the live address — a settings page should answer
      // "what am I" without a tap.
      final Finder row = find.ancestor(
        of: find.text(kLocalInfoTitle),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: row, matching: find.text(_selfAddress)),
        findsOneWidget,
        reason: 'the value slot carries the address, not an empty gap',
      );

      await tester.tap(find.text(kLocalInfoTitle));
      await tester.pumpAndSettle();

      // The really-existing sheet, not a copy of it.
      expect(find.byKey(kLocalInfoSheetKey), findsOneWidget);
      final Finder sheet = find.byKey(kLocalInfoSheetKey);
      final DiscoveryStatus status = backend.discovery.status;
      expect(status.selfAddress, _selfAddress, reason: 'precondition');
      expect(status.selfPort, _selfPort, reason: 'precondition');
      expect(
        find.descendant(of: sheet, matching: find.text(_selfAddress)),
        findsOneWidget,
        reason: 'the sheet shows the address the discovery layer reported',
      );
      expect(
        find.descendant(of: sheet, matching: find.text('$_selfPort')),
        findsOneWidget,
        reason: 'and the port — the number the other machine has to type',
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Workstation')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text(kLocalInfoTitle)),
        findsOneWidget,
        reason: 'the constant the settings row uses is the word the sheet draws '
            '— one string, two places (a comment cannot keep these in step)',
      );
    }

    testWidgets('desktop: the row exists and opens the sheet', (
      WidgetTester tester,
    ) async {
      useSurfaceSize(tester, const Size(1400, 1000));
      final FakeBackend backend = backendWith();
      addTearDown(backend.dispose);
      await pumpShell(
        tester,
        backend: backend,
        settle: true,
        initialModule: ShellModule.settings,
      );
      await judgeSheet(tester, backend);
    });

    testWidgets('phone: the same row, the same sheet', (
      WidgetTester tester,
    ) async {
      useSurfaceSize(tester, const Size(400, 1000));
      final FakeBackend backend = backendWith();
      addTearDown(backend.dispose);
      backend.platform.setMobile(true);
      await pumpShell(
        tester,
        backend: backend,
        settle: true,
        initialModule: ShellModule.settings,
      );
      await judgeSheet(tester, backend);
    });

    testWidgets('with no address the row says so instead of guessing', (
      WidgetTester tester,
    ) async {
      useSurfaceSize(tester, const Size(1400, 1000));
      final FakeBackend backend = backendWith(address: null, port: null);
      addTearDown(backend.dispose);
      await pumpShell(
        tester,
        backend: backend,
        settle: true,
        initialModule: ShellModule.settings,
      );

      final Finder row = find.ancestor(
        of: find.text(kLocalInfoTitle),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: row, matching: find.text(kSelfAddressUnknown)),
        findsOneWidget,
      );
      expect(ipTextInside(find.byType(SettingsBody)), findsNothing,
          reason: 'no address is known, so the page shows none');
    });
  });
}
