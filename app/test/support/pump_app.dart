/// Widget-test helpers that mount a widget under a **fake** [AppScope]
/// (spec §6, `test/support/pump_app.dart`).
///
/// It builds an [AppDeps] entirely from a [FakeBackend] — no sockets, no disk,
/// no `dart:io` — and wraps the widget under test in `AppScope → MaterialApp`,
/// so `AppScope.of(context)` / `context.deps` resolve exactly as they will in
/// production (spec §1.2), without any real adapter.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/bootstrap/app_deps.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/picked_cache.dart';
import 'package:lanlink_app/domain/share_inbox.dart';
import 'package:lanlink_app/ui/localization.dart';
import 'package:lanlink_app/ui/scope.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/shell/shell_page.dart';

/// A neutral [AppConfig] for tests.
///
/// The paths are inert placeholders: the fakes never touch the filesystem, so
/// their values only need to be well-formed and alias-independent (spec §8.2).
const AppConfig testAppConfig = AppConfig(
  tcpPort: 53317,
  udpPort: 53317,
  multicastGroup: '224.0.0.168',
  certDirectory: r'C:\lanlink-test\certs',
  databasePath: r'C:\lanlink-test\lanlink.db',
  defaultSaveDirectory: r'C:\lanlink-test\received',
  settingsPath: r'C:\lanlink-test\settings.json',
);

/// Wires [backend] into the [AppDeps] container the tree expects.
///
/// [shareInbox] is the inbound-share port (0.2.18). Left out it stays the
/// [NoopShareInbox] default — "this platform cannot receive shares" — which is
/// what every test that does not care about sharing wants.
///
/// [pickedCache] is the "delete our own temporary copies" port (0.2.23),
/// defaulting to the production [NoopPickedCache]. A test that asserts a shared
/// file's copy is **still there** after 取消 has to pass a recording one: the
/// no-op would make "nothing was deleted" vacuously true.
AppDeps testDeps(
  FakeBackend backend, {
  AppConfig config = testAppConfig,
  ShareInboxPort? shareInbox,
  PickedCachePort? pickedCache,
}) =>
    AppDeps(
      repo: backend.repo,
      discovery: backend.discovery,
      transfer: backend.transfer,
      platform: backend.platform,
      clock: backend.clock,
      ids: backend.ids,
      config: config,
      shareInbox: shareInbox,
      pickedCache: pickedCache,
    );

/// Wraps [child] in `AppScope(deps) → MaterialApp`, ready to pump.
///
/// [AppScope] sits **above** [MaterialApp] on purpose: that keeps the
/// [Navigator] — and every route pushed onto it — **inside** the scope, so a
/// pushed page's `didChangeDependencies` reads `context.deps` exactly as in
/// production. Putting the scope at `MaterialApp.home` instead would place
/// pushed routes *beside* it, outside the subtree, and `AppScope.of` would throw
/// (the bug the home→conversation navigation test caught).
///
/// **0.2.35 — the localization wiring is part of the contract too.** The
/// production roots (`lanlink_app/lib/app.dart`, and the startup-failure surface
/// in `lib/main.dart`) declare `flutter_localizations` and pin the locale to
/// `zh_CN`; this helper declares the *same* constants
/// (`lib/ui/localization.dart`), because otherwise a mounted test tree would be
/// a different app from the shipped one for exactly the class of string this
/// release is about. Concretely: the selection toolbar's labels are
/// `MaterialLocalizations`' — with no delegates here they would render English
/// ("Copy / Select all") and every test that taps 「复制」 would be asserting a
/// menu the user never sees. Declaring them here is what makes those tests
/// meaningful rather than merely green.
Widget appWithScope({
  required Widget child,
  required AppDeps deps,
  ThemeData? theme,
}) =>
    AppScope(
      deps: deps,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: kLanlinkLocalizationsDelegates,
        supportedLocales: kLanlinkSupportedLocales,
        locale: kLanlinkLocale,
        theme: theme,
        home: child,
      ),
    );

/// Pumps [child] under a fresh (or supplied) [FakeBackend] and returns it, so a
/// test can drive the fakes and assert on the rendered tree.
///
/// Pass [settle] to wait for animations / async work (`pumpAndSettle`) instead
/// of a single extra frame (`pump`).
Future<FakeBackend> pumpApp(
  WidgetTester tester,
  Widget child, {
  FakeBackend? backend,
  AppConfig config = testAppConfig,
  ThemeData? theme,
  bool settle = false,
  ShareInboxPort? shareInbox,
  PickedCachePort? pickedCache,
}) async {
  final FakeBackend resolved = backend ?? FakeBackend();
  await tester.pumpWidget(
    appWithScope(
      child: child,
      deps: testDeps(resolved,
          config: config, shareInbox: shareInbox, pickedCache: pickedCache),
      theme: theme,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return resolved;
}

/// Pumps the three-pane [ShellPage] under a fresh (or supplied) [FakeBackend].
///
/// **This is the single mount point of the T05 rewrite** (design §8.1): every
/// widget test that used to mount one of the old `ui/pages/**` pages now mounts
/// `ShellPage` here, and picks the pane it needs through `ShellPage`'s
/// test/deep-link parameters — `initialModule` (which middle-pane module) and
/// `initialPeer` (which conversation the right pane shows).
///
/// It is a thin wrapper over [pumpApp]: the mounting contract (`AppScope →
/// MaterialApp → ShellPage`, with `AppScope` **outside** `MaterialApp`) is
/// unchanged, so the T05 rewrite keeps the one place where "how the app is
/// mounted" is expressed.
///
/// ⚠️ `ShellPage` owns its controllers for its `State`'s lifetime and **ignores
/// a later `initialModule` / `initialPeer`**. A test that mounts the shell more
/// than once (a new module / peer) must first `await tester
/// .pumpWidget(const SizedBox.shrink())` to unmount the old `State` (the pattern
/// the previous menu-navigation test documented); otherwise the second mount
/// reuses the first `ShellController`.
Future<FakeBackend> pumpShell(
  WidgetTester tester, {
  FakeBackend? backend,
  AppConfig config = testAppConfig,
  ThemeData? theme,
  bool settle = false,
  ShellModule initialModule = ShellModule.conversations,
  PeerDevice? initialPeer,
  String? initialFileId,
  String? initialFileMessageId,
  ShareInboxPort? shareInbox,
  PickedCachePort? pickedCache,
}) =>
    pumpApp(
      tester,
      ShellPage(
        initialModule: initialModule,
        initialPeer: initialPeer,
        initialFileId: initialFileId,
        initialFileMessageId: initialFileMessageId,
      ),
      backend: backend,
      config: config,
      theme: theme,
      settle: settle,
      shareInbox: shareInbox,
      pickedCache: pickedCache,
    );

/// Sizes the test window to [size] **logical** pixels at device-pixel-ratio 1,
/// and restores it when the test ends.
///
/// The three-pane shell resolves its layout from the window width (design §6.1),
/// so the responsive / narrow-window tests must drive `tester.view` instead of
/// the 800×600 default. `DPR = 1` keeps `cacheWidth` caps (which multiply by the
/// device-pixel-ratio) equal to the logical edge, so a thumbnail's rendered
/// logical size is directly comparable to its `edge`.
void useSurfaceSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// Lets every currently-mounted [Image] finish decoding, then rebuilds.
///
/// `Image.memory` decodes its bytes **off the fake-async clock** that
/// `testWidgets` runs on, so a plain `pumpAndSettle()` can leave the render box
/// at its pre-decode size and make a size / aspect-ratio assertion meaningless
/// (the classic `tester.runAsync` caveat). This resolves each provider on the
/// **real** event loop — [`precacheImage`] under [WidgetTester.runAsync] — and
/// then pumps, so a caller can measure the image at its true, decoded size.
///
/// A no-op when nothing is mounted; harmless when the image had already decoded
/// (the provider cache makes the await immediate). Only tests that assert a
/// *decoded* image's geometry need it.
Future<void> settleImages(WidgetTester tester) async {
  final List<Element> images = find.byType(Image).evaluate().toList();
  if (images.isEmpty) {
    return;
  }
  final BuildContext context = images.first;
  final List<ImageProvider<Object>> providers = <ImageProvider<Object>>[
    for (final Element element in images) (element.widget as Image).image,
  ];
  await tester.runAsync(() async {
    for (final ImageProvider<Object> provider in providers) {
      await precacheImage(provider, context);
    }
  });
  await tester.pumpAndSettle();
}
