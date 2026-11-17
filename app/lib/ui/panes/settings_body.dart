/// The middle pane's `设置` body (design §1.3 / §1.4; Flix-aligned on a phone —
/// docs/18 §3.5).
///
/// **Two layouts, one owner.** On a **phone** the body is the Flix shape: a big
/// 「软件设置」 title, **grouped white cards** (1px lines *inside* a group, plain
/// air *between* groups), rows of `icon + title + grey value + ›`, the 检查更新
/// row as a static version string with no arrow, and 退出软件 as a standalone
/// card with centred red text. On **desktop / compact** the body renders the
/// fields / buttons / divider / [AcceptToggle] tree it has always rendered — with
/// **one 0.2.24 addition**: the 关于 entry, which used to be phone-only and left
/// `AboutPage` unreachable on a desktop build (see `_desktopBody`'s note).
///
/// **The receive switch lives here and must stay switchable** (docs/18 §3.5):
/// after the narrow bottom receive bar was removed, this is the **only** place
/// 接收模式 can be turned off — deleting it would make receiving impossible to
/// disable. Its name is deliberately **not** 「自动接收」: Flix's means "skip the
/// confirmation", ours means "receive at all", and the per-device settings page
/// already uses 「自动接收」 for the former.
///
/// Group code / transfer / extensions / donation / recommend / legal notice are
/// deliberately **absent** rather than present-but-inert (docs/18 §8.2): a row
/// that cannot do anything is a promise the app cannot keep.
///
/// Renaming only touches the alias through the controller — the certificate
/// directory is alias-independent, so the fingerprint never changes (spec §8.2).
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**`, `controllers/**` and sibling `ui/**` — never `dart:io` /
/// `dart:ffi` / `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_info.dart';
import '../../controllers/home_controller.dart';
import '../../controllers/settings_controller.dart';
import '../../domain/downloads_folder.dart'
    show
        downloadsFolderLabel,
        downloadsFolderPath,
        isDefaultDownloadsSubdirectory,
        kLanlinkDownloadsSubdirectory;
import '../../domain/manual_targets.dart';
import '../../domain/models.dart';
import '../../domain/peer_discovery.dart' show DiscoveryStatus;
import '../../domain/platform_ports.dart'
    show
        DownloadsFolderChoice,
        PickDownloadsFolderOutcome,
        PlatformPorts,
        ViewInDownloadsOutcome;
import '../about_page.dart';
import '../format.dart';
import '../notices.dart';
import '../scope.dart';
import '../theme.dart';
import '../widgets/accept_toggle.dart';
import '../widgets/error_banner.dart';
import '../widgets/loading_state.dart';
import '../widgets/local_info_sheet.dart';
import '../widgets/manual_peer_dialog.dart';

/// The settings and their persistence.
class SettingsBody extends StatefulWidget {
  /// Creates the settings body.
  ///
  /// [controller] is the app-level settings controller (created once by the
  /// host, design §2.5) — this widget never disposes it.
  ///
  /// [home] is the app-level home controller. It is read here for exactly one
  /// reason (0.2.54): removing a hand-typed address has to stop the discovery
  /// heartbeat that dials it, and that set lives behind the discovery port —
  /// `HomeController.removeManualPeer` is the one place that both forgets the
  /// address and edits the document.
  const SettingsBody({
    super.key,
    required this.controller,
    required this.home,
  });

  /// The app-level settings state.
  final SettingsController controller;

  /// The app-level home state (used only by 「手动添加的设备」 → 移除).
  final HomeController home;

  @override
  State<SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<SettingsBody> {
  final TextEditingController _aliasController = TextEditingController();
  final TextEditingController _directoryController = TextEditingController();
  String? _syncedAlias;
  String? _syncedDirectory;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    // ★ Mirror the CURRENT settings once, right here.
    //
    // `addListener` only fires for *future* notifications — it never replays the
    // current value. `load()` runs when the shell starts, while on a phone this
    // page is opened later, so the load's notification has already been delivered
    // by the time we subscribe: without this call the mirror below never runs and
    // the editors open on the controllers' initial `''`, even though the rows
    // above them read the live value and show the real path.
    //
    // This reads only `widget.controller.settings`, i.e. **no inherited widget**,
    // so it is safe to run before `initState` completes.
    _syncFields();
  }

  /// Mirrors the loaded settings into the two field controllers, once per value.
  void _syncFields() {
    final settings = widget.controller.settings.valueOrNull;
    if (settings == null) {
      return;
    }
    if (_syncedAlias != settings.alias) {
      _syncedAlias = settings.alias;
      _aliasController.text = settings.alias;
    }
    if (_syncedDirectory != settings.saveDirectory) {
      _syncedDirectory = settings.saveDirectory;
      _directoryController.text = settings.saveDirectory;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _aliasController.dispose();
    _directoryController.dispose();
    super.dispose();
  }

  /// Mirrors the loaded settings into the two fields once each, then rebuilds.
  void _onControllerChanged() {
    _syncFields();
    if (mounted) {
      setState(() {});
    }
  }

  void _saveAlias() {
    unawaited(widget.controller.applyAlias(_aliasController.text.trim()));
  }

  void _saveDirectory() {
    unawaited(
        widget.controller.setSaveDirectory(_directoryController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.settings.isLoading) {
      return const LoadingState(message: '正在读取设置…', showProgress: false);
    }
    final String? error = widget.controller.error;
    final bool phone = context.deps.platform.isMobile;
    return ListView(
      // The phone page inset is the card inset (docs/18 §2.1/§3.5); the desktop
      // keeps its original padding so its rendering is unchanged.
      padding: phone
          ? const EdgeInsets.fromLTRB(kListRowPadding, 8, kListRowPadding, 28)
          : const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        if (error != null)
          ErrorBanner(
            message: error,
            onRetry: widget.controller.clearError,
            retryLabel: '知道了',
          ),
        if (phone) ..._phoneBody(context) else ..._desktopBody(context),
      ],
    );
  }

  // ── phone: the Flix shape (docs/18 §3.5) ───────────────────────────────────

  List<Widget> _phoneBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppSettings? settings = widget.controller.settings.valueOrNull;
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 18),
        // The big in-body title. After scrolling, the shell's AppBar carries the
        // same word — that bar is the "sticks to the top, centred" title
        // (docs/18 §3.5); this one is the head of the page.
        child: Text(
          '软件设置',
          style: theme.textTheme.headlineMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      // Card 1 — settings. The receive switch is the third row: it is a
      // `SwitchListTile` already (its own 「接收模式」 label + explanation), so it
      // drops in unchanged and stays the single, working place to turn
      // receiving off.
      _card(theme, <Widget>[
        // 0.2.58 — 本机信息 is the **first** row of the first card: the page's
        // identity block opens with "which machine is this", and its value (the
        // LAN address) is the one thing a user setting up a second device needs
        // before anything below it matters. Inside the same card, not a card of
        // its own: it answers the same question the rows under it do ("this
        // device"), which is the rule `_manualPeerCard` follows too.
        _localInfoRow(theme),
        _cardDivider(theme),
        _valueRow(
          theme,
          icon: Icons.smartphone_outlined,
          title: '本机名称',
          value: settings?.alias ?? '',
          onTap: () => unawaited(_editAlias(context)),
        ),
        _cardDivider(theme),
        // 0.2.23 — **not editable on a phone, and it says so honestly.**
        //
        // It used to be a `_valueRow` showing `settings.saveDirectory`, i.e.
        // `/data/user/0/<pkg>/files/lanlink/received` on Android — a path the
        // user can neither reach nor change, offered as a tappable 「更改位置」
        // editor that could not change anything: since 0.2.19 that directory is
        // only a **temporary landing spot** (`create_deps_native.dart`), and the
        // file is published to `Download/lanlink` and then deleted from it
        // (`received_file_publisher.dart`). Editing it therefore promised
        // something the app never did. The 复制/更改 editor stays gone.
        //
        // **0.2.26 — the row is tappable again, but for a real reason this time.**
        // 0.2.23's replacement was a `_noteRow`: no ink, no `›`, no handler. The
        // user read that as a bug ("点了没反应，是故意为之还是bug呢") — and they
        // were right to: a row that *looks* like a destination and cannot be
        // touched is indistinguishable from a broken one. The position is still
        // fixed (nothing can change it — see above), but the tap now does the one
        // useful thing: **opens that folder** in the system file manager, via the
        // same native `viewInDownloads` the attachment menu uses (0.2.24), in its
        // no-file form (`openDownloadsFolder`).
        //
        // The value moves into the trailing slot (「下载 / lanlink」 + `›`), so the
        // row states *where* and advertises *that it does something* — while the
        // subtitle names the action outright, because "值 + ›" alone could as
        // easily mean "edit this".
        // The value and the hint share the subtitle block — **two grey lines**,
        // one widget, `isThreeLine`.
        //
        // ★ Why the folder is not in the `›`-side slot (where 关于我们 keeps its
        // version): measured at 320dp, 「下载 / lanlink」 + the `›` leaves the title
        // *no* width at all — the row's own name 「文件保存位置」 renders 0 dp wide
        // (six one-character lines) or the row overflows by 9 px. A settings row
        // whose name disappears to make room for its value is worse than a taller
        // row: the title is what the user scans for. So the value sits under the
        // title, where it has the row's full width, and the `›` still says "this
        // does something".
        //
        // **0.2.29 — three states, one row.** The value is `下载 / <current>`, so
        // it reads `下载 / lanlink` on a fresh install and `下载 / 素材` after a
        // pick; the hint says what a tap does, and a tap opens a small menu
        // (打开 / 选择 / 恢复默认) rather than jumping anywhere. The menu is the
        // answer to "the row must not surprise me": 0.2.26 made the tap open the
        // folder, and 0.2.29 adds *choosing*, which is a different question — one
        // of them has to be asked rather than assumed.
        _navRow(
          theme,
          icon: Icons.folder_outlined,
          title: '文件保存位置',
          isThreeLine: true,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                downloadsFolderLabel(settings?.receivedSubdirectory),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(
                '点一下选择文件夹',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
          onTap: () => unawaited(_showSaveLocationMenu(context)),
        ),
        _cardDivider(theme),
        AcceptToggle(
          accepting: widget.controller.accepting,
          // Honest while unloaded: disabled rather than clickable-but-inert
          // (the controller also guards, but the UI must not lie).
          enabled: widget.controller.ready,
          onChanged: (bool value) =>
              unawaited(widget.controller.setAccepting(value)),
        ),
      ]),
      const SizedBox(height: kCardGap),
      // Card 1b — 手动添加的设备 (0.2.54; **always drawn** since 0.2.56).
      //
      // It used to be hidden while the list was empty, on the theory that the
      // empty device list was the way in. That theory broke the first time the
      // user had one device: a card outlives discovery (it is rebuilt from the
      // stored row / the conversation), so the device list never empties again —
      // and "再加一台，自动发现又没扫到" had **no** entry anywhere. The block now
      // carries its own 添加设备地址 row and stays put.
      ..._manualPeerSection(theme, settings),
      // Card 2 — about. Reuses the existing page; no new content.
      _card(theme, <Widget>[
        _navRow(
          theme,
          icon: Icons.forum_outlined,
          title: '关于我们',
          // The version rides here as this row's value. It used to be its own
          // 「检查更新」 row, but there is no update server: that row could only
          // ever be decorative, and a row that looks tappable and does nothing is
          // the one shape we ruled out (docs/18 §8.2). The spec allows "just
          // don't build it" — this is that, with the number still visible.
          value: '版本 $kAppVersion',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const AboutPage(),
            ),
          ),
        ),
      ]),
      const SizedBox(height: kCardGap),
      // The next card is 退出软件 — its own card, centred red text, no arrow
      // (docs/18 §3.5).
      _card(theme, <Widget>[_exitRow(context, theme)]),
    ];
  }

  /// One grouped white card: `icon + title (+ grey value) + ›` rows, separated
  /// by a 1px line **inside** the card — the air between cards is [kCardGap].
  Widget _card(ThemeData theme, List<Widget> children) => ClipRRect(
        borderRadius: BorderRadius.circular(kRadiusCard),
        // A `Material`, not a coloured `Container`: the rows are `ListTile`s and
        // they paint their ink on the nearest Material ancestor — a ColoredBox
        // there makes the tap feedback invisible (Flutter asserts exactly that).
        child: Material(
          color: cardSurface(theme),
          child: Column(children: children),
        ),
      );

  /// The hairline **inside** a card (docs/18 §2.1).
  Widget _cardDivider(ThemeData theme) =>
      Divider(height: 1, thickness: 1, color: dividerColor(theme));

  // ── 手动添加的设备 (0.2.54) ────────────────────────────────────────────────
  //
  // The user's own list of addresses, and the only place one can be removed.
  //
  // **Removal is not cosmetic — it is what keeps the feature alive.** The
  // heartbeat re-dials every address **serially** with a 3 s deadline each, so a
  // list that only ever grows (nine addresses that no longer exist would take
  // 27 s a pass) stalls the 25 s timer and takes the *working* peers down with
  // it. Hence a cap of `kMaxManualPeers` on the way in and a 移除 row on the way
  // out. Removing an address does **not** delete the device: the peer stays in the
  // list and goes grey when it stops answering, exactly like a peer found by
  // multicast.

  /// The 「手动添加的设备」 block. **Always** returns a heading + a card + the gap
  /// after it (0.2.56), even with zero addresses — see the caller for why an empty
  /// heading is now the lesser evil: the row inside it is the only durable door
  /// into the feature, and the only place the `n / 8` count is visible.
  ///
  /// The caller already emitted the gap before it, so a card-to-card rhythm
  /// stays uniform.
  List<Widget> _manualPeerSection(ThemeData theme, AppSettings? settings) {
    final List<ManualPeerTarget> peers =
        settings?.manualPeers ?? const <ManualPeerTarget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(kManualPeerListTitle, style: theme.textTheme.titleSmall),
      ),
      _manualPeerCard(theme, peers),
      const SizedBox(height: kCardGap),
    ];
  }

  /// One grouped card: `192.168.1.23:49494` + 移除 per address, then the add row.
  ///
  /// The add row lives **inside** the same card, not in a card of its own: it
  /// answers the same question as the rows above it ("which addresses am I
  /// dialling?") and shares their count. A separate card would read as a
  /// different setting.
  Widget _manualPeerCard(ThemeData theme, List<ManualPeerTarget> peers) =>
      _card(theme, <Widget>[
        for (int i = 0; i < peers.length; i += 1) ...<Widget>[
          if (i > 0) _cardDivider(theme),
          _manualPeerRow(theme, peers[i]),
        ],
        if (peers.isNotEmpty) _cardDivider(theme),
        _manualPeerAddRow(theme, peers.length),
      ]);

  /// 「添加设备地址」 + the count on the right.
  ///
  /// At [kMaxManualPeers] the row is **disabled** (and says 已满) rather than
  /// opening a dialog whose only possible ending is the capacity sentence: a
  /// control that looks usable and always fails is the shape this project ruled
  /// out. The count is not decoration — the limit comes from the heartbeat's
  /// serial 3 s deadlines, so "how many are left" is the number that decides
  /// whether the feature keeps working.
  Widget _manualPeerAddRow(ThemeData theme, int count) {
    final bool full = count >= kMaxManualPeers;
    return ListTile(
      key: const ValueKey<String>('manual-peer-add'),
      enabled: !full,
      leading: Icon(
        Icons.add_link,
        color: full ? theme.disabledColor : theme.colorScheme.primary,
      ),
      title: Text(
        kManualPeerAddLabel,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: full ? theme.disabledColor : theme.colorScheme.primary,
        ),
      ),
      trailing: Text(
        full ? kManualPeerFullLabel : '$count / $kMaxManualPeers',
        // The trailing text greys out with the row (0.2.57). It carries the
        // sentence that *explains* why the row cannot be tapped (「已满 8 个」), and
        // it was the only part still painted in the live colour — the one string
        // that matters most reading as enabled.
        style: theme.textTheme.bodySmall?.copyWith(
          color: full
              ? theme.disabledColor
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: full ? null : () => unawaited(_addManualPeer()),
    );
  }

  /// The add row's tap: the same dialog and the same controller call the device
  /// list uses (`openManualPeerDialog` also does the settings reload that makes
  /// the new row appear here without restarting).
  ///
  /// It passes this device's own address too (0.2.58), so the dialog opens
  /// stating what to type on the other machine — on a desktop, 设置 is the page
  /// the user is already on when they wonder what their own IP is.
  Future<void> _addManualPeer() => openManualPeerDialog(
        context,
        add: widget.home.addManualPeer,
        reload: widget.controller.load,
        localAddress: widget.home.discoveryStatus.selfAddress,
        localPort: widget.home.discoveryStatus.selfPort,
      );

  // ── 本机信息 (0.2.58) ────────────────────────────────────────────────────────
  //
  // **The gap this closes.** The 本机信息 sheet — alias, LAN address, port,
  // fingerprint — existed and had exactly **one** door: the phone's
  // `NetworkStatusRow` (`list_pane.dart`, drawn only when `carded`, i.e. only in
  // `PhoneShell`). On a desktop the sheet was unreachable, and the only port the
  // app ever printed there was `about_page.dart`'s hardcoded 49494. So "connect
  // by hand from the computer" required first walking over to the phone to read
  // its address — the exact dead end this row removes.
  //
  // It is the **same sheet**, opened with the **same fallbacks** the phone's row
  // uses: one destination, two doors. The row's value is the live address because
  // "what am I" is the question a settings page should answer without a tap.

  /// The 「本机信息」 row, shared by both layouts.
  ///
  /// [_navRow], not a new widget: it is the shape this page already uses for
  /// "name + value + ›", and the `›` is honest here — the tap really does open
  /// something.
  Widget _localInfoRow(ThemeData theme) {
    final DiscoveryStatus status = widget.home.discoveryStatus;
    return _navRow(
      theme,
      icon: Icons.info_outline,
      title: kLocalInfoTitle,
      // The grey value is the address itself, or the placeholder — never a guess.
      value: status.selfAddress ?? kSelfAddressUnknown,
      onTap: () => showLocalInfoSheet(
        context,
        alias: status.selfAlias ?? kSelfAliasUnknown,
        address: status.selfAddress ?? kSelfAddressUnknown,
        port: status.selfPort ?? 0,
        fingerprint: status.selfFingerprint ?? '',
      ),
    );
  }

  /// One stored address. The address is the title (it is what the user
  /// recognises); the action is a single icon with a tooltip, because a text
  /// button per row would dominate the card.
  Widget _manualPeerRow(ThemeData theme, ManualPeerTarget target) {
    final String text = manualPeerText(target);
    return ListTile(
      leading: Icon(Icons.link, color: theme.colorScheme.onSurfaceVariant),
      title: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      trailing: IconButton(
        // Keyed by the address so a test can tap *this* row's button on a list
        // of several, and so two rows can never be confused.
        key: ValueKey<String>('manual-peer-remove-$text'),
        tooltip: '移除',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => unawaited(_removeManualPeer(target)),
      ),
    );
  }

  /// 移除: stop the heartbeat, forget the address, then re-read the document.
  ///
  /// The order is the contract (`HomeController.removeManualPeer` owns it): the
  /// dialling stops first — that is the behaviour the user asked to end — and the
  /// document is edited second. This method only mirrors the result: `load()`
  /// replaces this page's settings state, which is what makes the row disappear
  /// (and what makes a **failed** write visible as a row that is still there,
  /// together with the sentence saying so).
  Future<void> _removeManualPeer(ManualPeerTarget target) async {
    final String? problem = await widget.home.removeManualPeer(target);
    if (!mounted) {
      return;
    }
    await widget.controller.load();
    if (!mounted || problem == null) {
      return;
    }
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      showTransientNoticeOn(messenger, problem);
    }
  }

  /// A row that carries the current value as a grey second line and opens an
  /// editor — the `›` is backed by a real action, never decorative.
  Widget _valueRow(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) =>
      ListTile(
        leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
        title: Text(title),
        subtitle: value.isEmpty
            ? null
            : Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
        trailing: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        onTap: onTap,
      );

  /// A row that **only states a fact**: no value, no `›`, no `onTap`.
  ///
  /// It existed so a setting that could not be changed on a platform was still
  /// visible (the user needs to know where their files go) without being offered
  /// as an action — a `ListTile` with no `onTap` paints no ink and reads as plain
  /// text to a screen reader, which is the contract docs/18 §8.2 asks for.
  ///
  /// **0.2.26 deleted it**, together with its only caller: 文件保存位置 is now a
  /// real action (it opens the folder), so nothing in this file is a read-only
  /// fact row any more. It is ten lines in git history (`git log -S _noteRow`)
  /// if a future candidate from docs/18c needs the shape again — carrying an
  /// uncalled widget with an `ignore: unused_element` would be the very kind of
  /// "looks supported, quietly is not" that this file keeps removing.

  /// A row that opens another page, optionally reporting a value beside its
  /// arrow (the reference's `value ›` shape).
  ///
  /// [subtitle] is a widget, not a string, because 0.2.26 needs **two** grey
  /// lines under the title (the folder, then what a tap does) while staying one
  /// `ListTile`; [isThreeLine] tells the tile to reserve that height.
  ///
  /// ★ **The `value` lives inside the `title` row, not in `trailing`.** Both
  /// shapes look identical (value right-aligned just before the `›`), but they
  /// degrade very differently on a narrow phone: `trailing` receives *loose
  /// constraints as wide as the tile*, so a value there is measured at full
  /// intrinsic width first and the title gets what is left — measured at 320dp
  /// with the test font, the title of the 「文件保存位置」 row came out **0 dp wide
  /// and 144 dp tall** (six one-character lines): the row's own name disappeared
  /// to make room for a secondary value.
  ///
  /// Inside the title row the two share one bounded width (`Expanded` title +
  /// `Flexible` value), so neither can overflow; at 320dp the *value* ellipsizes,
  /// which is the right sacrifice — the title is what names the row.
  Widget _navRow(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    String? value,
    Widget? subtitle,
    bool isThreeLine = false,
  }) {
    final Widget titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
      title: value == null
          ? titleText
          : Row(
              children: <Widget>[
                Expanded(child: titleText),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
      subtitle: subtitle,
      isThreeLine: isThreeLine,
      trailing: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
      onTap: onTap,
    );
  }

  /// 退出软件 — its own card, centred red, no arrow (docs/18 §3.5).
  ///
  /// The colour comes from the `dangerAction` slot, so it changes with the
  /// palette instead of being a hex written here.
  Widget _exitRow(BuildContext context, ThemeData theme) => ListTile(
        title: Text(
          '退出软件',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(color: dangerAction),
        ),
        onTap: () => SystemNavigator.pop(),
      );

  /// The folder the user configured right now (normalised; never blank).
  ///
  /// Read from the controller rather than from the port on purpose: the row's
  /// value and the row's actions must describe **the same** folder, and the
  /// controller is what the page already rebuilds on.
  String get _receivedSubdirectory =>
      widget.controller.settings.valueOrNull?.receivedSubdirectory ??
      kLanlinkDownloadsSubdirectory;

  /// 「文件保存位置」 tapped on a phone (0.2.26 → 0.2.29): ask, don't assume.
  ///
  /// 0.2.26 made the tap open the folder — the answer to 「点了没反应」. With a
  /// *choosable* folder (0.2.29) a tap can no longer mean one thing, so it opens
  /// this three-row sheet:
  ///
  /// * 打开文件夹 — the 0.2.26 behaviour, still one tap away (dropping it would
  ///   re-break the complaint that produced it);
  /// * 选择文件夹 — the new capability;
  /// * 恢复默认 — **only when the current folder is not the default**, so the row
  ///   never offers a no-op.
  ///
  /// A bottom sheet, not a context menu: on a phone the sheet is the platform's
  /// own "small list of choices", it is reachable one-handed, and it does not
  /// depend on the row's pixel position.
  Future<void> _showSaveLocationMenu(BuildContext context) async {
    final String subdirectory = _receivedSubdirectory;
    final bool isDefault = isDefaultDownloadsSubdirectory(subdirectory);
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      // The sheet is about this one row; it must not outlive a module switch.
      builder: (BuildContext sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('打开文件夹'),
              subtitle: Text(downloadsFolderLabel(subdirectory)),
              onTap: () => Navigator.of(sheetContext).pop('open'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('选择文件夹'),
              subtitle: const Text('只能选「下载」里的文件夹'),
              onTap: () => Navigator.of(sheetContext).pop('pick'),
            ),
            if (!isDefault)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('恢复默认'),
                subtitle: Text(downloadsFolderLabel(kLanlinkDownloadsSubdirectory)),
                onTap: () => Navigator.of(sheetContext).pop('reset'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) {
      return;
    }
    switch (choice) {
      case 'open':
        await _openDownloadsFolder(context);
      case 'pick':
        await _pickDownloadsFolder(context);
      case 'reset':
        await widget.controller
            .setReceivedSubdirectory(kLanlinkDownloadsSubdirectory);
    }
  }

  /// Asks the platform for a folder and stores it — **only** if it is usable.
  ///
  /// Three of the five outcomes change nothing, and each says why (or says
  /// nothing, for a cancel):
  /// * [PickDownloadsFolderOutcome.cancelled] — the user backed out. Silence: a
  ///   toast for "you changed your mind" is noise;
  /// * [PickDownloadsFolderOutcome.invalid] — the pick was outside `Download` (or
  ///   was the `Download` root itself). The message names what is allowed, and the
  ///   stored setting is untouched, so files keep landing where they did;
  /// * [PickDownloadsFolderOutcome.unsupported] /  [PickDownloadsFolderOutcome.failed]
  ///   — the chooser could not run. Also nothing stored.
  ///
  /// A **persist failure** is not handled here: `setReceivedSubdirectory` routes
  /// it into `controller.error`, which this page draws as the in-place error
  /// banner (the 0.2.23 rule — never a silent fallback).
  Future<void> _pickDownloadsFolder(BuildContext context) async {
    final PlatformPorts platform = context.deps.platform;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final DownloadsFolderChoice choice = await platform.pickDownloadsFolder();
    if (!mounted) {
      return;
    }
    switch (choice.outcome) {
      case PickDownloadsFolderOutcome.cancelled:
        return;
      case PickDownloadsFolderOutcome.invalid:
        showTransientNoticeOn(messenger, '请选择「下载」里的文件夹');
        return;
      case PickDownloadsFolderOutcome.unsupported:
        showTransientNoticeOn(messenger, '这个系统不能选择保存文件夹');
        return;
      case PickDownloadsFolderOutcome.failed:
        showTransientNoticeOn(
          messenger,
          '选择文件夹失败：${choice.reason ?? '未知原因'}',
        );
        return;
      case PickDownloadsFolderOutcome.picked:
        await widget.controller
            .setReceivedSubdirectory(choice.subdirectory ?? '');
    }
  }

  /// 「文件保存位置」 → 打开文件夹: hand the **current** folder to the platform.
  ///
  /// **What this is not.** It is not an editor and it changes nothing — on
  /// Android `saveDirectory` is a temporary landing spot whose contents are
  /// published to the chosen folder under `Download` and then deleted (0.2.23
  /// removed the editor that pretended otherwise). It is the *destination* that
  /// gets opened, and since 0.2.29 that destination is user-configurable.
  ///
  /// **Every outcome is answered**, and the two dead ends end the same way: the
  /// readable folder path really goes to the clipboard, then the user is told.
  /// The clipboard is written with `await` **before** the message, because a
  /// toast that says 「路径已复制到剪贴板」 before anything was copied is a lie the
  /// user can catch by pasting — the same rule the attachment menu follows.
  ///
  /// [ViewInDownloadsOutcome.opened] stays silent: the folder the user just
  /// opened is its own confirmation.
  Future<void> _openDownloadsFolder(BuildContext context) async {
    final PlatformPorts platform = context.deps.platform;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String subdirectory = _receivedSubdirectory;
    final ViewInDownloadsOutcome outcome =
        await platform.openDownloadsFolder(subdirectory: subdirectory);
    // The await can outlive this page (back button, module switch); writing to a
    // disposed messenger would throw.
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case ViewInDownloadsOutcome.opened:
        return;
      case ViewInDownloadsOutcome.noApp:
      case ViewInDownloadsOutcome.noDirectory:
        await Clipboard.setData(
          ClipboardData(text: downloadsFolderPath(subdirectory)),
        );
        showTransientNoticeOn(
          messenger,
          '这个系统没有能打开文件夹的应用，路径已复制到剪贴板',
        );
      case ViewInDownloadsOutcome.unsupported:
      case ViewInDownloadsOutcome.failed:
        await Clipboard.setData(
          ClipboardData(text: downloadsFolderPath(subdirectory)),
        );
        showTransientNoticeOn(messenger, '打开文件夹失败，路径已复制到剪贴板');
    }
  }

  /// The alias editor, opened from the 本机名称 row.
  Future<void> _editAlias(BuildContext context) => _edit(
        context,
        title: '本机名称',
        controller: _aliasController,
        actionLabel: '保存名称',
        onSave: _saveAlias,
      );

  // 0.2.23 deleted `_editDirectory` (the phone's 更改位置 editor): a phone has no
  // editable save location. The receive directory is the app-private landing
  // spot and the published copy always goes to `Download/lanlink`, so the editor
  // could only ever lie. Desktop keeps its inline field + 更改位置 button, which
  // now take effect immediately (see `SettingsController.setSaveDirectory`).

  /// A small editor dialog. It holds the **same** controller and calls the
  /// **same** handler the inline desktop fields use, so the phone gains a row
  /// shape without a second way of writing settings.
  Future<void> _edit(
    BuildContext context, {
    required String title,
    required TextEditingController controller,
    required String actionLabel,
    required VoidCallback onSave,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              onSave();
              Navigator.of(dialogContext).pop();
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  // ── desktop / compact: the original tree, plus the About entry (0.2.24) ────

  List<Widget> _desktopBody(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return <Widget>[
      // ★ 0.2.58 — 本机信息, as its **own card at the very top**, and the reason it
      // is a card here rather than "the first row of the first card" (the phone's
      // shape):
      //
      // the desktop body has **no first card** — it opens with bare `_field`s
      // (本机名称 / 保存位置 / 接收模式) and only switches to rounded cards for
      // 手动添加的设备 and 关于我们 further down. Wrapping those three fields in a
      // card so that a row could be "the first row of one" would restyle the
      // whole page; reusing the card shape the two blocks below already have
      // (`_card` + `_navRow`, inset 16 to match `_field`) adds the row without
      // touching a line of what was there. The `gap` below keeps that card-to-
      // block rhythm.
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _card(theme, <Widget>[_localInfoRow(theme)]),
      ),
      const SizedBox(height: kCardGap),
      _field(
        controller: _aliasController,
        label: '本机名称',
        helper: '修改后立即生效，且不会改变本机指纹',
      ),
      _action(label: '保存名称', onPressed: _saveAlias),
      const Divider(height: 1),
      _field(
        controller: _directoryController,
        label: '保存位置',
        // 0.2.23: "改完立即生效" is now literally true — `setSaveDirectory`
        // rebuilds the receiver before persisting (see
        // `SettingsController.setSaveDirectory`).
        helper: '接收到的文件会保存到这个目录，改完立即生效',
      ),
      _action(label: '更改位置', onPressed: _saveDirectory),
      const Divider(height: 1),
      AcceptToggle(
        accepting: widget.controller.accepting,
        enabled: widget.controller.ready,
        onChanged: (bool value) =>
            unawaited(widget.controller.setAccepting(value)),
      ),

      // 手动添加的设备 (0.2.54) — the **same** block the phone draws, inset by 16
      // like every other rounded card on this layout (a card flush against the
      // pane edge has its corners clipped, which reads as a rendering bug).
      //
      // **Unconditional since 0.2.56.** This branch used to carry its own
      // `isNotEmpty` guard — a second copy of the rule the phone had — and the
      // two of them together meant the feature had no door at all once the device
      // list stopped being empty (a card outlives discovery, so that is *after
      // the first transfer, forever*). Now the heading + the add row are always
      // there, on both layouts, from the same `_manualPeerCard`.
      const SizedBox(height: kCardGap),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          kManualPeerListTitle,
          style: theme.textTheme.titleSmall,
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _manualPeerCard(
          theme,
          widget.controller.settings.valueOrNull?.manualPeers ??
              const <ManualPeerTarget>[],
        ),
      ),

      // ★ 0.2.24 — the desktop gains the 关于 entry it never had.
      //
      // Until now `AboutPage` was reachable **only** from `_phoneBody`: this
      // branch rendered 名称 / 保存位置 / 接收模式 and stopped, so on a desktop
      // build the page existed and nothing could open it (verified by
      // `test/widget/desktop_about_reachability_test.dart`, which walked
      // 启动 → rail「设置」 and found no entry). A page you cannot reach is the
      // same as no page.
      //
      // **The row is `_navRow`, the phone's own** — not a second, desktop-shaped
      // spelling of it. Same icon, same 「关于我们」, same version beside the `›`,
      // same `AboutPage`: one entry, two layouts (the pairing docs/18 §3.5 asked
      // for). Reusing it is also what keeps the 版本 number single-sourced from
      // [kAppVersion].
      //
      // The card is inset by 16 horizontally — the same inset `_field` /
      // `_action` above already use — because a rounded card flush against the
      // pane edges would have its corners clipped by the pane, which reads as a
      // rendering bug rather than a card.
      const SizedBox(height: kCardGap),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _card(theme, <Widget>[
          _navRow(
            theme,
            icon: Icons.forum_outlined,
            title: '关于我们',
            value: '版本 $kAppVersion',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const AboutPage(),
              ),
            ),
          ),
        ]),
      ),
    ];
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String helper,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  Widget _action({
    required String label,
    required VoidCallback onPressed,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: FilledButton(onPressed: onPressed, child: Text(label)),
        ),
      );
}
