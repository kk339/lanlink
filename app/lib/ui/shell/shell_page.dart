/// The three-pane shell host (design §1.1 / §2 / §6).
///
/// [ShellPage] is the single owner of the shell controllers: it creates the one
/// [ShellController] (the shared UI state) plus the three **app-level**
/// controllers (`HomeController` initialises startup, `RecentFilesController`
/// and `SettingsController` load once), and mounts `NavRail` / `ListPane` /
/// `DetailPane`. The per-conversation `ConversationController` is owned by
/// `DetailPane` and lives only as long as the selected conversation (design
/// §2.5).
///
/// **Layering (design §9.6):** imports only `package:flutter/*`, this package's
/// `domain/**`, `controllers/**` and `ui/**` — never `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../bootstrap/app_deps.dart';
import '../../controllers/home_controller.dart';
import '../../controllers/recent_files_controller.dart';
import '../../controllers/settings_controller.dart';
import '../../domain/models.dart';
import '../scope.dart';
import '../notices.dart';
import '../theme.dart';
import '../widgets/forward_target_picker.dart';
import 'detail_pane.dart';
import 'list_pane.dart';
import 'nav_rail.dart';
import 'phone_shell.dart';
import 'shell_controller.dart';
import 'shell_module.dart';
import 'share_intake.dart';

/// The three-pane shell: navigation rail | list | detail.
class ShellPage extends StatefulWidget {
  /// Creates the shell.
  ///
  /// [initialModule] / [initialPeer] / [initialFileId] / [initialFileMessageId]
  /// are **test / deep-link only** (production passes nothing) so each old
  /// widget test can mount one widget and assert against the new structure
  /// (design §8.1).
  const ShellPage({
    super.key,
    this.initialModule = ShellModule.conversations,
    this.initialPeer,
    this.initialFileId,
    this.initialFileMessageId,
  });

  /// The module shown on first build.
  final ShellModule initialModule;

  /// The device pre-selected on first build, if any.
  final PeerDevice? initialPeer;

  /// The recent file pre-selected on first build, if any.
  final String? initialFileId;

  /// The message the pre-selected recent file belongs to.
  final String? initialFileMessageId;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> with WidgetsBindingObserver {
  ShellController? _shell;
  HomeController? _home;
  RecentFilesController? _recentFiles;
  SettingsController? _settings;
  ShareIntake? _shareIntake;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shell != null) {
      return;
    }
    // Watch the app lifecycle once: a resume after sleep/background can leave
    // the multicast sockets and group memberships stale (see
    // `didChangeAppLifecycleState`).
    WidgetsBinding.instance.addObserver(this);
    final AppDeps deps = context.deps;

    _shell = ShellController(
      repo: deps.repo,
      initialModule: widget.initialModule,
      initialPeer: widget.initialPeer,
      initialFileId: widget.initialFileId,
      initialFileMessageId: widget.initialFileMessageId,
    );
    final HomeController home = HomeController(
      repo: deps.repo,
      discovery: deps.discovery,
      transfer: deps.transfer,
      // 0.2.54 — the hand-typed-address list lives in the settings document, and
      // this controller is what adds to / removes from it when the device list
      // (not the settings page) starts the flow. The port is the document's only
      // owner, so it is the only thing that needs passing.
      platform: deps.platform,
    );
    final RecentFilesController recentFiles = RecentFilesController(
      repo: deps.repo,
      platform: deps.platform,
    );
    final SettingsController settings = SettingsController(
      platform: deps.platform,
      discovery: deps.discovery,
      transfer: deps.transfer,
    );
    _home = home;
    _recentFiles = recentFiles;
    _settings = settings;

    // Inbound shares (0.2.18): built with the shell so it can stage a shared
    // file and, since 0.2.62, **ask** which device it goes to before binding it
    // (see `_onShareIntakeChanged`). It only ever stages a draft — never sends
    // (`share_intake.dart`). A no-op on platforms without the capability.
    final ShareIntake shareIntake = ShareIntake(
      inbox: deps.shareInbox,
      shell: _shell!,
      onLog: debugPrint,
      // 0.2.23: 取消 on the 待发送 row frees the temporary copy behind it.
      pickedCache: deps.pickedCache,
    );
    _shareIntake = shareIntake;
    shareIntake.addListener(_onShareIntakeChanged);
    unawaited(shareIntake.start());

    // App-level controllers start once, here (design §2.5): `HomeController`
    // carries startup (zombie cleanup + receiver + discovery), so it must keep
    // running across module switches.
    home.init();
    recentFiles.load();
    settings.load();
  }

  /// Surfaces a share notice ("已收到 3 个文件，选择要发给谁") **once**, and asks
  /// 「发给谁」 whenever a share arrives with no destination (0.2.62).
  ///
  /// A `SnackBar` rather than a new page: the plan is explicit that this must be
  /// a one-line prompt, and the draft itself is drawn by the thread, which
  /// listens to the same [ShareIntake].
  ///
  /// **0.2.62** — the sheet comes first. Before this release a share quietly
  /// bound itself to whatever conversation was open; now the intake always
  /// leaves the draft unattached and raises [ShareIntake.takeTargetRequest],
  /// which is answered here by the same device sheet 「转发到…」 uses, in its
  /// single-target mode. Nothing jumps into a conversation until the user picks
  /// one.
  void _onShareIntakeChanged() {
    if (!mounted) {
      return;
    }
    final ShareIntake? intake = _shareIntake;
    if (intake == null) {
      return;
    }
    if (intake.takeTargetRequest()) {
      _askShareTargetSoon(intake);
    }
    final String? notice = intake.takeNotice();
    if (notice == null) {
      return;
    }
    // 0.2.36: `maybeOf` may be null (the shell can be mounted without a
    // messenger in tests), so the guard stays here and the helper takes the state.
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      showTransientNoticeOn(messenger, notice,
          bottomInset: kComposerNoticeInset);
    }
  }

  /// Shows the 「把 N 个文件发给谁」 sheet, unless we are inside a frame.
  ///
  /// The intake notifies from an async continuation, which in practice is
  /// already outside the frame — but "outside the frame" is a property of the
  /// scheduler, so it is read from the scheduler instead of assumed. Pushing a
  /// route from inside `build` / `layout` would throw.
  void _askShareTargetSoon(ShareIntake intake) {
    final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      unawaited(_askShareTarget(intake));
      return;
    }
    // A frame is in flight, so its post-frame callbacks will run.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) {
        unawaited(_askShareTarget(intake));
      }
    });
  }

  /// Asks who the staged files go to, then binds the draft to that device.
  ///
  /// ★ Never sends. The answer only decides *where the 待发送 row appears*; the
  /// user still has to press 发送 in that thread (`share_intake.dart`, rule 1).
  ///
  /// 取消 leaves everything as it is: the draft stays unattached and the notice
  /// still says 「选择要发给谁」, so tapping a device in the list is the (equally
  /// explicit) way to answer — `ShareIntake` binds it then.
  Future<void> _askShareTarget(ShareIntake intake) async {
    final ShareDraft? draft = intake.draft;
    final ShellController? shell = _shell;
    if (draft == null || draft.conversationId != null || shell == null) {
      return;
    }
    final PeerDevice? picked = await _pickOneTarget(
      title: '把 ${draft.count} 个文件发给谁',
      emptyMessage: kShareTargetPickerEmptyMessage,
    );
    if (!mounted || picked == null) {
      return;
    }
    // `selectPeer` is what shows the thread (it sets `detailVisible`), so the
    // draft appears where the user just pointed it — on a phone included.
    shell.selectPeer(picked);
    final String? conversationId = shell.selectedConversationId;
    if (conversationId != null) {
      // Explicit and idempotent: `selectPeer` above already notifies the intake,
      // which binds an unattached draft. Calling it here is what makes the
      // binding a stated contract of this method rather than a side effect of a
      // listener firing in the right order.
      intake.attachTo(conversationId);
    }
  }

  /// Asks which device the staged draft should go to instead, then moves it
  /// there (0.2.63 — the 待发送 row's 「改发到…」).
  ///
  /// ★ Still never sends. Moving a draft only changes which conversation the row
  /// appears in; the user presses 发送 there, exactly as before.
  ///
  /// 取消 (or a barrier dismissal) is a no-op **on purpose**: the draft keeps the
  /// device it already had, so "I opened the sheet and changed my mind" cannot
  /// lose the answer the user gave earlier. That is the opposite of
  /// [_askShareTarget]'s 取消, and correctly so — there the draft has no
  /// destination yet, here it has one.
  Future<void> _onRetargetDraft() async {
    final ShareIntake? intake = _shareIntake;
    final ShellController? shell = _shell;
    final ShareDraft? draft = intake?.draft;
    if (intake == null || shell == null || draft == null) {
      return;
    }
    final PeerDevice? picked = await _pickOneTarget(
      title: '把这 ${draft.count} 个文件改发给谁',
      emptyMessage: kShareTargetPickerEmptyMessage,
    );
    if (!mounted || picked == null) {
      return;
    }
    shell.selectPeer(picked);
    final String? conversationId = shell.selectedConversationId;
    if (conversationId != null) {
      intake.retarget(conversationId);
    }
  }

  /// The single-device chooser both doors above use.
  ///
  /// One function rather than two calls to [showForwardTargetPicker] so the two
  /// questions (「发给谁」 and 「改发给谁」) cannot drift apart in mode, filtering
  /// or dismissal semantics: single-select always, and "nothing chosen" always
  /// answers `null` (see the picker's rule 1 — a closed sheet is an empty list,
  /// never "everybody").
  Future<PeerDevice?> _pickOneTarget({
    required String title,
    required String emptyMessage,
  }) async {
    final List<PeerDevice> picked = await showForwardTargetPicker(
      context,
      singleSelect: true,
      title: title,
      emptyMessage: emptyMessage,
    );
    return picked.isEmpty ? null : picked.first;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareIntake?.removeListener(_onShareIntakeChanged);
    _shareIntake?.dispose();
    _shell?.dispose();
    _home?.dispose();
    _recentFiles?.dispose();
    _settings?.dispose();
    super.dispose();
  }

  /// On resume, **rebuild** discovery (fresh sockets) and re-announce.
  ///
  /// A phone that was asleep (or a laptop whose lid was closed) comes back with
  /// sockets and OS group memberships that may have gone stale — and neither
  /// failure raises a socket error, so nothing else would notice. Without this,
  /// the device keeps "announcing" into a dead membership and every peer times
  /// it out as offline (the "一会儿就离线" report).
  ///
  /// 0.2.40: this used to be a re-join on the **pre-sleep** sockets, which is
  /// the half that does not survive an Android screen lock (see
  /// `LanPeerDiscovery.rejoin` for the full account). The call itself is still
  /// fire-and-forget — the resume handler must not block the frame the user is
  /// about to see — but it is no longer **silent**: an escape used to become an
  /// unhandled async error, which is precisely how "解锁后还是离线" stayed
  /// invisible in the shipped build.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) {
      return;
    }
    unawaited(
      context.deps.discovery.rejoin().catchError((Object error) {
        debugPrint('lanlink: resume rebuild of discovery failed: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ShellController? shell = _shell;
    final HomeController? home = _home;
    final RecentFilesController? recentFiles = _recentFiles;
    final SettingsController? settings = _settings;
    if (shell == null ||
        home == null ||
        recentFiles == null ||
        settings == null) {
      return const Scaffold(body: SizedBox.shrink());
    }

    return Scaffold(
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final ShellLayout layout = layoutForWidth(constraints.maxWidth);
          return ListenableBuilder(
            listenable: shell,
            builder: (BuildContext context, Widget? child) {
              // A phone (<760) drops the collapsed rail for a bottom-nav shell
              // (M5 §3.1). Everything else keeps the one `Row(NavRail + panes)`
              // expression **unchanged** — the wide/compact path is untouched
              // (constraint #1), and `PhoneShell` (with its `PopScope`) is only
              // ever built here, on a narrow window (constraint #5).
              if (layout == ShellLayout.narrow) {
                return _phoneShell(shell, home, recentFiles, settings);
              }
              // docs/19 §8-②: the middle and right columns sit on **one** sheet
              // and are cut apart by a seam — not three tinted surfaces joined
              // by 1px rules.
              return ColoredBox(
                color: paneSurface(Theme.of(context)),
                child: Row(
                  children: <Widget>[
                    NavRail(
                      controller: shell,
                      home: home,
                      settings: settings,
                      collapsed: layout != ShellLayout.wide,
                    ),
                    _paneSeam(context),
                    ..._panes(
                        context, layout, shell, home, recentFiles, settings),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// The narrow (<760) phone shell (M5 §3.1 / S4).
  ///
  /// It reuses the host-built panes: the list drops its 48px header (the title
  /// moves to the top bar, S5) and the detail always draws the ← affordance
  /// (S3). The wide / compact `_panes` path above is left untouched.
  Widget _phoneShell(
    ShellController shell,
    HomeController home,
    RecentFilesController recentFiles,
    SettingsController settings,
  ) {
    return PhoneShell(
      shell: shell,
      home: home,
      recentFiles: recentFiles,
      settings: settings,
      listPane: ListPane(
        controller: shell,
        home: home,
        recentFiles: recentFiles,
        settings: settings,
        showHeader: false,
      ),
      detailPane: DetailPane(
        controller: shell,
        home: home,
        recentFiles: recentFiles,
        shareIntake: _shareIntake,
        onRetargetDraft: () => unawaited(_onRetargetDraft()),
        showBack: true,
      ),
    );
  }

  /// The list / detail panes for a **wide or compact** [layout] (design §6.1).
  ///
  /// Wide and compact show both panes (the rail is simply narrower at compact).
  /// A narrow window never reaches here — [build] routes it to [PhoneShell]
  /// (M5 §3.1). The settings and archived modules have no detail pane, so there
  /// the list spans the full width on every layout.
  /// The **seam** between two panes (docs/19 §8-②): a narrow band of its own
  /// colour, not a 1px rule. Measured on the reference: ~9 image px of
  /// `#EDF1FC` between two panes that share the *same* surface.
  Widget _paneSeam(BuildContext context) => Container(
        width: kPaneSeam,
        color: paneSeamColor(Theme.of(context)),
      );

  List<Widget> _panes(
    BuildContext context,
    ShellLayout layout,
    ShellController shell,
    HomeController home,
    RecentFilesController recentFiles,
    SettingsController settings,
  ) {
    final Widget listPane = ListPane(
      controller: shell,
      home: home,
      recentFiles: recentFiles,
      settings: settings,
    );

    // Settings and the read-only archived list have no right-pane content:
    // mounting a DetailPane for them would leave two thirds of the screen idle,
    // so the list fills the whole middle + right area instead (user feedback).
    // The conversations and recent-files modules keep all three panes — they
    // have real detail (messages / file preview).
    if (shell.module == ShellModule.settings ||
        shell.module == ShellModule.archived) {
      // A single full-width pane on *every* layout: wide/compact reclaim the
      // right column, and narrow is already one pane, so this merge never fights
      // the two-level degradation (design §6.1).
      return <Widget>[Expanded(child: listPane)];
    }

    final Widget detailPane = DetailPane(
      controller: shell,
      home: home,
      recentFiles: recentFiles,
      shareIntake: _shareIntake,
      onRetargetDraft: () => unawaited(_onRetargetDraft()),
      showBack: layout == ShellLayout.narrow,
    );

    switch (layout) {
      case ShellLayout.wide:
      case ShellLayout.compact:
        return <Widget>[
          SizedBox(
            width: layout == ShellLayout.wide ? kListWidth : kListWidthCompact,
            child: listPane,
          ),
          _paneSeam(context),
          Expanded(child: detailPane),
        ];
      case ShellLayout.narrow:
        return <Widget>[
          Expanded(child: shell.detailVisible ? detailPane : listPane),
        ];
    }
  }
}
