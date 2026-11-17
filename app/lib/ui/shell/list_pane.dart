/// The middle pane of the three-pane shell (design §1.3 / §2.4 / §6).
///
/// It is a **dispatcher**: it reads `ShellController.module` and renders that
/// module's body, wrapped in the shared `kSurfaceList` surface and one module
/// header. The four bodies are:
///
/// * `conversations` — the merged device list (with a rescan action and a local
///   device-name filter); it lives here, as a private widget, because the design
///   has no separate `conversations_list.dart`.
/// * `recentFiles` → `RecentFilesList`
/// * `archived` → `ArchivedList`
/// * `settings` → `SettingsBody`
///
/// The rows read the selection straight from [ShellController]
/// (`selectedFingerprint`), so the highlight and the right pane can never
/// disagree (PRD E16). The list order is the controller's
/// (`HomeController.cards`); this pane **never re-sorts** it.
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**`, `controllers/**` and sibling `ui/**` — never `dart:io` /
/// `dart:ffi` / `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/recent_files_controller.dart';
import '../../controllers/settings_controller.dart';
import '../../domain/manual_targets.dart';
import '../../domain/models.dart';
import '../../domain/peer_discovery.dart';
import '../widgets/local_info_sheet.dart';
import '../format.dart';
import '../panes/archived_list.dart';
import '../panes/recent_files_list.dart';
import '../panes/settings_body.dart';
import '../theme.dart';
import '../widgets/device_row.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_banner.dart';
import '../widgets/fade_in.dart';
import '../widgets/loading_state.dart';
import '../widgets/manual_peer_dialog.dart';
import '../widgets/notice_banner.dart';
import '../widgets/troubleshoot_hints.dart';
import 'shell_controller.dart';
import 'shell_module.dart';

/// The middle pane: a module header over the active module's body.
class ListPane extends StatelessWidget {
  /// Creates the middle pane.
  ///
  /// [controller] is the shared shell state; [home] / [recentFiles] /
  /// [settings] are the app-level controllers created once by the host and
  /// handed down (design §2.5).
  ///
  /// [showHeader] draws the module header (title + actions). The phone shell
  /// passes `false` — the title moves to the top bar, so it must not be drawn
  /// twice (M5 §3.3 / S5). The default keeps the wide / compact rendering
  /// **byte-for-byte** unchanged (constraint #1).
  const ListPane({
    super.key,
    required this.controller,
    required this.home,
    required this.recentFiles,
    required this.settings,
    this.showHeader = true,
  });

  /// The shared shell state (module + selection).
  final ShellController controller;

  /// The app-level home state (device cards, error, rescan).
  final HomeController home;

  /// The app-level recent-files state.
  final RecentFilesController recentFiles;

  /// The app-level settings state.
  final SettingsController settings;

  /// Whether to draw the module header (title + actions). `false` on a phone,
  /// where the top bar owns the title (M5 §3.3 / S5).
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: paneSurface(Theme.of(context)),
      child: Material(
        // A transparent Material so the middle pane's rows host their own ink /
        // hover highlight *above* this pane's opaque surface colour (PRD §2.5);
        // otherwise the Scaffold's Material paints the ink underneath it.
        type: MaterialType.transparency,
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            controller,
            home,
            recentFiles,
            settings,
          ]),
          builder: (BuildContext context, Widget? child) => Column(
            children: <Widget>[
              _transferNotice(context),
              // The header (and its divider) is omitted on a phone, where the
              // title lives in the top bar (M5 §3.3 / S5); the default path is
              // unchanged.
              if (showHeader) ...<Widget>[
                _header(context),
                // Air instead of a rule (Feishu alignment, comparison-table
                // row 3 — Feishu almost never uses lines).
                const SizedBox(height: kSectionGap),
              ],
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  /// The app-level "someone tried to send and we refused" notice (P0-7
  /// follow-up).
  ///
  /// Shown at the top of the middle pane, across **every** module, and
  /// dismissible — a **neutral** sibling of the discovery [ErrorBanner] (red is
  /// reserved for real failures). A refusal is not a message: it belongs to no
  /// conversation (any device may send, and there may be no conversation at
  /// all), so it must never enter the message list.
  Widget _transferNotice(BuildContext context) {
    final UploadRejected? event = home.transferNotice;
    if (event == null) {
      return const SizedBox.shrink();
    }
    return NoticeBanner(
      message: transferRejectedText(event),
      onDismiss: home.clearTransferNotice,
    );
  }

  /// The uniform module header (design §1.3: "模块标题 + 动作"). The
  /// conversations module offers a ⋮ with **two** actions (0.2.56).
  ///
  /// It used to be a bare 🔄 `IconButton` for the rescan, and 0.2.55 added a
  /// second icon beside it for 手动填写 IP 连接. Two 30px icons in a 48px header
  /// read as a toolbar, so both now live in the menu the phone has always used
  /// (`phone_shell.dart`): one shape on both platforms, and room for a third
  /// action without re-drawing the header.
  ///
  /// **Accepted cost:** the rescan is two taps on the desktop instead of one.
  /// That was a deliberate call, not an oversight.
  Widget _header(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Widget> actions = controller.module == ShellModule.conversations
        ? <Widget>[
            PopupMenuButton<_ConversationsMenu>(
              tooltip: '更多',
              onSelected: (_ConversationsMenu item) =>
                  _onConversationsMenu(context, item),
              itemBuilder: (BuildContext context) {
                // At the cap the address entry goes **disabled**, exactly like the
                // 添加设备地址 row in 设置 (0.2.57). Opening a dialog whose only
                // possible ending is 「最多保存 8 个」 is the "tappable but inert"
                // shape we ruled out — and it would be inconsistent with the row
                // that shows the same limit, two taps away.
                final bool full =
                    (settings.settings.valueOrNull?.manualPeers.length ?? 0) >=
                        kMaxManualPeers;
                return <PopupMenuEntry<_ConversationsMenu>>[
                  const PopupMenuItem<_ConversationsMenu>(
                    value: _ConversationsMenu.rescan,
                    child: Text('重新扫描'),
                  ),
                  PopupMenuItem<_ConversationsMenu>(
                    value: _ConversationsMenu.manualPeer,
                    enabled: !full,
                    child: const Text(kManualPeerActionLabel),
                  ),
                ];
              },
            ),
          ]
        : const <Widget>[];
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                controller.module.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // 20 — **CHOSEN, not a single-point measurement.**
                //
                // Feishu's mid-column header is genuinely larger than our 16, but
                // the reading only supports a RANGE: across five ink thresholds
                // the header's ink is stably 23 image px while its row name's
                // drifts 12-16 image px, so the scale-free ratio is 1.44-1.92 and
                // the target band is 20-27 (mid ~24). 20 and 22 both sit inside
                // it, and our M3 ladder has no rung between 16 and 22.
                //
                // (An earlier version of this comment claimed "no DPR reading
                // reconciles 23 with 16" — that compared image px against logical
                // px and was wrong. Do not restore it.)
                style: theme.textTheme.titleMedium?.copyWith(fontSize: 20),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }

  /// Runs one conversation-header action.
  ///
  /// Both land on capabilities that already exist — the menu adds no new
  /// behaviour, which is why there is nothing here about probes or retries.
  void _onConversationsMenu(BuildContext context, _ConversationsMenu item) {
    switch (item) {
      case _ConversationsMenu.rescan:
        home.rescan();
      case _ConversationsMenu.manualPeer:
        // Not awaited: the menu is already closed and the dialog owns its own
        // lifetime. The reload keeps 设置's count and rows honest — it is inside
        // `openManualPeerDialog` so all three doors behave the same.
        //
        // `localAddress` / `localPort` (0.2.58): the dialog now opens with this
        // device's own address, so the user does not have to go and look it up on
        // the *other* machine's screen. Read straight off the discovery status —
        // no new state, and the dialog decides for itself what "not known" means.
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

  Widget _body() => FadeIn(
        // Keyed by the module so a module switch re-runs the one-shot fade; an
        // unchanged module keeps this subtree's state and does not re-animate
        // (PRD §2.5: switching modules / recent files should not feel "僵硬").
        key: ValueKey<ShellModule>(controller.module),
        child: switch (controller.module) {
          ShellModule.conversations => _ConversationsBody(
              home: home,
              settings: settings,
              controller: controller,
              // The phone hides the search field behind its ⋮ menu (M5c §3);
              // the desktop (`showHeader`) keeps it always visible.
              collapsibleSearch: !showHeader,
              // `!showHeader` is this pane's existing "I am the phone shell"
              // signal (only `PhoneShell` passes `showHeader: false`), and the
              // card look is narrow-only by definition (docs/18 §2.0/§2.1), so
              // it is reused rather than threading a second, parallel flag from
              // the shell down here.
              carded: !showHeader,
            ),
          ShellModule.recentFiles =>
            RecentFilesList(files: recentFiles, selection: controller),
          ShellModule.archived => const ArchivedList(),
          ShellModule.settings =>
            SettingsBody(controller: settings, home: home),
        },
      );
}

/// The middle-pane body of the conversations module: status filter + list.
class _ConversationsBody extends StatelessWidget {
  const _ConversationsBody({
    required this.home,
    required this.settings,
    required this.controller,
    this.collapsibleSearch = false,
    this.carded = false,
  });

  final HomeController home;

  /// The settings state, touched by exactly one thing here: after a hand-typed
  /// address is accepted (0.2.54) the persisted document has one more entry, and
  /// this is what re-reads it into the settings page's mirror.
  final SettingsController settings;

  final ShellController controller;

  /// Phone only: hide the search field until the shell's ⋮ reveals it (M5c §3).
  /// `false` (the desktop) keeps the field always visible.
  final bool collapsibleSearch;

  /// Phone only: draw each conversation as a card with air between cards
  /// (docs/18 §2.1). `false` (wide / compact) keeps the current full-bleed
  /// `ListView.builder` **byte for byte** — the wide-screen baseline in
  /// `test/widget/responsive_test.dart` pins that.
  final bool carded;

  @override
  Widget build(BuildContext context) {
    // `home.warning` (e.g. the Android multicast lock) is a discovery problem
    // too, and the banner's retry re-runs `discovery.start()` — which retakes
    // the lock — so it is folded in here as well as the rail indicator.
    final String? error = home.error ?? home.warning;
    final bool showSearch =
        !collapsibleSearch || controller.conversationSearchVisible;
    return Column(
      children: <Widget>[
        // The **network** layer, directly under the top bar (docs/18 §5.1
        // 候选①). Phone only — the wide / compact panes never draw it, so their
        // rendering is untouched (docs/18 §2.0).
        //
        // 0.2.9: the brand row that used to sit **above** this line is gone. The
        // brand moved up into the top bar itself (`PhoneShell._barTitle`), so the
        // bar's title, the mark and the product name are one row instead of two
        // stacked ones. The mark there is a real asset — `assets/brand/mark.png`,
        // the user's own artwork (source: the project's own vector artwork)
        // — which replaces the coloured-square stand-in this file used to draw
        // because no logo existed back then.
        if (carded) NetworkStatusRow(status: home.discoveryStatus),
        if (error != null)
          // E10 / A2-14: the persistent banner stays visible in the middle pane
          // (the left rail also shows its error dot, design §2.4).
          ErrorBanner(message: error, onRetry: home.retryDiscovery),
        if (showSearch) _searchField(),
        Expanded(child: _list(context)),
      ],
    );
  }

  // **0.2.9 — the brand row that used to sit above `NetworkStatusRow` is gone.**
  // The brand moved into the top bar itself (`PhoneShell._barTitle`), where the
  // mark is now a real asset — `assets/brand/mark.png`, the user's own artwork
  // (source: the project's own vector artwork) — instead of the coloured
  // square this file used to draw because no logo existed (§3.4 marked it 待核;
  // there was no `assets/` directory at all). The two rulings that shaped that
  // row still stand and are recorded with the replacement: no scan button (we
  // have no scan-to-pair — "抄了形状、没抄用途", §3.4), no ➕ (0.2.8, docs/19 §9.9:
  // the ⋮'s 「重新扫描」 already does it), and no 「网页版」 (a menu entry that can
  // never work is worse than a missing one).
  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: TextField(
          onChanged: controller.setConversationQuery,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            // 「筛选」, not 「搜索」 (0.2.56, the user's own wording call).
            //
            // The field only filters the rows that are **already in this list**
            // — `onChanged: setConversationQuery`, and `_list` drops rows whose
            // alias does not contain the query. It sends nothing, scans nothing,
            // and finds no new device. 「搜索设备」 read as "look for devices in
            // range", i.e. as the *discovery* action, which this never was.
            hintText: '筛选设备名',
            // Filled, not outlined (comparison-table row 7 — Feishu's controls
            // carry no ring; the fill value is the lead's pixel scan).
            filled: true,
            fillColor: kSearchFill,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kRadiusCard),
              borderSide: BorderSide.none,
            ),
            isDense: true,
          ),
        ),
      );

  Widget _list(BuildContext context) {
    // A2-2: loading is a distinct state, never the empty one.
    if (home.cards.isLoading) {
      return const LoadingState();
    }
    final List<PeerDevice> devices =
        home.cards.valueOrNull ?? const <PeerDevice>[];
    if (devices.isEmpty) {
      // A2-1: guidance + the four P0-10 troubleshooting hints + (0.2.54) the
      // escape hatch for a network that eats both discovery legs.
      //
      // The `SingleChildScrollView` and `EmptyState.devices` used to be `const`;
      // the button needs a callback, so both lose it. Nothing else about the
      // empty state changes.
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: EmptyState.devices(footer: _emptyFooter(context)),
      );
    }
    final String query = controller.conversationQuery.trim().toLowerCase();
    final List<PeerDevice> visible = <PeerDevice>[
      for (final PeerDevice device in devices)
        if (query.isEmpty || device.alias.toLowerCase().contains(query)) device,
    ];
    if (visible.isEmpty) {
      return const EmptyState(
        title: '没有匹配的设备',
        message: '换个关键词试试',
        icon: Icons.search_off,
      );
    }
    if (carded) {
      // The phone list (docs/18 §2.1): cards separated by **air**, never by a
      // 1px line. Purely additive — the `ListView.builder` below is untouched,
      // so the wide / compact rendering keeps its exact tree (docs/18 §2.0).
      return ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (BuildContext context, int index) =>
            const SizedBox(height: kCardGap),
        itemBuilder: (BuildContext context, int index) => DeviceRow(
          device: visible[index],
          selected:
              controller.selectedFingerprint == visible[index].fingerprint,
          onTap: () => controller.selectPeer(visible[index]),
          carded: true,
        ),
      );
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (BuildContext context, int index) {
        final PeerDevice device = visible[index];
        return DeviceRow(
          device: device,
          selected: controller.selectedFingerprint == device.fingerprint,
          onTap: () => controller.selectPeer(device),
        );
      },
    );
  }

  /// The empty list's footer: the four hints, then the manual-address entry.
  ///
  /// The button is **inside the empty state, not on the list** (0.2.54): typing
  /// an address is the *last* resort, after the four things worth checking — a
  /// permanently visible 「手动填写 IP」 would be a standing invitation to skip
  /// them, and it would also be one more control on a screen that has none. It is
  /// therefore rendered only while nothing has been found, and it disappears the
  /// moment a device appears.
  ///
  /// One implementation for both layouts: the phone and the desktop share this
  /// body (`carded` only changes how the *rows* are drawn), so there is no second
  /// copy of the entry point to keep in step.
  Widget _emptyFooter(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const TroubleshootHints(),
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const ValueKey<String>('manual-peer-entry'),
          onPressed: () => unawaited(_connectManualPeer(context)),
          icon: const Icon(Icons.add_link),
          label: const Text(kManualPeerActionLabel),
        ),
        const SizedBox(height: 8),
        Text(
          kManualPeerActionHint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// Asks for an address, then hands it straight to the controller.
  ///
  /// The dialog owns no probe (see `manual_peer_dialog.dart`): it returns the
  /// typed string, `HomeController.addManualPeer` decides what it means, and the
  /// same string is what the user can correct in place when it comes back as a
  /// sentence. On success the device simply appears — no confirmation dialog,
  /// because the list growing *is* the confirmation.
  ///
  /// The settings reload that has to follow a successful add lives inside
  /// [openManualPeerDialog] (0.2.56), because three doors now share this path:
  /// the empty list, this pane's ⋮, and 设置's add row. It is the one step that
  /// is easy to forget and impossible to notice until 设置 shows a stale count.
  Future<void> _connectManualPeer(BuildContext context) =>
      openManualPeerDialog(
        context,
        add: home.addManualPeer,
        reload: settings.load,
        // This device's own address, so the dialog can show it (0.2.58): on a
        // desktop this is the only place it can be read at all.
        localAddress: home.discoveryStatus.selfAddress,
        localPort: home.discoveryStatus.selfPort,
      );
}

/// The **network** status line on the phone home page (docs/18 §5.1 候选①).
///
/// This is the "本机这一侧" layer, deliberately separate from the per-peer layer
/// the device rows carry: mixing them into one dot leaves the user unable to tell
/// "my machine has no network" from "that machine is off" (docs/18 §5). Sitting
/// under the top bar is also what lets the two layers be told apart by
/// **position + icon + copy** rather than by colour — both stay in the blue
/// family by decision (docs/18 §1.3, candidate B).
///
/// It reads only data that already exists: [DiscoveryStatus.phase].
///
/// **It opens the 本机信息 sheet** (S9, docs/18 §3.3): tapping the row slides up
/// the alias / LAN address / port / fingerprint, and the row is the **only**
/// entry to it. (This note used to say the row deliberately had **no `onTap`**
/// while the sheet was still to come — that is no longer true, so it is
/// replaced rather than left to rot.)
class NetworkStatusRow extends StatelessWidget {
  /// Creates the line for [status] (the local discovery phase).
  const NetworkStatusRow({super.key, required this.status});

  /// The local discovery status — the network layer's only source.
  final DiscoveryStatus status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = status.phase == DiscoveryPhase.running
        ? statusNetwork
        : statusNetworkOff(theme);
    final IconData icon = switch (status.phase) {
      DiscoveryPhase.running => Icons.wifi,
      DiscoveryPhase.starting => Icons.wifi_find,
      DiscoveryPhase.failed => Icons.wifi_off,
    };
    final String label = switch (status.phase) {
      DiscoveryPhase.running => '已连接',
      DiscoveryPhase.starting => '正在连接…',
      DiscoveryPhase.failed => '未连接',
    };
    return InkWell(
      onTap: () => showLocalInfoSheet(
        context,
        // The two placeholders are constants (0.2.58) because the 设置 page's
        // 「本机信息」 row opens this same sheet with the same fallbacks — one
        // source, so the two doors cannot drift apart.
        alias: status.selfAlias ?? kSelfAliasUnknown,
        address: status.selfAddress ?? kSelfAddressUnknown,
        port: status.selfPort ?? 0,
        fingerprint: status.selfFingerprint ?? '',
      ),
      child: Padding(
        // 8, not 6 (0.2.9): the brand row's bottom padding (2) used to sit above
        // this line. With the row gone the row would hug the top bar, so its own
        // top padding takes over that air — 6 + 2 = 8 keeps the optical gap.
        padding:
            const EdgeInsets.fromLTRB(kListRowPadding, 8, kListRowPadding, 2),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// The conversations header's ⋮ items (0.2.56).
///
/// Both are **existing** capabilities; the menu changed *where* they live, never
/// *what* they do. Private to this file: no other surface has a reason to name
/// them, and the phone keeps its own enum (`_PhoneMenu`) because it carries one
/// extra action (the search reveal) the desktop does not need.
enum _ConversationsMenu { rescan, manualPeer }
