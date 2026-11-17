/// The narrow-window (<760) shell: the Flix-style phone form (M5 spec §3.1).
///
/// It replaces the old "collapsed `NavRail` + one pane" narrow layout with:
///
/// * an `AppBar` carrying the current title — on the 会话 list that title **is**
///   the brand (mark + `kAppName`), on a 会话 detail it is the peer's name and
///   nothing else — and, on the 会话 module, a ⋮ with the rescan and the search
///   reveal (M5c §2/§3);
/// * a **bottom `NavigationBar` of exactly three destinations** — 设备 / 文件 /
///   设置 (PRD §3.1) — and **nothing above it**: the receive-mode row that used
///   to sit there was removed (docs/18, "照 Flix": Flix's bottom bar is a single
///   bar). The switch it carried still exists in 设置 (`AcceptToggle`), which is
///   where Flix keeps it too — so 接收模式 can never become impossible to turn
///   off;
/// * **0.2.42** — a **read-only** 「接收已关闭」 marker above the 设备 list, drawn
///   only while the receiver is off ([_receiveOffBanner]). It replaces nothing:
///   it is the phone's *first* sight of a state that used to be visible only in
///   the desktop rails, and it is deliberately not a switch (one write entry).
///   While receiving is on it costs zero pixels — not a hidden row, an absent one;
/// * the 文件 page's secondary `[最近文件 | 已归档]` segment (the Q8 ruling);
/// * a `PopScope` so the system back button **steps back one layer** (detail →
///   list) instead of leaving the app, and only on the phone (PRD §5).
///
/// The wide and compact layouts never mount this widget, so their `Row(NavRail
/// + panes)` path — and the **absence of any `PopScope`** there — is untouched
/// (hard constraints #1 / #5).
///
/// It reuses the **same** `ListPane` / `DetailPane` instances the host builds, so
/// the two-level list ⇄ detail choice stays exactly the shell's
/// (`ShellController.detailVisible`): there is no second source of truth, and
/// the module/selection semantics are byte-for-byte the wide shell's.
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**`, `controllers/**` and sibling `ui/**` — never `dart:io` /
/// `dart:ffi` / `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../controllers/home_controller.dart';
import '../../controllers/recent_files_controller.dart';
import '../../controllers/settings_controller.dart';
import '../../domain/manual_targets.dart';
import '../../domain/models.dart';
import '../format.dart';
import '../notices.dart';
import '../panes/device_profile.dart';
import '../scope.dart';
import '../widgets/manual_peer_dialog.dart';
import '../widgets/notice_banner.dart';
import 'phone_tabs.dart';
import 'shell_controller.dart';
import 'shell_module.dart';

/// The phone shell: top bar + one pane + a three-tab bottom navigation.
class PhoneShell extends StatelessWidget {
  /// Creates the narrow shell.
  ///
  /// [listPane] / [detailPane] are the host-built panes (with `showHeader:
  /// false` and `showBack: true` respectively) — reused, never rebuilt here.
  const PhoneShell({
    super.key,
    required this.shell,
    required this.home,
    required this.recentFiles,
    required this.settings,
    required this.listPane,
    required this.detailPane,
  });

  /// The shared shell state (module + selection + narrow detail flag).
  final ShellController shell;

  /// The app-level home state (identity, discovery, rescan).
  final HomeController home;

  /// The app-level recent-files state. The 文件 tab's rows come from the reused
  /// [listPane]; the state is carried so the shell's contract matches the
  /// wide shell's, where the same controller feeds the middle pane.
  final RecentFilesController recentFiles;

  /// The app-level settings state (the receive toggle's single writer).
  final SettingsController settings;

  /// The middle pane, built by the host with `showHeader: false` — the module
  /// title lives in the top bar on a phone, so it must not be drawn twice.
  final Widget listPane;

  /// The right pane, built by the host with `showBack: true` — every narrow
  /// detail (conversation *and* file) gets the ← affordance.
  final Widget detailPane;

  /// Whether [module] has a two-level detail on a phone.
  static bool _hasDetail(ShellModule module) =>
      module == ShellModule.conversations || module == ShellModule.recentFiles;

  /// Whether [module] is one of the 文件 tab's two secondary segments.
  static bool _isFilesTab(ShellModule module) =>
      module == ShellModule.recentFiles || module == ShellModule.archived;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // ★ 0.2.42: `settings` joined this merge. The home's 「接收已关闭」 marker
      // ([_receiveOffBanner]) reads `settings.accepting`, which forwards to the
      // receiver; without listening here, turning 接收 back on would leave the
      // marker standing on the home list until some *other* change happened to
      // rebuild the shell (a tab switch, an arriving message) — a stale warning,
      // which is the same class of bug as no warning.
      listenable: Listenable.merge(<Listenable>[shell, home, settings]),
      builder: (BuildContext context, Widget? child) {
        final bool showDetail = shell.detailVisible && _hasDetail(shell.module);
        return PopScope(
          // List page → let the system pop (exit the app); detail page → swallow
          // the pop and step back exactly one layer (PRD §5 / A2-1..A2-3).
          // `selectModule` never clears the flag, so every bottom-nav / segment
          // switch calls `closeDetail()` first (see [_onTabSelected]).
          canPop: !shell.detailVisible,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (!didPop) {
              shell.closeDetail();
            }
          },
          child: Scaffold(
            appBar: _appBar(context),
            body: showDetail ? detailPane : _listBody(),
            bottomNavigationBar: _bottomBar(),
          ),
        );
      },
    );
  }

  /// The top bar: the current title, the conversation rescan and the receive
  /// toggle (PRD §3.1.1 / §3.3).
  PreferredSizeWidget _appBar(BuildContext context) {
    return AppBar(
      // The ← affordance is this bar's `leading`, shown only while a detail is
      // open (`detailVisible && _hasDetail`) — the same condition the body uses,
      // so the conversation and the file preview both get it.
      //
      // `automaticallyImplyLeading` stays false: a phone shell is the app's root,
      // so there is nothing for the framework to pop — and with it true, a null
      // `leading` would make the bar inject its own back button.
      automaticallyImplyLeading: false,
      leading: (shell.detailVisible && _hasDetail(shell.module))
          ? IconButton(
              tooltip: '返回列表',
              icon: const Icon(Icons.arrow_back),
              onPressed: shell.closeDetail,
            )
          : null,
      title: _barTitle(context),
      actions: <Widget>[
        // The conversations LIST's actions live in an overflow ⋮ (M5c §2/§3):
        // the search reveal and the rescan. Hidden on the detail page, where the
        // conversation header has its own ⋮ (fingerprint / archive) — one ⋮ per
        // page. The receive switch is NOT here any more — it moved to the
        // always-visible bottom bar.
        if (shell.module == ShellModule.conversations && !shell.detailVisible)
          PopupMenuButton<_PhoneMenu>(
            tooltip: '更多',
            onSelected: (_PhoneMenu item) => _onMenu(context, item),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<_PhoneMenu>>[
              const PopupMenuItem<_PhoneMenu>(
                value: _PhoneMenu.search,
                // 「筛选设备」, not 「搜索设备」 (0.2.56): this only reveals a field
                // that filters the rows already in the list. It never looks for a
                // device — that is what 重新扫描 does, one row below. Two adjacent
                // items both saying "search" made the wrong one the obvious guess.
                child: Text('筛选设备'),
              ),
              const PopupMenuItem<_PhoneMenu>(
                value: _PhoneMenu.rescan,
                child: Text('重新扫描'),
              ),
              // 0.2.56 — the third door to 手动填写 IP 连接. Without it the feature
              // is reachable only from the *empty* list, which stops existing the
              // first time a conversation is created: "再添一台设备，自动发现没扫到"
              // then has no entry at all.
              //
              // 0.2.57 — and it goes **disabled** at the cap, the same way the
              // 添加设备地址 row does: both would otherwise open a dialog whose
              // only ending is 「最多保存 8 个」.
              PopupMenuItem<_PhoneMenu>(
                value: _PhoneMenu.manualPeer,
                enabled:
                    (settings.settings.valueOrNull?.manualPeers.length ?? 0) <
                        kMaxManualPeers,
                child: const Text(kManualPeerActionLabel),
              ),
            ],
          ),
        // While a conversation is open the bar carries **that conversation's** ⋮
        // — 查看指纹 / 归档会话 — moved up from the header row that used to sit
        // below this bar (docs/18 §2.4). The list page's ⋮ above is hidden while
        // a detail is open, so there is still exactly one ⋮ per page.
        // §3.1: the way into a peer's profile sits beside its name in the
        // conversation bar. A phone-only affordance — the wide/compact panes are
        // untouched (`PhoneShell` is mounted only for `ShellLayout.narrow`).
        //
        // 0.2.59: the entry is called 「媒体与文件」, not 「设备设置」. The page it
        // opens is the 图片 / 视频 / 文件 wall; "设备设置" promised settings that
        // this page deliberately does not have (docs/18 §3.1 has no per-device
        // switches at all). The page's own `AppBar` keeps the **device name** —
        // that is what it has always shown, and it is the right title.
        if (shell.module == ShellModule.conversations && shell.detailVisible)
          IconButton(
            tooltip: '媒体与文件',
            icon: const Icon(Icons.tune),
            onPressed: () => unawaited(_openDeviceProfile(context)),
          ),
        if (shell.module == ShellModule.conversations && shell.detailVisible)
          PopupMenuButton<_ConversationAction>(
            tooltip: '更多',
            onSelected: (_ConversationAction item) =>
                _onConversationAction(context, item),
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<_ConversationAction>>[
              PopupMenuItem<_ConversationAction>(
                value: _ConversationAction.viewFingerprint,
                child: Text('查看指纹'),
              ),
              PopupMenuItem<_ConversationAction>(
                value: _ConversationAction.archive,
                child: Text('归档会话'),
              ),
              // 0.2.41 — 多选: the phone's way in (its bubbles have no
              // right-click, and bumping a long press would fight text selection).
              PopupMenuItem<_ConversationAction>(
                value: _ConversationAction.multiSelect,
                child: Text('多选'),
              ),
            ],
          ),
      ],
    );
  }

  /// Opens the 媒体与文件 page for the peer of the open conversation (§3.1).
  ///
  /// The peer comes from the merged card when it is online (so the page shows
  /// the live name), else from a minimal stand-in built off the selected
  /// fingerprint — the same two-step `detail_pane` uses for its header.
  ///
  /// **0.2.59: the page can now answer.** Its card menu's 「转到消息」 closes it
  /// with the owning message's id as the route's result, and this method is what
  /// hands that id to the conversation: `requestReveal` is the only way to say
  /// "scroll to this message", and the controller is the only object that
  /// survives a 消息 / 文件 tab switch (a request parked in the timeline's State
  /// would be lost if the user was on 文件 at the time). Nothing else happens
  /// here — no `context` is touched after the `await`, which is why the route is
  /// typed `<String>` rather than `void`: a `void` route would silently drop it.
  Future<void> _openDeviceProfile(BuildContext context) async {
    final String? conversationId = shell.selectedConversationId;
    final String? fingerprint = shell.selectedFingerprint;
    if (conversationId == null || fingerprint == null) {
      return;
    }
    PeerDevice? peer;
    for (final PeerDevice card
        in home.cards.valueOrNull ?? const <PeerDevice>[]) {
      if (card.fingerprint == fingerprint) {
        peer = card;
        break;
      }
    }
    peer ??= PeerDevice(
      fingerprint: fingerprint,
      alias: '',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 0,
    );
    final String? target = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) => DeviceProfilePage(
          peer: peer!,
          conversationId: conversationId,
        ),
      ),
    );
    // `null` ⇒ the user came back with ← / Esc / the system back button: no
    // request, and the thread's state is exactly as they left it.
    if (target != null) {
      shell.conversationController?.requestReveal(target);
    }
  }

  /// Runs a conversation-page overflow action.
  ///
  /// The same two actions the removed header offered. They are written out
  /// **twice on purpose** — here and in `detail_pane.dart` (which now serves
  /// only the wide / compact header): the alternative is editing the desktop
  /// path, and "电脑版一个像素都不能变" forbids that. If a third caller ever
  /// appears, extract a shared widget instead of copying a third time.
  ///
  /// **They are no longer identical in one respect (0.2.10):** archiving here
  /// also closes the detail, because on a phone "detail visible with nothing
  /// selected" is a dead end (see the note in the archive branch). The desktop
  /// copy keeps the old behaviour on purpose — there `detailVisible` is ignored
  /// and the right pane is supposed to fall back to its placeholder.
  void _onConversationAction(BuildContext context, _ConversationAction item) {
    if (item == _ConversationAction.multiSelect) {
      // The state is per conversation; the shell only holds the handle (see
      // `ShellController.conversationController`).
      shell.conversationController?.startSelecting();
      return;
    }
    if (item == _ConversationAction.viewFingerprint) {
      final String fingerprint = shell.selectedFingerprint ?? '';
      showTransientNotice(
        context,
        fingerprint.isEmpty ? '（未知指纹）' : fingerprint,
        bottomInset: kComposerNoticeInset,
      );
      return;
    }
    // item == _ConversationAction.archive (Q8: hidden from the home list).
    final String? id = shell.selectedConversationId;
    if (id != null) {
      context.deps.repo.archiveConversation(id);
      // Back to the LIST, not to the detail's placeholder (0.2.10).
      //
      // `clearSelection()` nulls the fingerprint and the conversation id but
      // leaves `detailVisible` alone (see `ShellController.clearSelection`), so
      // the phone stayed on the detail branch with nothing selected: the body
      // showed `DetailPane`'s **desktop** placeholder ("左侧选一台设备开始" —
      // "left" is wrong on a phone) and the bar fell back to the module label
      // 「设备」. Closing the detail first is what makes "archive" mean "this
      // conversation is gone from this list": the user lands on the list and the
      // bar goes back to the brand.
      shell.clearSelection();
      shell.closeDetail();
    }
  }

  /// The top-bar ⋮ actions (M5c §2/§3).
  void _onMenu(BuildContext context, _PhoneMenu item) {
    switch (item) {
      case _PhoneMenu.search:
        shell.toggleConversationSearch();
      case _PhoneMenu.rescan:
        home.rescan();
      case _PhoneMenu.manualPeer:
        // The same path the empty list and the desktop ⋮ use — including the
        // settings reload that keeps 设置's count honest.
        //
        // The dialog also gets this device's own address (0.2.58): that is what
        // the user reads out to the other machine.
        unawaited(
          openManualPeerDialog(
            context,
            add: home.addManualPeer,
            reload: settings.load,
            localAddress: home.discoveryStatus.selfAddress,
            localPort: home.discoveryStatus.selfPort,
          ),
        );
    }
  }

  /// The top-bar title **widget** — three cases, deliberately not one `Row`.
  ///
  /// * **会话列表** → the brand: the mark + [kAppName]. It replaces the brand row
  ///   that used to sit *under* this bar (docs/18 §3.4): the reference puts the
  ///   name where our title goes, and having it twice (a bar title saying 设备
  ///   above a brand row saying lanlink) read as a bug.
  /// * **会话详情** → the peer's name as **plain text, no mark**. A brand mark
  ///   above a person's name reads as "this person sits under my brand"; the
  ///   product and the peer are different kinds of thing. There is a test for
  ///   this (`test/widget/home_brand_test.dart`), so the distinction does not
  ///   quietly collapse into "one Row for every branch".
  /// * **设置 / 文件** → exactly what they were: 设置 keeps the empty `Text('')`
  ///   (the page carries its own large 「软件设置」 title), 文件 keeps the tab
  ///   label.
  ///
  /// The brand mark comes from `assets/brand/mark.png` — the user's own artwork
  /// (source: the project's own vector artwork), rasterised without the
  /// plate/shadow so it can sit on the bar. It is **not** a drawn placeholder:
  /// the earlier brand row faked the logo with a coloured square because no
  /// asset existed; that stand-in is gone with the row.
  Widget _barTitle(BuildContext context) {
    if (shell.module == ShellModule.conversations) {
      return shell.detailVisible
          ? Text(_title(), maxLines: 1, overflow: TextOverflow.ellipsis)
          : _brandTitle(context);
    }
    return Text(_title(), maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  /// The conversation list's bar title: mark + product name, `mainAxisSize.min`
  /// so the `AppBar` centres nothing and the title keeps its leading edge.
  Widget _brandTitle(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 24dp, the same edge length the removed brand row used, so the bar's
        // height and the mark's optical weight do not change with the move.
        Image.asset(
          kBrandMarkAsset,
          width: 24,
          height: 24,
          // The mark is decorative here: the wordmark right beside it already
          // says "lanlink", and the bar's title node is a *header*, not a
          // picture. Without this, `Image` wraps itself in
          // `Semantics(image: true, label: '')` (SDK image.dart:1425), which
          // **merges into the AppBar title node** and gives it the `isImage`
          // flag — a screen reader then announces "lanlink, image, header".
          // `semanticLabel` would be worse: a second node, read twice.
          excludeFromSemantics: true,
          // The source is 96px for a 24dp slot (4x on the densest screens):
          // `medium` keeps the thin gradient edges from shimmering when it is
          // downscaled, where the default `low` resampling softens them.
          filterQuality: FilterQuality.medium,
        ),
        const SizedBox(width: 8),
        // `Flexible` so a very long product name ellipsises instead of
        // overflowing the bar — the row is `min` sized, so this is a guard, not
        // a layout decision (`kAppName` is short today).
        Flexible(
          child: Text(
            // The product name comes from the single constant (guarded against
            // pubspec by its own test) — never a second hand-written string.
            kAppName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  /// The top-bar title **text**: the peer alias while a conversation detail is
  /// open (fingerprint fallback), else the current tab label (PRD §3.1.1 / W3).
  ///
  /// The conversation **list** never reaches the empty branch below — its bar
  /// carries the brand widget instead ([_barTitle]). The branch is kept for
  /// 设置, whose body already announces itself with 「软件设置」.
  String _title() {
    if (shell.module == ShellModule.conversations && shell.detailVisible) {
      final String? fingerprint = shell.selectedFingerprint;
      if (fingerprint != null && fingerprint.isNotEmpty) {
        final String? alias = _aliasFor(fingerprint);
        return (alias != null && alias.isNotEmpty)
            ? alias
            : shortFingerprint(fingerprint);
      }
    }
    // Pages that carry their **own** large title/wordmark keep the bar textless:
    // stacking the same name twice reads as a bug ("最上面有一个设置，下面又是软件
    // 设置" — the user hit exactly that).
    //
    // Today that is exactly one page: the settings body (「软件设置」, §3.5). The
    // conversation list used to be the other one — it now draws the brand in the
    // bar instead of nothing, so it is resolved by [_barTitle] before reaching
    // here. The About page's wordmark is a different word from its bar title, so
    // it is not this defect.
    if (shell.module == ShellModule.settings) {
      return '';
    }
    return phoneTabOf(shell.module).label;
  }

  /// The alias of the device [fingerprint] from the merged cards, or `null`.
  ///
  /// Read from [HomeController.cards] — the same merged source the list rows and
  /// the detail header use, so the title can never name a device differently.
  String? _aliasFor(String fingerprint) {
    final List<PeerDevice> cards =
        home.cards.valueOrNull ?? const <PeerDevice>[];
    for (final PeerDevice device in cards) {
      if (device.fingerprint == fingerprint && device.alias.isNotEmpty) {
        return device.alias;
      }
    }
    return null;
  }

  /// The body for the list (no detail) case: the plain list, or — on the 文件
  /// tab — the `[最近文件 | 已归档]` segment over it (Q8), with the read-only
  /// 「接收已关闭」 marker above the 设备 tab's list when it applies.
  ///
  /// The marker is inserted **only when it exists**. With receiving on this
  /// method returns the very same widget it returned before 0.2.42 — no
  /// `Column`, no zero-height `SizedBox`, no reserved space — so an enabled
  /// receiver pays nothing at all, which is what the geometry test asserts
  /// (`ListPane`'s top edge sits exactly at the app bar's bottom edge).
  Widget _listBody() {
    final Widget body = _isFilesTab(shell.module)
        ? Column(
            children: <Widget>[
              _filesSegment(),
              const Divider(height: 1, thickness: 1),
              Expanded(child: listPane),
            ],
          )
        : listPane;
    final Widget? banner = _receiveOffBanner();
    if (banner == null) {
      return body;
    }
    return Column(
      children: <Widget>[banner, Expanded(child: body)],
    );
  }

  /// 「接收已关闭」 — a **read-only** marker above the home list, or `null` when
  /// there is nothing to say (0.2.42).
  ///
  /// **The defect this closes.** The receiver state was visible in exactly one
  /// place: the desktop rail's toggle (`nav_rail.dart::_receiveMode`). `PhoneShell`
  /// never mounts that rail, so on a phone a user whose 接收 was off had **no way
  /// to see it** — files simply never arrived, and the natural conclusions are
  /// "the network is bad" and "the other side's app is broken", neither of which
  /// the user can act on. This banner says the one thing that is actually true.
  ///
  /// **It is not a switch, and it must not become one.** The single write entry
  /// stays `SettingsController.setAccepting` (desktop rail + 设置's `AcceptToggle`).
  /// A control here would give one boolean two places it can be flipped from — and
  /// then a third thing to keep in sync with the persisted default.
  ///
  /// **Same source as the desktop.** `SettingsController.accepting` forwards to
  /// the running receiver (`TransferService.accepting`), which is the one place
  /// the state lives; the rail reads that exact getter, so the two surfaces cannot
  /// disagree. Nothing is re-derived here.
  ///
  /// Only on the 设备 (home) tab: that is where a user lands and where the
  /// absence of incoming files is felt. 设置 already shows the switch itself, and
  /// the 文件 tab's `[最近文件 | 已归档]` strip is left byte-for-byte as it was.
  Widget? _receiveOffBanner() {
    if (settings.accepting || shell.module != ShellModule.conversations) {
      return null;
    }
    // `NoticeBanner` with no `onDismiss`: a strip of information with no button,
    // which is precisely "read-only" — and the same shape the rest of the app
    // uses for a sentence about state (error/notice banners).
    return const NoticeBanner(
      message: kReceiveOffNote,
      icon: Icons.wifi_tethering_off,
    );
  }

  /// The 文件 tab's secondary segment: 最近文件 ⇄ 已归档 (Q8). Both highlight
  /// the same bottom-nav「文件」slot, so 已归档 never becomes a fourth tab.
  Widget _filesSegment() {
    final bool recent = shell.module == ShellModule.recentFiles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          children: <Widget>[
            ChoiceChip(
              label: const Text('最近文件'),
              selected: recent,
              onSelected: (bool selected) =>
                  _selectFilesSegment(ShellModule.recentFiles),
            ),
            ChoiceChip(
              label: const Text('已归档'),
              selected: !recent,
              onSelected: (bool selected) =>
                  _selectFilesSegment(ShellModule.archived),
            ),
          ],
        ),
      ),
    );
  }

  /// Switches the 文件 tab's segment. Resets the detail flag first, so leaving a
  /// file detail for the other segment returns to the list (not a stale detail).
  void _selectFilesSegment(ShellModule target) {
    shell.closeDetail();
    shell.selectModule(target);
  }

  /// The three-tab bottom bar — one bar, no row above it (docs/18, "照 Flix").
  ///
  /// The receive-mode row that used to sit here was removed; the switch lives in
  /// 设置 (`AcceptToggle`), the same place Flix keeps it.
  Widget _bottomBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NavigationBar(
          // Icon-only (docs/18 §2.3): `alwaysHide` drops the *painted* text but
          // keeps each `label` in the semantics tree, so screen readers still
          // name the destinations — accessibility is not traded away for the
          // look. Narrow-screen only: this widget is mounted solely for
          // `ShellLayout.narrow` (shell_page.dart), so wide/compact are untouched.
          labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
          selectedIndex: phoneTabOf(shell.module).index,
          onDestinationSelected: _onTabSelected,
          destinations: <Widget>[
            for (final PhoneTab tab in PhoneTab.values)
              NavigationDestination(icon: Icon(tab.icon), label: tab.label),
          ],
        ),
      ],
    );
  }

  /// A bottom-nav tap. **Resets the detail flag first**: `selectModule` never
  /// clears `_detailVisible`, so without the reset, tapping 设备 while a
  /// conversation detail is open would leave the user on the old detail instead
  /// of that module's list (M5 §3.2.3). The selection itself is kept (E16).
  void _onTabSelected(int index) {
    final PhoneTab tab = PhoneTab.values[index];
    shell.closeDetail();
    shell.selectModule(tab.module);
  }
}

/// The phone home's 「接收已关闭」 sentence (0.2.42).
///
/// It has to answer **"why do I get nothing?"** in one glance, so it states the
/// consequence in the user's own terms — 别人现在发不进来 — rather than repeating
/// the rail's bare `接收已关闭` label (which the phone never shows, and which on its
/// own reads like a setting, not like a reason). It also says where the switch
/// is, because a read-only marker that names no way out is a dead end.
///
/// Declared here rather than beside `kReceiveModeNote` in `ui/format.dart` on
/// purpose: the rail's label and its long caption are separate copies already, and
/// the desktop is frozen pixel-for-pixel (hard constraint #1) — a shared constant
/// would invite one surface's rewording to drag the other's around.
const String kReceiveOffNote =
    '接收已关闭：别人现在发不进来，对方发文件会被直接拒绝。可在「设置」里开启。';

/// The phone top-bar overflow menu (M5c §2/§3).
enum _PhoneMenu { search, rescan, manualPeer }

/// The conversation page's top-bar overflow menu (docs/18 §2.4) — the actions
/// the removed conversation header used to own.
enum _ConversationAction { viewFingerprint, archive, multiSelect }
