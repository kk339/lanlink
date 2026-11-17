/// Widget tests for **0.2.35 — Flutter's own widgets speak Chinese**.
///
/// The release is not a translation feature: every string this app writes is
/// Chinese at the call site. What was broken is the strings the app does **not**
/// write — the text-selection toolbar, a `TextField`'s long-press menu, tooltips,
/// picker buttons — which come from `MaterialLocalizations`. With no
/// `localizationsDelegates` declared, `MaterialApp` falls back to
/// `DefaultMaterialLocalizations`, i.e. **English only**, so those menus read
/// "Paste / Select all / Copy" inside an otherwise all-Chinese screen. 0.2.31
/// hand-translated the three labels of the timeline's selection menu; that fixed
/// one call site. 0.2.35 declares the real delegates (`lib/ui/localization.dart`)
/// in **both** `MaterialApp`s and deletes the hand translation.
///
/// What each case here is able to catch:
/// * **A** — the production root (`LanlinkApp`, `lib/app.dart`) advertises exactly
///   one locale, `zh_CN`, and `MaterialLocalizations.of` answers in Chinese from
///   inside the real shell. Delete the delegates and every label below flips back
///   to English.
/// * **B** — the app's **second** `MaterialApp` (`StartupErrorApp`, shown when
///   `createAppDeps` throws) is wired the same way. This is the screen a user
///   only ever sees when something is already wrong, and it is a
///   `SelectableText` — exactly the widget whose menu used to be English. It is a
///   separate `MaterialApp`, so it needs its own proof.
/// * **C** — a **rendered** framework tooltip: the licence page's `AppBar` back
///   button (reached from 关于 → 开源许可) says 「返回」, not "Back".
/// * **D** — the composer's own `TextField`: a long press opens 「剪切 / 复制 /
///   粘贴」, not "Cut / Copy / Paste". This is the *general* fix — 0.2.31 never
///   touched this menu at all.
///
/// The timeline's selection menu (criterion 2 of the release: 「复制 / 全选」, and
/// 复制 puts **only the dragged range** on the clipboard) is owned by
/// `message_copy_test.dart` and `selection_excludes_chrome_test.dart`. Those
/// cases are not duplicated here — they mount through `pump_app.dart`, which now
/// declares the *same* delegates as production, so they are asserting the menu
/// the user actually sees rather than an English one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/app.dart';
import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/main.dart';
import 'package:lanlink_app/ui/shell/shell_page.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The one locale the app ships. Spelled out rather than read from
/// `lib/ui/localization.dart` on purpose: a test that took its expectation from
/// the code under test would stay green if the constant itself were changed to
/// `en_US`.
const Locale _zh = Locale('zh', 'CN');

/// A dialable peer, i.e. one the composer will let us type to.
PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// The framework labels the whole release is about, asserted together so a
/// single missing delegate fails with the whole list visible (`reason` names the
/// cause: `DefaultMaterialLocalizations` is English-only).
///
/// Read from [MaterialLocalizations] rather than from the rendered tree because
/// this is the *contract*: every framework widget on this screen reads these
/// same getters, so if they are Chinese the menus are Chinese.
void _expectChineseFrameworkLabels(MaterialLocalizations loc, String where) {
  expect(loc.copyButtonLabel, '复制',
      reason: '$where: the selection toolbar\'s 复制 is '
          'MaterialLocalizations.copyButtonLabel — "Copy" means the '
          'localizationsDelegates are missing again');
  expect(loc.selectAllButtonLabel, '全选', reason: '$where: 全选');
  expect(loc.cutButtonLabel, '剪切', reason: '$where: 剪切');
  expect(loc.pasteButtonLabel, '粘贴',
      reason: '$where: this is the label the composer\'s long-press menu shows — '
          'the exact "Paste" the user reported');
  expect(loc.backButtonTooltip, '返回',
      reason: '$where: every automatic AppBar back button uses this tooltip');
}

void main() {
  testWidgets(
      'A: the PRODUCTION root (LanlinkApp) pins zh_CN, so every framework '
      'string inside the shell is Chinese', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await tester.pumpWidget(LanlinkApp(deps: testDeps(backend)));
    // NOT `pumpAndSettle`: the shell shows a loading spinner (an unbounded
    // animation) until the fake resolves (same reason as `theme_mode_test`).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final MaterialApp app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale, _zh,
        reason: 'the locale is **pinned**, not left to the OS: the app has one '
            'language, and following the system would give English framework '
            'strings next to Chinese app strings');
    expect(app.supportedLocales, <Locale>[_zh],
        reason: 'advertising more than zh_CN lets Flutter resolve another one '
            'from the platform');
    expect(app.localizationsDelegates, isNotNull);
    // Material + Widgets + Cupertino. The count is asserted because dropping the
    // Cupertino one throws at build time on iOS-shaped affordances instead of
    // rendering English — a silent-until-iOS failure worth pinning.
    expect(app.localizationsDelegates, hasLength(3));

    _expectChineseFrameworkLabels(
      MaterialLocalizations.of(tester.element(find.byType(ShellPage))),
      'production root',
    );
  });

  testWidgets(
      'B: the CRASH surface — the second MaterialApp — is Chinese too, so the '
      'one screen shown when startup failed is not half English',
      (WidgetTester tester) async {
    await tester.pumpWidget(StartupErrorApp(
      error: StateError('数据库打不开'),
      stackTrace: StackTrace.current,
    ));
    await tester.pump();

    // It is genuinely the crash surface, not a blank frame: the Chinese caption
    // and the reason are on screen.
    expect(find.textContaining('lanlink 启动失败'), findsOneWidget);
    expect(find.textContaining('数据库打不开'), findsOneWidget);

    // The `SelectableText` is the reason this surface needs the delegates: its
    // long-press / right-click menu is `MaterialLocalizations`.
    _expectChineseFrameworkLabels(
      MaterialLocalizations.of(
        tester.element(find.byType(SelectableText)),
      ),
      'crash surface',
    );
  });

  testWidgets(
      'C: a rendered framework tooltip is Chinese — the licence page\'s AppBar '
      'back button says 返回, and "Back" is nowhere', (WidgetTester tester) async {
    // 900dp is the desktop (lateral) licence layout; the phone layout is a
    // different `AppBar`, and both take their leading button from the same
    // localization, so one of them is enough to falsify "the tooltip is English".
    useSurfaceSize(tester, const Size(900, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    await pumpApp(
      tester,
      Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'lanlink',
                applicationVersion: '0.2.35',
              ),
              child: const Text('开源许可'),
            ),
          ),
        ),
      ),
      backend: backend,
      settle: true,
    );

    await tester.tap(find.text('开源许可'));
    // NOT `pumpAndSettle`: the licence list streams in and can keep a progress
    // indicator spinning forever (`about_page_test` documents the same trap).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(LicensePage), findsOneWidget,
        reason: 'showLicensePage pushed the real licence page');
    expect(find.byTooltip('返回'), findsOneWidget,
        reason: 'the AppBar back button\'s tooltip is '
            'MaterialLocalizations.backButtonTooltip — before 0.2.35 it read '
            '"Back"');
    expect(find.byTooltip('Back'), findsNothing,
        reason: 'a surviving "Back" tooltip means the delegates are not reached '
            'by this route');
  });

  testWidgets(
      'D: the composer\'s own TextField long press opens 粘贴 / 全选 — the '
      'general bug 0.2.31 never touched', (WidgetTester tester) async {
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // A phone: the long press is the natural gesture there, and this menu is the
    // one the release report is literally about ("输入框长按是 Paste").
    backend.platform.setMobile(true);
    // **A clipboard with something in it.** Flutter only offers 粘贴 when it
    // believes the clipboard is pasteable, and `Clipboard.hasStrings` goes
    // through the platform channel — unmocked it answers "no", the entry is
    // dropped, and this test would assert on a menu that simply lacks the very
    // label it is about. Mapped to what a real device answers after any copy.
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (MethodCall call) async {
      switch (call.method) {
        case 'Clipboard.hasStrings':
          return <String, dynamic>{'value': true};
        case 'Clipboard.getData':
          return <String, dynamic>{'text': '外面的文字'};
      }
      return null;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    backend.repo.addConversation(
      id: 'c-loc',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-loc',
      conversationId: 'c-loc',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '先有一条',
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
      conversationId: 'c-loc',
      drafts: ComposerDraftStore(),
    );
    addTearDown(controller.dispose);

    unawaited(controller.load());
    await pumpApp(
      tester,
      Scaffold(
        body: ConversationThread(controller: controller, peer: _peer()),
      ),
      backend: backend,
      settle: true,
    );

    final Finder field = find.byType(TextField);
    expect(field, findsOneWidget, reason: 'the composer is the only TextField');
    await tester.enterText(field, '第一段话');
    await tester.pumpAndSettle();

    await tester.longPress(field);
    await tester.pumpAndSettle();

    final Finder toolbar = find.byType(AdaptiveTextSelectionToolbar);
    expect(toolbar, findsOneWidget,
        reason: 'a long press must open the editing menu at all — if this is '
            'absent the assertion below proves nothing');

    Finder inToolbar(String label) =>
        find.descendant(of: toolbar, matching: find.text(label));

    // A long press leaves a **collapsed** selection, so Flutter's own rules give
    // exactly two entries here: 粘贴 (the clipboard has content) and 全选 (the
    // field has text that is not all selected). That is the pair the release
    // criterion names, and it is Flutter deciding — the test only checks the
    // language. 剪切 / 复制 are absent by the same rules, which is why they are
    // asserted as absent rather than demanded: inventing them would be testing
    // this app's opinion of Flutter's menu, not Flutter's.
    expect(inToolbar('粘贴'), findsOneWidget,
        reason: 'the long-press menu must read 粘贴; it was "Paste"');
    expect(inToolbar('全选'), findsOneWidget,
        reason: 'the long-press menu must read 全选; it was "Select all"');
    expect(inToolbar('复制'), findsNothing,
        reason: 'a collapsed selection has nothing to copy (Flutter\'s rule, '
            'unchanged by 0.2.35) — if this appears, the menu is no longer '
            'Flutter\'s');
    expect(inToolbar('剪切'), findsNothing,
        reason: 'same rule as 复制: nothing is selected yet');

    // The negative direction: the English labels are gone from the toolbar
    // entirely, not merely accompanied by Chinese ones.
    for (final String english in <String>[
      'Paste',
      'Copy',
      'Cut',
      'Select all',
    ]) {
      expect(inToolbar(english), findsNothing,
          reason: 'the editing menu still renders "$english" — English in an '
              'all-Chinese screen is the exact bug 0.2.35 removes');
    }
  });
}
