/// Widget tests for the 「关于」 page (M5 §F).
///
/// The entry lives in the settings module on **both** layouts since 0.2.24: the
/// phone's `_phoneBody` always had the 关于 row (version beside the `›`), and the
/// desktop's `_desktopBody` now has the same row through the same `_navRow`.
/// Before that the desktop had none, and the page was unreachable there — see the
/// last test's comment for how the old assertion hid it. The version shown is the
/// single code constant [kAppVersion] (guard-tested against `pubspec.yaml`).
///
/// **0.2.21 changed the page's shape**, so the assertions below changed with it —
/// and the change is the point, not a re-point to a weaker check:
/// * the page used to be "one-liner + three bullets + 使用简介"; it is now the
///   mainstream shape (identity block / read-only 信息 group / tappable 其他
///   group / copyright);
/// * the six 使用简介 steps **must no longer be here** — they moved to
///   [HelpPage] (`help_page_test.dart` owns their verbatim content);
/// * the 信息 rows must **not** be `ListTile`s (docs/18 §8.2: a row that cannot be
///   tapped must not look tappable) while the 其他 rows must be;
/// * the icon is the user's real artwork, not a drawn placeholder.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/app_info.dart';
import 'package:lanlink_app/ui/about_page.dart';
import 'package:lanlink_app/ui/help_page.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The six steps' titles. None of them may appear on the About page any more:
/// they are troubleshooting / how-to, which is [HelpPage]'s job.
///
/// Kept in step with `help_page_test.dart` **and** with the re-voiced copy: if the
/// two lists drift apart, the "not here" assertions below become vacuous — they
/// would check for sentences that no longer exist anywhere.
const List<String> _stepTitles = <String>[
  '让两台设备处于同一局域网',
  '首次发送需对方确认',
  '接收开关与常驻通知',
  '收到的文件位置',
  '日志位置',
  '传输速度',
];

/// The read-only fact rows of the 信息 group, in order.
///
/// **Three rows, not four.** `传输协议 lanlink v1（自有帧格式，纯 Dart）` was
/// deleted: it is a statement about our implementation (developer-facing, and
/// `docs/13` already says it), not something the user can act on. The port stays
/// — a firewall exception is an action.
const List<String> _infoLabels = <String>['数据去向', '接收位置', '局域网端口'];

/// The two receive folders, as the row states them. Pinned as one literal because
/// the *pair* is the fact: 0.2.19 publishes Android's received files into the
/// public `Download/lanlink` collection, so anything that names only the private
/// app directory is the pre-0.2.19 truth.
///
/// The Windows line names the **`received` folder**, not its parent: the label is
/// 「接收位置」, so the value has to answer "where does the file land" — and it must
/// be the same path `HelpPage` ④ gives. (It used to stop at `…\lanlink`, one level
/// short: two pages, two answers for one fact.)
const String _receiveLocation =
    'Windows：%LOCALAPPDATA%\\lanlink\\received\n'
    '手机：Download/lanlink\n'
    '可在「设置」中修改';


/// The tappable rows of the 其他 group.
const List<String> _navTitles = <String>['使用帮助', '开源许可', '隐私说明'];

void main() {
  /// Opens the About page the way a user does: phone settings → 关于我们.
  ///
  /// The surface is **tall** on purpose: the new page is ~700 logical px of
  /// content, and a `ListView` does not build children outside the viewport, so a
  /// default 800×600 window would make "the row exists" untestable rather than
  /// false.
  Future<void> openAbout(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 1200));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(true);

    await pumpShell(
      tester,
      initialModule: ShellModule.settings,
      backend: backend,
      settle: true,
    );

    await tester.tap(find.text('关于我们'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
  }

  /// Every text inside the About page (scoped, so a same-word row in the shell
  /// behind it can never satisfy the assertion).
  Finder inAbout(Finder matching) =>
      find.descendant(of: find.byType(AboutPage), matching: matching);

  testWidgets(
      // §7.5 note: the label is 「关于我们」 since docs/18 §3.5 aligned this page
      // with Flix. The property under test (a phone settings page carries a
      // visible About entry with the version, and it opens the page) is
      // unchanged — only the word did, so this is a re-point, not a weakened
      // assertion. The DESKTOP case below still asserts "no such row".
      'F: a phone settings page shows 关于我们 (with the version) and opens '
      'the About page in its 0.2.21 shape', (WidgetTester tester) async {
    await openAbout(tester);

    // 1) Identity block: name + version, and the version is the code constant.
    expect(inAbout(find.text(kAppName)), findsWidgets);
    expect(inAbout(find.text('版本 $kAppVersion')), findsOneWidget);
    expect(inAbout(find.text('局域网直传 · 不过云 · 不要账号')), findsOneWidget);

    // 2) ★ The icon is the REAL artwork now, not `Icons.swap_horiz` in a circle.
    final Finder mark = inAbout(find.byType(Image));
    expect(mark, findsOneWidget, reason: 'one icon, the app mark');
    expect(
      tester.widget<Image>(mark).image,
      isA<AssetImage>().having(
        (AssetImage image) => image.assetName,
        'assetName',
        kBrandMarkAssetHiRes,
      ),
      reason: 'the bundled 192px artwork (64dp at 3x), not a drawn placeholder',
    );
    expect(tester.getSize(mark), const Size(64, 64));
    expect(inAbout(find.byIcon(Icons.swap_horiz)), findsNothing);

    // …and it really decodes: `settleImages` precaches every mounted provider on
    // the real event loop, so a missing / unpublished file throws here instead of
    // shipping as an invisible 404 (the failure a type-only assertion cannot see).
    await settleImages(tester);
    expect(find.byType(Image), findsWidgets);
    expect(tester.getSize(inAbout(find.byType(Image))), const Size(64, 64),
        reason: 'the decoded mark occupies the 64dp slot');

    // 3) The 信息 group is present — and its rows are NOT tappable.
    //
    // docs/18 §8.2 is the rule that matters here: a value row that opens nothing
    // must not be a `ListTile` (that shape promises ink + an action). Asserting
    // "no ListTile ancestor" is what can actually fail if someone later "tidies"
    // these into tiles.
    for (final String label in _infoLabels) {
      final Finder row = inAbout(find.text(label));
      expect(row, findsOneWidget, reason: '信息 row 「$label」');
      expect(
        find.ancestor(of: row, matching: find.byType(ListTile)),
        findsNothing,
        reason: '「$label」 is read-only, so it must not look tappable',
      );
    }
    expect(inAbout(find.text('49494')), findsOneWidget,
        reason: 'the real default port (core: kDefaultPort), not 53317');
    expect(inAbout(find.text('只在你与对端设备之间，不经任何服务器')), findsOneWidget);

    // ★ 0.2.19 made the app's private directory a staging area only: verified
    // files are published into `Download/lanlink` (Android `MediaStore.Downloads`)
    // and the private copy is deleted. The row therefore has to name the folder
    // the user actually opens — on both platforms — instead of pointing at
    // 「设置」, which was true when the private directory *was* the destination.
    expect(inAbout(find.text(_receiveLocation)), findsOneWidget,
        reason: '接收位置 names Windows + phone defaults and where to change them');

    // ★ The developer-facing row is gone. Asserting the *absence* is the assertion
    // that matches the request (「关于页的协议写那么多吗」); a page that keeps it is
    // the regression, so a "tidier" rewrite that puts it back fails here.
    expect(inAbout(find.text('传输协议')), findsNothing,
        reason: 'the protocol name answers no question the user can act on');
    expect(inAbout(find.textContaining('自有帧格式')), findsNothing,
        reason: 'implementation vocabulary stays in docs/13');


    // 4) The 其他 group: three rows, each tappable, each with a ›.
    for (final String title in _navTitles) {
      final Finder row = inAbout(find.text(title));
      expect(row, findsOneWidget, reason: '其他 row 「$title」');
      expect(
        find.ancestor(of: row, matching: find.byType(ListTile)),
        findsOneWidget,
        reason: '「$title」 does something, so it is a tile',
      );
      expect(
        find.descendant(
          of: find.ancestor(of: row, matching: find.byType(ListTile)),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsOneWidget,
        reason: '「$title」 advertises its action with a ›',
      );
    }

    // 5) ★ The six 使用简介 steps are GONE from this page — and their section
    // title with them. This is the assertion that pins the move rather than the
    // re-wording.
    expect(inAbout(find.text('使用简介')), findsNothing);
    for (final String title in _stepTitles) {
      expect(inAbout(find.text(title)), findsNothing,
          reason: '「$title」 belongs to 使用帮助, not 关于');
    }

    // 6) The footer.
    expect(inAbout(find.text('© 2026 lanlink')), findsOneWidget);

    // 7) …and 使用帮助 really opens the page the steps moved to.
    await tester.tap(inAbout(find.text('使用帮助')));
    await tester.pumpAndSettle();
    expect(find.byType(HelpPage), findsOneWidget);
    expect(find.text(_stepTitles.first), findsOneWidget,
        reason: 'the steps are one tap away, on their own page');
  });

  testWidgets('F: 隐私说明 opens a dialog and says 「不经过任何服务器」 — the '
      'claim is not softened into marketing', (WidgetTester tester) async {
    await openAbout(tester);

    await tester.tap(inAbout(find.text('隐私说明')));
    await tester.pumpAndSettle();

    final Finder dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget, reason: 'a dialog, not a page');

    // ★ The specific sentence. A "privacy" blurb that drops "不经过任何服务器"
    // has quietly stopped saying the one thing that is verifiable.
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('不经过任何服务器'),
      ),
      findsOneWidget,
    );
    // The other two statements must be there too (no account / no analytics).
    expect(
      find.descendant(of: dialog, matching: find.textContaining('不需要注册')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('不发起任何外部网络请求')),
      findsOneWidget,
    );

    // …and it closes, so it can never become a dead end.
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('F: 开源许可 opens Flutter\'s own licence page (no crash, no new '
      'dependency)', (WidgetTester tester) async {
    await openAbout(tester);

    await tester.tap(inAbout(find.text('开源许可')));
    // NOT `pumpAndSettle`: the licence page streams a list in and may keep a
    // progress indicator spinning, which never settles. A few frames is exactly
    // what "it opened and did not throw" needs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(LicensePage), findsOneWidget,
        reason: 'showLicensePage pushed the real licence page');
    expect(tester.takeException(), isNull);
  });

  testWidgets('F: the About page survives a 320dp-wide phone — the long 数据去向 '
      'value wraps instead of overflowing', (WidgetTester tester) async {
    // 320 is the narrowest phone the layout host resolves to; the page is text in
    // a row (label 80 + gap 12 + value), so the failure mode here is a horizontal
    // `RenderFlex` overflow that would print a yellow-and-black stripe in release.
    // `AboutPage` has no deps, so the honest mount is a bare `MaterialApp`.
    useSurfaceSize(tester, const Size(320, 800));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        home: const AboutPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('只在你与对端设备之间，不经任何服务器'), findsOneWidget);
    // The value really wrapped (two lines tall) rather than being clipped.
    expect(
      tester.getSize(find.text('只在你与对端设备之间，不经任何服务器')).height,
      greaterThan(24),
      reason: 'the 数据去向 value wraps on a narrow phone',
    );

    // 接收位置 is the one value with embedded `\n`, i.e. the only row whose height
    // does not depend on how a path happens to wrap. At 320dp the value column is
    // ~180dp wide and the test font paints every glyph — ASCII included — as a
    // square of the font size, so `Windows：%LOCALAPPDATA%\lanlink\received` alone
    // needs four 21dp lines and the block measures **seven** (147dp, verified).
    // With real proportional glyphs that path needs two, i.e. **four** lines on a
    // device — the `\received` added to the Windows line rides on the second line
    // that already existed, so naming the real folder costs nothing on screen even
    // though it costs a line in this font. Worth stating, because otherwise the
    // test number reads as "we made the page taller".
    //
    // The bound moved 6 → 7 exactly when the Windows line gained its `\received`:
    // the bound tracks the test font, the device does not move. Either way the row
    // is a scrolling list child, so height is a layout question, not an overflow
    // one: pin the upper bound (a `SizedBox`/`Expanded` regression makes it grow
    // without limit) and that the three facts never collapse onto one line.
    final double receiveHeight =
        tester.getSize(find.text(_receiveLocation)).height;
    expect(receiveHeight, greaterThanOrEqualTo(3 * 21.0 - 1),
        reason: 'its three facts never collapse onto one line');
    expect(receiveHeight, lessThanOrEqualTo(7 * 21.0 + 1),
        reason: '接收位置 stays at seven lines in the square-glyph test font');
  });

  testWidgets(
      'F: a DESKTOP settings page HAS 关于我们 (with the version) and opens '
      'AboutPage — and still has none of the phone-only rows',
      (WidgetTester tester) async {
    // ── what this test used to be ────────────────────────────────────────────
    //
    // It was named 「a DESKTOP settings page has no 关于 row (desktop unchanged)」
    // and asserted `find.text('关于')`. The row is labelled 「关于我们」, and
    // `find.text` is an **exact** match, so the assertion could never fail for
    // the reason the name claimed — it stayed green while the desktop had no
    // About entry at all (`_desktopBody` stopped after 接收模式), which is how
    // "the desktop already has an About page" got assumed for several releases.
    // 0.2.24 gives the desktop the entry; this test now names that behaviour and
    // keeps a real check in the other direction (the phone-only rows are still
    // absent), instead of being deleted.
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    // `mobile` defaults to false → desktop.
    //
    // ★ 0.2.58 — the window is **stated** here instead of inherited from the test
    // binding's 800×600 default, and the reason is a layout fact, not a courtesy:
    // 设置 gained a 「本机信息」 card at the top (one `ListTile` + the card gap), and
    // the desktop body is a `ListView` that does not build what is below its
    // viewport — at exactly 600 tall, 「关于我们」 fell one row past the fold and
    // stopped existing as a widget. The page scrolling is not a defect (the Windows
    // runner's own minimum is 784×480, where this page already scrolled), so the
    // judgement is kept and the surface is made big enough to contain what it
    // reads: nothing below is weakened — the row is still required to be there,
    // to carry the version, and to really open `AboutPage`.
    useSurfaceSize(tester, const Size(800, 900));

    await pumpShell(
      tester,
      initialModule: ShellModule.settings,
      backend: backend,
      settle: true,
    );
    expect(find.text('本机名称'), findsOneWidget); // the desktop settings intact

    // 1) ★ The entry exists, carries the single-sourced version, and is a
    //    *tappable* row (a `ListTile` with a `›`) — not a static label.
    final Finder aboutRow = find.text('关于我们');
    expect(aboutRow, findsOneWidget,
        reason: 'the desktop must have the same 关于 entry the phone has');
    expect(find.text('版本 $kAppVersion'), findsOneWidget,
        reason: 'the version rides on that row (kAppVersion, no second copy)');
    final Finder aboutTile =
        find.ancestor(of: aboutRow, matching: find.byType(ListTile));
    expect(aboutTile, findsOneWidget, reason: 'it opens a page, so it is a tile');
    expect(
      find.descendant(of: aboutTile, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
      reason: 'the › is what advertises the action',
    );

    // 2) The phone-only rows must still be **absent** here — this is the half
    //    that keeps the two layouts from collapsing into one.
    expect(find.text('软件设置'), findsNothing,
        reason: 'the big in-body title is the phone page head');
    expect(find.text('退出软件'), findsNothing,
        reason: 'quitting the app from a settings card is a phone affordance');
    expect(find.text('文件保存位置'), findsNothing,
        reason: 'the phone states the fixed 下载/lanlink destination; the '
            'desktop edits its own directory instead');
    // …and the desktop keeps the row the phone deleted (0.2.23):
    expect(find.text('更改位置'), findsOneWidget,
        reason: 'desktop save directory stays editable');

    // 3) …and it really opens the page.
    await tester.tap(aboutRow);
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AboutPage),
        matching: find.text('版本 $kAppVersion'),
      ),
      findsOneWidget,
    );
  });
}
