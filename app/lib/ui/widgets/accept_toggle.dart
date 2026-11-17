/// The receive-mode switch (spec §2 `accept_toggle.dart`, PRD §4.1 status bar).
///
/// A pure view: it reflects [accepting] and reports the desired new value through
/// [onChanged]. The single source of truth is the controller, so the home status
/// bar and the settings page read the same value and stay in sync (A2-17).
///
/// Layering (M4 §8.1): `ui/**` imports only `package:flutter/**` and this
/// package's `domain/**`; never `lanlink_core` / `lanlink_store` / `dart:io`.
library;

import 'package:flutter/material.dart';

import '../format.dart';
import '../theme.dart';

/// A labelled switch that turns the receive mode on or off.
class AcceptToggle extends StatelessWidget {
  /// Creates a receive-mode toggle.
  ///
  /// [enabled] = `false` renders the switch disabled (e.g. while a change is in
  /// flight); [onChanged] is still the only output channel.
  const AcceptToggle({
    super.key,
    required this.accepting,
    required this.onChanged,
    this.enabled = true,
  });

  /// Whether the receive mode is currently on.
  final bool accepting;

  /// Called with the requested new value when the switch is toggled.
  final ValueChanged<bool> onChanged;

  /// Whether the switch responds to input.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SwitchListTile(
      value: accepting,
      onChanged: enabled ? onChanged : null,
      isThreeLine: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      secondary: Icon(
        accepting ? Icons.download_done : Icons.download_outlined,
        color: accepting ? kSeedColor : theme.colorScheme.onSurfaceVariant,
      ),
      title: const Text('接收模式'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            accepting ? '已开启：自动接收对方发来的文件' : '已关闭：需先开启才能接收文件',
          ),
          const SizedBox(height: 4),
          // P0-7 follow-up: also state that the choice is **remembered** and
          // that "off" means an incoming file is refused outright (the sender
          // sees "被拒绝") — the same copy the rail's toggle shows.
          Text(
            kReceiveModeNote,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
