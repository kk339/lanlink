/// The right pane of the three-pane shell (design §1.4 / §2.4 / §6).
///
/// It is a **dispatcher** over `ShellController.module` and the single owner of
/// the per-conversation `ConversationController` (design §2.5): when the
/// selected conversation changes, the old controller is disposed and a new one
/// is built and loaded. It also renders the conversation header (peer avatar +
/// alias + online marker + 媒体与文件 entry + menu) and the `消息 / 文件` tab bar,
/// and the narrow window's back affordance.
///
/// The selected recent file (recent-files module) is read from the **same**
/// `RecentFilesController` the middle pane uses (design §2.4): the shell carries
/// only `selectedFileId` / `selectedFileMessageId` (design §2.3), which this
/// pane resolves against `RecentFilesController.visible`. Both panes therefore
/// render the *one* `RecentFileItem` — including its single `sourceMissing`
/// verdict, so the two panes can never disagree about whether a file is gone.
///
/// **Layering (design §9.6):** imports only `package:flutter/**`, this package's
/// `domain/**`, `controllers/**` and sibling `ui/**` — never `dart:io` /
/// `dart:ffi` / `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../bootstrap/app_deps.dart';
import '../../controllers/conversation_controller.dart';
import '../../controllers/home_controller.dart';
import '../../controllers/recent_files_controller.dart';
import '../../domain/models.dart';
import '../../domain/platform_ports.dart';
import '../../domain/selectors.dart';
import '../format.dart';
import '../panes/conversation_files.dart';
import '../panes/conversation_thread.dart';
import '../panes/device_profile.dart';
import '../panes/file_detail.dart';
import '../scope.dart';
import '../notices.dart';
import '../theme.dart';
import '../widgets/device_row.dart';
import '../widgets/empty_state.dart';
import '../widgets/loading_state.dart';
import 'shell_controller.dart';
import 'shell_module.dart';
import 'share_intake.dart';

/// The right pane: the selected conversation, the selected file detail, or a
/// module placeholder.
class DetailPane extends StatefulWidget {
  /// Creates the right pane.
  ///
  /// [showBack] draws the narrow-window "←" (design §6.1), wired to
  /// `ShellController.closeDetail`.
  const DetailPane({
    super.key,
    required this.controller,
    required this.home,
    required this.recentFiles,
    this.shareIntake,
    this.onRetargetDraft,
    this.showBack = false,
  });

  /// The shared shell state (module + selection + right tab).
  final ShellController controller;

  /// The app-level home state (merged cards for the peer header).
  final HomeController home;

  /// The app-level recent-files state — the **same** source the middle pane
  /// reads, so a selected row's file (and its `sourceMissing` verdict) is
  /// identical on both sides.
  final RecentFilesController recentFiles;

  /// The inbound-share intake (0.2.18), or `null` in a test that mounts this
  /// pane alone. When present, a file the user shared **into** lanlink is handed
  /// to the thread as an unsent draft (`ShareIntake.draftFor`), so it appears
  /// above the composer and waits for 发送.
  final ShareIntake? shareIntake;

  /// Asks to move the staged draft to another device (0.2.63), or `null` when
  /// this host has no device chooser to offer.
  ///
  /// Only the shell can answer it: it owns the picker and the selection the draft
  /// is keyed on. The pane therefore does no work of its own — it only forwards
  /// the callback to the thread, which draws 「改发到…」 **only when it is
  /// non-null** (so a thread mounted by a test, or by a host without the shell,
  /// keeps the pre-0.2.63 one-line row).
  final VoidCallback? onRetargetDraft;

  /// Whether to draw the narrow-window back affordance.
  final bool showBack;

  @override
  State<DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<DetailPane> {
  ConversationController? _conversation;
  String? _boundConversationId;
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_listening) {
      widget.controller.addListener(_onShellChanged);
      widget.home.addListener(_onShellChanged);
      // A share landing (or being sent / discarded) must repaint this pane — the
      // draft row lives in the thread below it.
      widget.shareIntake?.addListener(_onShellChanged);
      _listening = true;
    }
    _reconcileConversation();
  }

  @override
  void dispose() {
    if (_listening) {
      widget.controller.removeListener(_onShellChanged);
      widget.home.removeListener(_onShellChanged);
      widget.shareIntake?.removeListener(_onShellChanged);
    }
    _conversation?.dispose();
    widget.controller.conversationController = null;
    super.dispose();
  }

  void _onShellChanged() {
    _reconcileConversation();
    if (mounted) {
      setState(() {});
    }
  }

  /// Creates / disposes the per-selection [ConversationController] (design
  /// §2.5). A no-op while the bound conversation id is unchanged, so a rebuild
  /// never re-creates or re-loads the thread.
  void _reconcileConversation() {
    final String? id = widget.controller.selectedConversationId;
    if (id == _boundConversationId) {
      return;
    }
    _conversation?.dispose();
    _conversation = null;
    // 0.2.41: the shell's ⋯ menu points at whatever conversation is open, so the
    // reference has to be withdrawn together with the controller it named.
    widget.controller.conversationController = null;
    _boundConversationId = id;
    if (id == null) {
      return;
    }
    final AppDeps deps = context.deps;
    final ConversationController conversation = ConversationController(
      repo: deps.repo,
      orchestrator: deps.orchestrator,
      platform: deps.platform,
      ids: deps.ids,
      clock: deps.clock,
      conversationId: id,
      // 0.2.23: a delivered send frees the app's temporary copy of each picked /
      // shared file, so `cache/lanlink-picked/` no longer grows by one full copy
      // per file the user ever sends.
      pickedCache: deps.pickedCache,
    );
    _conversation = conversation;
    widget.controller.conversationController = conversation; // 0.2.41
    unawaited(conversation.load());
  }

  @override
  Widget build(BuildContext context) {
    // The narrow window shows one module at a time and needs a way back to the
    // list — for **both** detail kinds (conversation AND file), so the ← bar is
    // drawn here, wrapping whichever module body is active (M5 §3.4 / A2-4).
    // `showBack` is only `true` on a narrow window (the host passes it), so the
    // wide / compact layouts never draw a ← bar (constraints #1 / #5).
    final Widget body = switch (widget.controller.module) {
      ShellModule.conversations => _conversationModule(context),
      ShellModule.recentFiles => _fileModule(context),
      ShellModule.archived => const EmptyState(
          title: '已归档',
          message: '归档会话仅作查看，不支持恢复或删除',
          icon: Icons.archive_outlined,
        ),
      ShellModule.settings => const EmptyState(
          title: '设置',
          message: '设置已在中间栏完成',
          icon: Icons.settings_outlined,
        ),
    };
    // docs/19 §8-②: the right pane shares **one** surface with the middle pane
    // (`kPaneSurface`), so the two read as a single sheet cut by a seam. It used
    // to paint `colorScheme.surface` (#FAF8FF, a seed-tinted white) of its own —
    // that is what made the columns read as three differently-tinted bands.
    return Container(
      color: paneSurface(Theme.of(context)),
      child: body,
    );
  }

  // ── conversation module ──────────────────────────────────────────────────

  Widget _conversationModule(BuildContext context) {
    final String? conversationId = widget.controller.selectedConversationId;
    if (conversationId == null) {
      // H36: never a blank hole — the global placeholder.
      return const EmptyState.rightPlaceholder();
    }
    final ConversationController? conversation = _conversation;
    if (conversation == null) {
      return const LoadingState(showProgress: false);
    }
    final PeerDevice peer = _peerFor(context, conversationId);
    // A file the user shared **into** lanlink, staged for THIS conversation and
    // still unsent. `draftFor` returns it only for its own conversation, so
    // switching devices can never offer to send someone else's staged files.
    final ShareDraft? shareDraft = widget.shareIntake?.draftFor(conversationId);
    return Column(
      children: <Widget>[
        _conversationHeader(context, peer),
        _tabBar(context),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: widget.controller.rightTab == RightTab.messages
              ? ConversationThread(
                  // A fresh key per conversation gives each thread a fresh State
                  // (the source-existence probe is per-conversation).
                  key: ValueKey<String>('messages-$conversationId'),
                  controller: conversation,
                  peer: peer,
                  sharedPaths: shareDraft?.paths ?? const <String>[],
                  onSharedSent: widget.shareIntake?.consumeDraft,
                  onSharedDiscarded: widget.shareIntake?.discardDraft,
                  onRetargetDraft: widget.onRetargetDraft,
                )
              : ConversationFiles(
                  key: ValueKey<String>('files-$conversationId'),
                  controller: conversation,
                ),
        ),
      ],
    );
  }

  /// Whether [conversation] has an **outgoing** transfer in flight right now.
  ///
  /// Used to stop the device marker from reading "离线" while bytes are still
  /// moving — the transfer's own state is the more truthful signal.
  bool _isTransferring(ConversationController conversation) {
    final List<ChatMessage>? messages = conversation.messages.valueOrNull;
    return messages != null &&
        messages.any((ChatMessage message) =>
            message.direction == MessageDirection.outgoing &&
            message.status == MessageStatus.transferring);
  }

  /// The device marker: an 8px dot plus a one-word status.
  ///
  /// Precedence: `online` wins outright. A live [transferring] conversation only
  /// overrides the **offline** verdict — because "离线" is the word the user read
  /// as a failure while his file was still uploading. When the peer already reads
  /// online there is nothing to correct, so no third state is added.
  Widget _statusLine(
    ThemeData theme, {
    required bool transferring,
    required bool online,
    required Color dot,
  }) {
    final Color color = (!online && transferring)
        ? statusColor(MessageStatus.transferring)
        : dot;
    final String label = online ? '在线' : (transferring ? '传输中' : '离线');
    return Row(
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// The conversation header: avatar + alias + online marker + 媒体与文件 + menu
  /// (PRD §1.4).
  ///
  /// **Phone (narrow, `showBack`) is deliberately thinner (M5 §B):** the top bar
  /// already shows the peer's name, so the avatar and a second copy of the name —
  /// the "设备卡" the user called a thick 额头 — are dropped, leaving one line:
  /// status marker + menu. Desktop (wide / compact) renders exactly as before.
  Widget _conversationHeader(BuildContext context, PeerDevice peer) {
    final ThemeData theme = Theme.of(context);
    final bool online = peer.isOnline;
    final Color onlineDot =
        online ? statusColor(MessageStatus.done) : theme.colorScheme.outline;
    final ConversationController? conversation = _conversation;

    if (widget.showBack) {
      // Phone (narrow): the bar above already carries ← / name / 媒体与文件 / ⋮
      // (docs/18 §2.4, and 0.2.27 for 媒体与文件), so this row is gone entirely —
      // hence no header widget at all. Neither affordance disappeared: both
      // moved up into the AppBar (`phone_shell.dart`), which is the only place
      // they can live once this row is removed. Wide / compact keep the full
      // header below (0.2.27 adds the 媒体与文件 entry there, in the same slot —
      // immediately left of the ⋮ — so the two platforms stay one product).
      return const SizedBox.shrink();
    }

    final String alias =
        peer.alias.isEmpty ? shortFingerprint(peer.fingerprint) : peer.alias;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: kDetailAvatarDiameter / 2,
            child: Icon(deviceKindIcon(peer.kind), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                _statusMarker(theme,
                    conversation: conversation, online: online, dot: onlineDot),
              ],
            ),
          ),
          // 0.2.27: the way into the three-filter media wall, in the same slot
          // the phone bar uses (immediately left of the ⋮). The name column
          // above is `Expanded`, so a long alias is ellipsised **before** either
          // button can be squeezed — the entry never pushes the name off.
          _deviceProfileEntry(context, peer),
          _menuButton(context),
        ],
      ),
    );
  }

  /// The 媒体与文件 entry — the desktop / compact door into [DeviceProfilePage]
  /// (0.2.27).
  ///
  /// The user's report: *"电脑端的会话里，能做成手机那样的文件分类吗，手机分了
  /// 图片视频文件来着，电脑这只有一个文件"*. The 图片 / 视频 / 文件 wall already
  /// existed (`DeviceProfilePage`), but the **only** door to it was the phone
  /// bar's (`phone_shell.dart`), so on a desktop the capability was unreachable
  /// and the `文件` tab looked like the end of the story. This is the same door,
  /// same icon ([Icons.tune]), same tooltip, same slot relative to the ⋮.
  ///
  /// **Visibility is exactly the ⋮'s**: this header is only built while a
  /// conversation is selected (`_conversationModule` returns the placeholder
  /// before that), so an unselected / blank right pane carries neither. And the
  /// narrow shell builds no header at all (`showBack` above), so a phone keeps
  /// its **one** 媒体与文件 — the change cannot produce two.
  Widget _deviceProfileEntry(BuildContext context, PeerDevice peer) {
    final String? conversationId = widget.controller.selectedConversationId;
    if (conversationId == null) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: '媒体与文件',
      icon: const Icon(Icons.tune),
      onPressed: () => unawaited(_openDeviceProfile(context, peer, conversationId)),
    );
  }

  /// Pushes the peer's profile over the shell — the same page, the same push the
  /// phone does (`phone_shell.dart`), so the three filters and their contents
  /// are **reused, not re-implemented**.
  ///
  /// [peer] is the one the header already resolved ([_peerFor]), so the page's
  /// title and the header can never disagree about who this is. [_peerFor] is a
  /// strict superset of the phone's rule — the merged card first (live name /
  /// `isOnline`), then the stored device row, then a minimal stand-in built off
  /// the conversation's own `deviceFingerprint` (`lastPort: 0`, so nothing that
  /// needs a dial is ever attempted).
  ///
  /// The route is a plain `MaterialPageRoute`, which is how the desktop shell
  /// already navigates (it hosts a root `Navigator` under `MaterialApp`); the
  /// page's own `AppBar` therefore draws its ← automatically, plus
  /// `DeviceProfilePage` handles Esc — both ways back work.
  ///
  /// **0.2.59: the route is typed `<String>` and awaited.** The page's card menu
  /// 「转到消息」 closes it with the owning message's id, and that id has to reach
  /// the conversation — `requestReveal` is the only way to ask the timeline to
  /// scroll somewhere, and the controller (not the timeline's `State`) is what
  /// survives a 消息 / 文件 tab switch. This is the wide / compact twin of
  /// `phone_shell.dart::_openDeviceProfile`, same two lines; no `context` is
  /// touched after the `await`.
  Future<void> _openDeviceProfile(
    BuildContext context,
    PeerDevice peer,
    String conversationId,
  ) async {
    final String? target = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) => DeviceProfilePage(
          peer: peer,
          conversationId: conversationId,
        ),
      ),
    );
    // `null` ⇒ ← / Esc / system back: nothing was chosen, nothing is requested.
    if (target != null) {
      widget.controller.conversationController?.requestReveal(target);
    }
  }

  /// The online / offline / "传输中" marker.
  ///
  /// ★ Honesty (#3): rebuilt from the conversation's own state so an in-flight
  /// transfer wins over a stale "offline" — the user's report was "it showed
  /// 离线 but it was still sending", and he read the badge as a failure. Scoped
  /// to this small subtree (the thread has its own subscription), so a status
  /// change never rebuilds the whole pane.
  Widget _statusMarker(
    ThemeData theme, {
    required ConversationController? conversation,
    required bool online,
    required Color dot,
  }) {
    if (conversation == null) {
      return _statusLine(theme, transferring: false, online: online, dot: dot);
    }
    return AnimatedBuilder(
      animation: conversation,
      builder: (BuildContext context, Widget? _) => _statusLine(
        theme,
        transferring: _isTransferring(conversation),
        online: online,
        dot: dot,
      ),
    );
  }

  /// The conversation overflow menu (查看指纹 / 归档会话).
  Widget _menuButton(BuildContext context) =>
      PopupMenuButton<_ConversationMenu>(
        tooltip: '更多',
        onSelected: (_ConversationMenu item) => _onMenu(context, item),
        itemBuilder: (BuildContext context) =>
            const <PopupMenuEntry<_ConversationMenu>>[
          PopupMenuItem<_ConversationMenu>(
            value: _ConversationMenu.viewFingerprint,
            child: Text('查看指纹'),
          ),
          PopupMenuItem<_ConversationMenu>(
            value: _ConversationMenu.archive,
            child: Text('归档会话'),
          ),
          // 0.2.41 — 多选: the entry the phone asked for (its bubbles have no
          // right-click), and the same menu exists on the desktop's header.
          PopupMenuItem<_ConversationMenu>(
            value: _ConversationMenu.multiSelect,
            child: Text('多选'),
          ),
        ],
      );

  Future<void> _onMenu(BuildContext context, _ConversationMenu item) async {
    if (item == _ConversationMenu.multiSelect) {
      // The selection lives in the **per-conversation** controller (created in
      // [_ensureConversation] and keyed to the selected conversation), so entering
      // the mode is one call on it — no callback to thread through the thread
      // widget, and the state cannot outlive the conversation it belongs to
      // (0.2.41).
      _conversation?.startSelecting();
      return;
    }
    if (item == _ConversationMenu.viewFingerprint) {
      final String fingerprint =
          _peerFor(context, widget.controller.selectedConversationId ?? '')
              .fingerprint;
      showTransientNotice(
        context,
        fingerprint.isEmpty ? '（未知指纹）' : fingerprint,
        bottomInset: kComposerNoticeInset,
      );
      return;
    }
    // item == _ConversationMenu.archive (Q8: hidden from the home list).
    final String? id = widget.controller.selectedConversationId;
    if (id != null) {
      context.deps.repo.archiveConversation(id);
      // Return the right pane to the placeholder; the row un-highlights.
      widget.controller.clearSelection();
    }
  }

  /// The `消息 / 文件` tab bar (design §1.4).
  Widget _tabBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: <Widget>[
          for (final RightTab tab in RightTab.values) ...<Widget>[
            ChoiceChip(
              label: Text(tab.label),
              selected: widget.controller.rightTab == tab,
              onSelected: (bool selected) => widget.controller.setRightTab(tab),
              // docs/19 §8-①: the reference's tabs carry **no checkmark** and
              // **no outline** — selection reads from the fill alone. Both used to
              // come from `ChoiceChip`'s **defaults** (`showCheckmark: true` plus
              // the outlined shape), which is why searching for `Icons.check` /
              // `Icons.done` found nothing: the tick is drawn by the chip itself,
              // not by an icon we pass in.
              showCheckmark: false,
              side: BorderSide.none,
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// The peer for the conversation header — the merged card (with live
  /// `isOnline` / `lastPort`) when present, else the stored device row, else a
  /// minimal stand-in that cannot receive.
  PeerDevice _peerFor(BuildContext context, String conversationId) {
    final PeerDevice? found =
        _peerByFingerprint(widget.controller.selectedFingerprint);
    if (found != null) {
      return found;
    }
    for (final Conversation conversation
        in context.deps.repo.conversations(includeArchived: true)) {
      if (conversation.id != conversationId) {
        continue;
      }
      final String fingerprint = conversation.deviceFingerprint ?? '';
      return PeerDevice(
        fingerprint: fingerprint,
        alias: fingerprint.isEmpty ? '本机会话' : shortFingerprint(fingerprint),
        kind: DeviceKind.unknown,
        lastPort: 0, // unknown peer → sending is honestly disabled
        conversationId: conversationId,
      );
    }
    return const PeerDevice(
      fingerprint: '',
      alias: '本机会话',
      kind: DeviceKind.unknown,
      lastPort: 0,
      conversationId: null,
    );
  }

  PeerDevice? _peerByFingerprint(String? fingerprint) {
    if (fingerprint == null) {
      return null;
    }
    final List<PeerDevice> cards =
        widget.home.cards.valueOrNull ?? const <PeerDevice>[];
    for (final PeerDevice device in cards) {
      if (device.fingerprint == fingerprint) {
        return device;
      }
    }
    return context.deps.repo.device(fingerprint);
  }

  // ── recent-files module ──────────────────────────────────────────────────

  Widget _fileModule(BuildContext context) {
    final RecentFileItem? item = _selectedRecentFile();
    if (item == null) {
      return const EmptyState(
        title: '选一个文件查看详情',
        message: '在左侧列表中点击任一文件',
        icon: Icons.insert_drive_file_outlined,
      );
    }
    final String? path = item.file.localPath;
    final PlatformPorts platform = context.deps.platform;
    return FileDetail(
      fileName: item.file.fileName,
      size: item.file.size,
      mime: item.file.mime,
      path: path,
      direction: item.direction,
      at: item.messageCreatedAt,
      conversationLabel: _conversationLabel(item.deviceFingerprint),
      onOpenConversation: () =>
          _openOwningConversation(context, item.deviceFingerprint),
      // The open/reveal actions are gated by the *same* `sourceMissing` the
      // middle pane shows, so a gone file can never be opened here (F26).
      available: !item.sourceMissing,
      // Mobile offers 「打开 / 分享」, desktop keeps 「打开文件 / 打开所在位置」
      // — the same intent, a different landing per platform (M5 §E).
      isMobile: platform.isMobile,
      onOpen: path == null ? null : () => unawaited(platform.openFile(path)),
      onReveal:
          path == null ? null : () => unawaited(platform.revealInFolder(path)),
      onShare: path == null ? null : () => unawaited(_shareFile(context, path)),
    );
  }

  /// Shares [path] through the OS share sheet; a failure is surfaced (a
  /// `ScaffoldMessenger` snack bar), never swallowed (M5 §E).
  Future<void> _shareFile(BuildContext context, String path) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await context.deps.platform.shareFile(path);
    } on Object catch (error) {
      showTransientNoticeOn(messenger, '分享失败：$error',
          bottomInset: kComposerNoticeInset);
    }
  }

  /// The row the middle pane selected — read from the **same**
  /// [RecentFilesController] the middle pane renders, matched by file id (and by
  /// message id when the shell carries one). No second data source, so the two
  /// panes agree on the file *and* on its `sourceMissing`.
  ///
  /// Matched against the **unfiltered** `all` list, never the tab/query-filtered
  /// [RecentFilesController.visible]: `selectedFileId` is an *identity*, and an
  /// identity must not depend on the current *view* — otherwise switching the
  /// middle pane's tab (or typing a non-matching query) would drop the file out
  /// of the filtered list and collapse the detail into an empty state.
  RecentFileItem? _selectedRecentFile() {
    final String? fileId = widget.controller.selectedFileId;
    if (fileId == null) {
      return null;
    }
    final String? messageId = widget.controller.selectedFileMessageId;
    for (final RecentFileItem item
        in widget.recentFiles.all.valueOrNull ?? const <RecentFileItem>[]) {
      if (item.file.id != fileId) {
        continue;
      }
      if (messageId != null && item.messageId != messageId) {
        continue;
      }
      return item;
    }
    return null;
  }

  String _conversationLabel(String? fingerprint) {
    if (fingerprint == null) {
      return '本机会话';
    }
    final PeerDevice? peer = _peerByFingerprint(fingerprint);
    final String alias = peer?.alias ?? '';
    return alias.isNotEmpty ? alias : shortFingerprint(fingerprint);
  }

  /// "所属会话" is tappable: switch to the conversations module and select that
  /// peer, so the middle highlight and the right pane move together.
  void _openOwningConversation(BuildContext context, String? fingerprint) {
    widget.controller.selectModule(ShellModule.conversations);
    final PeerDevice? peer = _peerByFingerprint(fingerprint);
    if (peer != null) {
      widget.controller.selectPeer(peer);
    }
  }
}

/// The conversation header's overflow menu entries (PRD §1.4).
enum _ConversationMenu { viewFingerprint, archive, multiSelect }
