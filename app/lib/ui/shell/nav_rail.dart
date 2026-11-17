/// The left navigation rail (design §1.2 / §2.4 / §6).
///
/// It reads [ShellController] (which module is active), [HomeController]
/// (this device's alias + short fingerprint and the discovery error) and
/// [SettingsController] (the receiver mode), and writes back through
/// `selectModule` / [SettingsController.setAccepting] — the **single**
/// receive-mode write entry (P0-7), so the rail toggle persists exactly like the
/// settings switch (the earlier rail path never persisted).
///
/// **Layering (design §9.6):** imports only `package:flutter/*`, this package's
/// `domain/**`, `controllers/**` and `ui/**` — never `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../controllers/settings_controller.dart';
import '../../domain/models.dart';
import '../../domain/peer_discovery.dart';
import '../format.dart';
import '../theme.dart';
import 'shell_controller.dart';
import 'shell_module.dart';

/// The far-left rail: device identity, the four module entries, the discovery
/// error dot and the always-visible receiver toggle.
class NavRail extends StatelessWidget {
  /// Creates the rail.
  ///
  /// [collapsed] shows icons only (design §6.1, used at compact and narrow
  /// widths); labels become tooltips.
  const NavRail({
    super.key,
    required this.controller,
    required this.home,
    required this.settings,
    this.collapsed = false,
  });

  /// The shared shell state (current module).
  final ShellController controller;

  /// The app-level home state (identity, error).
  final HomeController home;

  /// The app-level settings state — the **only** writer of the receiver mode.
  final SettingsController settings;

  /// Whether to draw the icons-only (64px) variant.
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[controller, home, settings]),
      builder: (BuildContext context, Widget? child) {
        final ThemeData theme = Theme.of(context);
        final DiscoveryStatus status = home.discoveryStatus;
        final String alias = (status.selfAlias ?? '').trim();
        return Container(
          width: collapsed ? kRailCollapsedWidth : kRailWidth,
          color: surfaceRail(theme),
          child: Material(
            // A transparent Material so the rail items' ink / hover highlight
            // shows *above* the rail's opaque surface colour (PRD §2.5);
            // without it the ink would be painted on the Scaffold's Material,
            // hidden behind this Container.
            type: MaterialType.transparency,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _identity(context, theme, alias, status.selfFingerprint),
                  // Sections are divided by **air, not a rule** — Feishu almost
                  // never uses lines (comparison-table row 3). The little 8px
                  // spacer that used to sit *under* the hairline is folded into
                  // this gap: its reason (padding below a rule) is gone with it.
                  const SizedBox(height: kSectionGap),
                  for (final ShellModule module in ShellModule.values)
                    _navItem(context, module),
                  const Spacer(),
                  if (home.error != null || home.warning != null)
                    _errorIndicator(context, theme),
                  // Sections are divided by **air, not a rule** — Feishu almost
                  // never uses lines (comparison-table row 3).
                  const SizedBox(height: kSectionGap),
                  _receiveMode(context, theme),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// This device's avatar + alias + short fingerprint (PRD §4.1 / §3.1).
  ///
  /// Tapping it opens the settings module (where the name is edited).
  Widget _identity(
    BuildContext context,
    ThemeData theme,
    String alias,
    String? fingerprint,
  ) {
    const Widget avatar = CircleAvatar(
      radius: kDetailAvatarDiameter / 2,
      child: Icon(Icons.desktop_windows, size: 18),
    );
    final Widget body = collapsed
        ? Tooltip(
            message: alias.isEmpty ? 'lanlink' : alias,
            child: Center(child: avatar),
          )
        : Row(
            children: <Widget>[
              avatar,
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      alias.isEmpty ? 'lanlink' : alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (fingerprint != null)
                      Text(
                        shortFingerprint(fingerprint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
    return InkWell(
      onTap: () => controller.selectModule(ShellModule.settings),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: body,
      ),
    );
  }

  /// One module entry: highlight = brand fill + brand icon + bold label
  /// (PRD §1.2).
  Widget _navItem(BuildContext context, ShellModule module) {
    final ThemeData theme = Theme.of(context);
    final bool selected = controller.module == module;
    final Color foreground =
        selected ? kSeedColor : theme.colorScheme.onSurfaceVariant;

    final Widget row = AnimatedContainer(
      duration: kTransitionDuration,
      height: 44,
      // The selected entry is a **capsule**, not a full-width block: Feishu's
      // left rail highlights with an inset rounded chip (comparison-table row 1;
      // the radius and inset are ESTIMATES — see [kRadiusNavItem]).
      decoration: BoxDecoration(
        color: selected ? selectionFill(theme) : Colors.transparent,
        borderRadius: BorderRadius.circular(kRadiusNavItem),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          Icon(module.icon, color: foreground),
          if (!collapsed) ...<Widget>[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                module.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    final Widget tappable = InkWell(
      onTap: () => controller.selectModule(module),
      // The ink follows the capsule, so the hover / splash highlight can never
      // spill outside the rounded shape.
      borderRadius: BorderRadius.circular(kRadiusNavItem),
      // PRD §2.5: the four module entries respond visibly to hover.
      child: row,
    );
    // Inset from the rail's edges: the capsule does not run the full width
    // (comparison-table row 1). **Re-measured on the reference 2026-10-17**
    // (docs/19 §8-③): rail `x 0..269`, selected block `x 12..257` — i.e. the
    // reference insets it **~12 image px on each side**, so "full-width" was
    // wrong. 12 / 270 = 4.4% × our 168-wide rail ≈ 7.5 ≈ [kNavItemInset] ✓.
    final Widget item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: kNavItemInset),
      child: tappable,
    );
    return collapsed ? Tooltip(message: module.label, child: item) : item;
  }

  /// The always-visible receiver toggle at the rail's foot (PRD §1.2 / P0-7).
  ///
  /// The caption spells out the two things the toggle's semantics are not
  /// obvious about (P0-7 follow-up after a real-device walkthrough): the choice
  /// is **remembered** (next launch is still "on"), and while it is **off** an
  /// incoming transfer is refused outright — the sender then sees "被拒绝". It
  /// is an explanation, not a warning ([kReceiveModeNote]).
  ///
  /// While the settings are still loading ([SettingsController.ready] `false`)
  /// the toggle is **disabled and greyed** — never clickable-but-inert, which
  /// would be the UI lying about what a tap does.
  Widget _receiveMode(BuildContext context, ThemeData theme) {
    final bool accepting = settings.accepting;
    final bool enabled = settings.ready;
    final String label = accepting ? '接收已开启' : '接收已关闭';
    final Color color = !enabled
        ? theme.disabledColor
        : accepting
            ? statusColor(MessageStatus.done)
            : theme.colorScheme.onSurfaceVariant;

    final Widget icon = Icon(
      accepting ? Icons.wifi_tethering : Icons.wifi_tethering_off,
      color: color,
    );

    // docs/19 §9-C: **one line, not a paragraph.** The caption used to sit in the
    // rail permanently (up to three wrapped lines) and was the tallest thing in
    // the rail's foot; the same explanation is already on the settings page and
    // in this toggle's tooltip. So the visible part is now icon + state, and the
    // explanation is one hover away.
    final Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        icon,
        if (!collapsed) ...<Widget>[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ],
    );

    final Widget tappable = InkWell(
      onTap:
          enabled ? () => unawaited(settings.setAccepting(!accepting)) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: content,
      ),
    );
    // The caption cannot fit in the collapsed (64px) rail, so the full meaning
    // always also lives in a tooltip — including on the expanded toggle, so it
    // is reachable by hover there too.
    return Tooltip(
      message: enabled ? '$label\n$kReceiveModeNote' : '接收设置加载中…',
      child: tappable,
    );
  }

  /// The rail's discovery-error marker (PRD §6: the error must be visible from
  /// any module, not only the conversation list). Also covers a degraded
  /// receiving warning (e.g. the Android multicast lock) via [HomeController.warning].
  Widget _errorIndicator(BuildContext context, ThemeData theme) {
    final String message = home.error ?? home.warning ?? '';
    final Widget body = collapsed
        ? Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: statusColor(MessageStatus.failed),
              shape: BoxShape.circle,
            ),
          )
        : Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor(MessageStatus.failed),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '设备发现异常',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ],
          );
    return Tooltip(
      message: message.isEmpty ? '设备发现异常' : message,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: collapsed ? Center(child: body) : body,
      ),
    );
  }
}
