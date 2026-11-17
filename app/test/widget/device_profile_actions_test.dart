/// The media wall's cards are **actionable** (0.2.59) — and the way in has a
/// name that matches what it opens.
///
/// Two user reports, one page:
///  1. *"墙上的卡片点不开"* — true by construction: `DeviceProfilePage._card`
///     returned a bare `Column` with no gesture anywhere, so no card had ever
///     been clickable. Not a regression, a never-built;
///  2. *"选一个文件 → 跳到它当初被发出来的那条消息"* — the reason the wall exists
///     as a second door to the same attachments.
///
/// What this file pins, in the user's own terms:
///  * a **single tap opens the file**, through `openLocalPath` (the one shared
///    implementation), not through a private copy;
///  * a tap on a card whose file is **off disk** opens nothing and says
///    「文件已不在原位置，无法打开」 — the same sentence the timeline and the
///    文件 tab give (the wall must not be the fourth opinion);
///  * **long press** (a finger) and **right click** (a mouse) both open the same
///    two-row menu, in the fixed order 打开 → 转到消息;
///  * 「转到消息」 closes the page **with the owning message's id**, and the entry
///    that pushed it hands that id to `ConversationController.requestReveal`;
///  * the entry is called **媒体与文件** now, and 「设备设置」 is gone from both
///    layouts (the page never had settings in the first place — see the header
///    of `device_profile.dart`);
///  * the 「来源 时间」 line above a card is **exactly the card's width** — it used
///    to take the whole row (a 570-wide line over a 285-wide card on a phone), so
///    the time floated in empty space to the right of the card it belongs to.
///
/// Behavioural only: every assertion reads what a user could see or what the
/// fake platform port was asked to do.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/bootstrap/app_deps.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/home_controller.dart';
import 'package:lanlink_app/controllers/recent_files_controller.dart';
import 'package:lanlink_app/controllers/settings_controller.dart';
import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/device_profile.dart';
import 'package:lanlink_app/ui/shell/phone_shell.dart';
import 'package:lanlink_app/ui/shell/shell_controller.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';

import '../support/pump_app.dart';

/// The entry's label after 0.2.59 — one string, three places (phone bar,
/// desktop header, and the test that reads both).
const String _kEntry = '媒体与文件';

/// The label the entry carried before 0.2.59. It must not be findable anywhere:
/// two names for one door is exactly what the rename removes.
const String _kOldEntry = '设备设置';

/// The two menu rows, in their fixed order.
const String _kOpen = '打开';
const String _kReveal = '转到消息';

/// What a tap on a card whose source is gone answers (identical to the
/// timeline's and the 文件 tab's wording — one sentence, one meaning).
const String _kGoneNotice = '文件已不在原位置，无法打开';

/// `Scenarios.e16SelectionSync`'s image attachment: its path, and the message it
/// arrived with. The wall's default filter is 图片, so this is the one card the
/// page draws before any tab is tapped.
const String _kPhotoPath = '/received/photo.png';
const String _kPhotoMessageId = 'm-e16-photo';
const String _kConversationId = 'c-e16';

/// The peer `e16SelectionSync` is about — `initialPeer` has to be dialable, and
/// `openActive` resolves it to [_kConversationId].
PeerDevice _peer() => const PeerDevice(
      fingerprint: 'AAAA1111',
      alias: 'Alice Laptop',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// The wall card of the one image in the fixture — scoped to the page, because
/// the conversation underneath the pushed route is still mounted (so a bare
/// `find.byType(FileThumbnail)` would also match the timeline's thumbnails).
Finder _photoCard() => find.descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.byType(FileThumbnail),
    );

/// The 损毁 card's glyph — the tap target when the source is off disk (there is
/// no `FileThumbnail` in that state by design: `_isBroken` chooses the white
/// card). Tapping the glyph still reaches the card's `GestureDetector`, which is
/// an ancestor of it.
Finder _brokenCard() => find.descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.byIcon(Icons.broken_image_outlined),
    );

/// The card's `yyyy-MM-dd HH:mm` paragraph.
Finder _timeText() => find
    .descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.textContaining(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
    )
    .first;

/// The 「来源 时间」 **row** — the nearest `Row` above the time paragraph.
///
/// `find.ancestor` orders its matches from the closest ancestor outward
/// (`_AncestorFinderMixin._collectAncestors` walks up with
/// `visitAncestorElements`), so `.first` is the meta line and not, say, the
/// filter row above the wall or the wide wall's own per-row `Row`.
Finder _metaRow() =>
    find.ancestor(of: _timeText(), matching: find.byType(Row)).first;

/// A [ConversationController] that **records** every 「转到消息」 request.
///
/// A spy rather than a real assertion on `pendingRevealId` alone: the timeline
/// is free to *consume* the request (it exists to be consumed), so a test that
/// only reads the field afterwards would be green or red depending on when the
/// thread happens to look. The recording is what the contract actually says —
/// "the entry hands the id to the controller" — and `pendingRevealId` is
/// asserted too, because nothing consumes it in this harness (the pane is a
/// stub, so no thread is mounted).
class _RevealSpy extends ConversationController {
  _RevealSpy(AppDeps deps)
      : super(
          repo: deps.repo,
          orchestrator: deps.orchestrator,
          platform: deps.platform,
          ids: deps.ids,
          clock: deps.clock,
          conversationId: _kConversationId,
        );

  /// Every id handed to [requestReveal], in order.
  final List<String> revealed = <String>[];

  @override
  void requestReveal(String messageId) {
    revealed.add(messageId);
    super.requestReveal(messageId);
  }
}

void main() {
  /// Mounts the real phone shell at a narrow width with the profile **closed**.
  ///
  /// Used by the two tests that need a controller the test can watch: the shell's
  /// `conversationController` is normally created by `DetailPane`, which this
  /// harness replaces with a stub — so the spy below is the one the bar talks to,
  /// and nothing in the tree can consume the request behind the test's back.
  Future<(_RevealSpy, FakeBackend)> mountPhoneShellWithSpy(
    WidgetTester tester,
  ) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);
    final AppDeps deps = testDeps(backend);
    final ShellController shell = ShellController(
      repo: backend.repo,
      initialPeer: _peer(),
    );
    addTearDown(shell.dispose);
    final _RevealSpy spy = _RevealSpy(deps);
    addTearDown(spy.dispose);
    shell.conversationController = spy;
    final HomeController home = HomeController(
      repo: backend.repo,
      discovery: backend.discovery,
      transfer: backend.transfer,
      platform: backend.platform,
    );
    addTearDown(home.dispose);
    final RecentFilesController recentFiles = RecentFilesController(
      repo: backend.repo,
      platform: backend.platform,
    );
    addTearDown(recentFiles.dispose);
    final SettingsController settings = SettingsController(
      platform: backend.platform,
      discovery: backend.discovery,
      transfer: backend.transfer,
    );
    addTearDown(settings.dispose);
    await pumpApp(
      tester,
      PhoneShell(
        shell: shell,
        home: home,
        recentFiles: recentFiles,
        settings: settings,
        listPane: const SizedBox.shrink(),
        detailPane: const SizedBox.shrink(),
      ),
      backend: backend,
      settle: true,
    );
    return (spy, backend);
  }

  /// Mounts the real shell (phone width) and opens the page through the entry.
  ///
  /// [prepared] runs against the fake **before** the page is pushed, which is
  /// how the "file is off disk" case is set up: the page's source probe runs on
  /// its first frame, so the answer has to exist by then.
  Future<FakeBackend> openProfile(
    WidgetTester tester, {
    void Function(FakeBackend backend)? prepared,
    Size size = const Size(600, 800),
  }) async {
    useSurfaceSize(tester, size);
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    if (size.width < 760) {
      backend.platform.setMobile(true);
    }
    prepared?.call(backend);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer(),
    );
    await tester.tap(find.byTooltip(_kEntry));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsOneWidget,
        reason: 'the entry is the only way in, so it has to work');
    return backend;
  }

  /// Lets a floating notice (2 s) expire so the test ends with no live timers.
  Future<void> drainNotice(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets(
      'entry: the door is called 媒体与文件, and 设备设置 is gone from the '
      'phone bar', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true, initialPeer: _peer());

    // RED before the rename: this was the only label the bar carried.
    expect(find.byTooltip(_kEntry), findsOneWidget);
    expect(find.byTooltip(_kOldEntry), findsNothing,
        reason: 'one door, one name — the old label promised settings the page '
            'deliberately does not have');
  });

  testWidgets(
      'entry: the desktop header carries the same 媒体与文件, and no 设备设置',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1400, 1000));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(tester, backend: backend, settle: true, initialPeer: _peer());

    expect(find.byTooltip(_kEntry), findsOneWidget,
        reason: 'the wide / compact header keeps its entry in the same slot');
    expect(find.byTooltip(_kOldEntry), findsNothing);
  });

  testWidgets('card: a single tap opens THIS file, through the shared port call',
      (WidgetTester tester) async {
    final FakeBackend backend = await openProfile(tester);

    await tester.tap(_photoCard());
    await tester.pumpAndSettle();

    expect(backend.platform.opened, <String>[_kPhotoPath],
        reason: 'the wall must hand the platform the card\'s own path — the '
            'same `openFile` the timeline and the 文件 tab use');
    expect(find.text(_kGoneNotice), findsNothing,
        reason: 'the file is on disk, so there is nothing to apologise for');
  });

  testWidgets(
      '★ card: a file that is off disk opens NOTHING and says why — the tap is '
      'not swallowed just because the card is 损毁',
      (WidgetTester tester) async {
    final FakeBackend backend = await openProfile(
      tester,
      prepared: (FakeBackend backend) =>
          backend.platform.setExists(_kPhotoPath, false),
    );

    // The card is drawn in its 损毁 state — that is `_isBroken`'s job, and it
    // still only decides which picture to paint.
    expect(_brokenCard(), findsOneWidget);

    await tester.tap(_brokenCard());
    await tester.pumpAndSettle();

    expect(backend.platform.opened, isEmpty,
        reason: 'never call the platform with a path we know is gone');
    expect(find.text(_kGoneNotice), findsOneWidget,
        reason: 'the same sentence the timeline and the 文件 tab give — the wall '
            'is not a fourth opinion');
    await drainNotice(tester);
  });

  testWidgets(
      'menu: long press opens 打开 then 转到消息 — two rows, fixed order, both '
      'live (long press = the phone gesture)', (WidgetTester tester) async {
    final FakeBackend backend = await openProfile(tester);

    await tester.longPress(_photoCard());
    await tester.pumpAndSettle();

    expect(find.text(_kOpen), findsOneWidget);
    expect(find.text(_kReveal), findsOneWidget);
    // 打开 is what the card's own tap does, so it leads.
    expect(
      tester.getTopLeft(find.text(_kOpen)).dy,
      lessThan(tester.getTopLeft(find.text(_kReveal)).dy),
      reason: 'the order is part of the menu, not an accident of building',
    );

    // 「打开」 is not a decoration: it does what the single tap does.
    await tester.tap(find.text(_kOpen));
    await tester.pumpAndSettle();
    expect(backend.platform.opened, <String>[_kPhotoPath]);
    expect(find.byType(DeviceProfilePage), findsOneWidget,
        reason: '"open" must not also leave the page');
  });

  testWidgets(
      'menu: right click (the desktop gesture) opens the same two rows',
      (WidgetTester tester) async {
    final FakeBackend backend = await openProfile(
      tester,
      size: const Size(1400, 1000),
    );

    // A mouse's secondary button, not a long press: the desktop path has to be
    // wired too (`onSecondaryTapDown`), and it is the one that carries the
    // cursor position the menu opens at.
    await tester.tap(_photoCard(), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text(_kOpen), findsOneWidget);
    expect(find.text(_kReveal), findsOneWidget);
    expect(backend.platform.opened, isEmpty,
        reason: 'a right click opens a menu; it never opens the file by itself');
  });

  testWidgets(
      '★ 转到消息: the page closes with the owning message id, and the entry hands '
      'it to ConversationController.requestReveal',
      (WidgetTester tester) async {
    final (_RevealSpy spy, FakeBackend backend) =
        await mountPhoneShellWithSpy(tester);
    expect(backend.platform.opened, isEmpty);

    await tester.tap(find.byTooltip(_kEntry));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsOneWidget);

    await tester.longPress(_photoCard());
    await tester.pumpAndSettle();
    await tester.tap(find.text(_kReveal));
    await tester.pumpAndSettle();

    // 1. the page is gone — the user is back on the conversation.
    expect(find.byType(DeviceProfilePage), findsNothing,
        reason: '"转到消息" means leave this page, not stay on it');
    // 2. the id really is the message this file came in with.
    expect(spy.revealed, <String>[_kPhotoMessageId]);
    // 3. and it landed in the exact field the timeline reads.
    expect(spy.pendingRevealId, _kPhotoMessageId,
        reason: 'the request is parked on the controller because the controller '
            'is what survives a 消息 / 文件 tab switch');
    // The tap that opened the page and the menu must not have opened the file.
    expect(backend.platform.opened, isEmpty);
  });

  testWidgets(
      '★ a 损毁 card\'s menu greys 打开 (it cannot work) but keeps 转到消息 (it '
      'always can)', (WidgetTester tester) async {
    await openProfile(
      tester,
      prepared: (FakeBackend backend) =>
          backend.platform.setExists(_kPhotoPath, false),
    );

    await tester.longPress(_brokenCard());
    await tester.pumpAndSettle();

    // The row is *drawn* — greying out is the documented alternative to hiding
    // it (docs/19 §9.6) — but it is inert, and `fast_menu`'s key is how that is
    // read without reaching into a private widget.
    final InkWell openRow = tester.widget<InkWell>(
      find.byKey(const ValueKey<String>('fast-menu-open')),
    );
    expect(openRow.onTap, isNull,
        reason: 'an entry that could not work is greyed out, not left clickable');
    final InkWell revealRow = tester.widget<InkWell>(
      find.byKey(const ValueKey<String>('fast-menu-reveal')),
    );
    expect(revealRow.onTap, isNotNull,
        reason: '「转到消息」 needs no file on disk — it is about the message');
  });

  // ── 5. 「来源 时间」 is exactly as wide as the card (0.2.59) ───────────────
  //
  // The defect: the line had no width of its own, the wall's list hands its
  // children the **tight** row width, so on a 320-wide phone the time sat on a
  // 290-wide line above a 145-wide card, and on a desktop on a 1370-wide line
  // above a 240-wide card. Measured in logical px, on both sides of
  // `kNarrowBreakpoint` — because the fix must hold in the phone path *and* the
  // wide grid, and neither may move its card edge or its column count.
  for (final Size surface in <Size>[
    Size(320, 800),
    Size(600, 800),
    Size(1400, 1000),
  ]) {
    testWidgets(
        'meta line: the 「来源 时间」 row is the CARD\'s width, not the row\'s '
        '(${surface.width.toInt()}×${surface.height.toInt()})',
        (WidgetTester tester) async {
      await openProfile(tester, size: surface);

      final Rect card = tester.getRect(_photoCard());
      final Rect meta = tester.getRect(_metaRow());
      // The measured numbers, in the same style the grid test prints its own
      // geometry: a judgement about pixels should leave a trace of the pixels.
      debugPrint('[0.2.59] ${surface.width.toInt()}×${surface.height.toInt()}: '
          'card ${card.width.toStringAsFixed(2)} wide, '
          'meta line ${meta.width.toStringAsFixed(2)} wide, '
          'card right ${card.right.toStringAsFixed(1)}, '
          'time right ${tester.getTopRight(_timeText()).dx.toStringAsFixed(1)}');

      // The judgement asked for: two `getSize`s, compared.
      expect(meta.width, closeTo(card.width, 0.01),
          reason: 'the 来源/时间 line must be exactly the square\'s width — '
              'card ${card.width}, line ${meta.width}');
      // Same left edge, so "same width" also means "same column" (a line that
      // were merely centred would pass the width test and still look wrong).
      expect(meta.left, closeTo(card.left, 0.01),
          reason: 'the line starts on the card\'s own left edge');
      // …and the time therefore ends where the card ends, which is the thing
      // the user actually saw floating in the middle of nowhere.
      expect(tester.getTopRight(_timeText()).dx, closeTo(card.right, 0.5),
          reason: 'the time ends on the card\'s right edge');
      // Regression guard: the old defect was a line as wide as the row.
      expect(meta.width, lessThan(surface.width),
          reason: 'a line as wide as the window is the bug, not the fix');
      expect(tester.takeException(), isNull,
          reason: 'a narrower line may not overflow (the time scales down)');
    });
  }
}
