/// The three-pane shell's vocabulary: the module/tab enums, their rail labels
/// and icons, and the responsive breakpoints (design §2.3 / §6 / §9.3).
///
/// **Layering (design §9.6):** `ui/**` may import `package:flutter/*` and this
/// package's `domain/**`; it never imports `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store`.
library;

import 'package:flutter/material.dart';

/// The four left-rail modules, in navigation order (design §2.3).
enum ShellModule {
  /// The merged device / session list — the default module.
  conversations,

  /// The global recent-files list.
  recentFiles,

  /// The read-only archived-session list.
  archived,

  /// The three V1 settings.
  settings,
}

/// The two tabs of the right pane's "conversation" module (design §2.3).
enum RightTab { messages, files }

/// The width at or above which all three panes stay visible (design §6.1).
const double kWideBreakpoint = 1000;

/// The width below which the shell degrades to two levels (design §6.1).
const double kNarrowBreakpoint = 760;

/// The expanded rail width (design §6.1).
const double kRailWidth = 168;

/// The collapsed rail width — icons only (design §6.1).
const double kRailCollapsedWidth = 64;

/// The middle pane width on a wide window (design §6.1).
const double kListWidth = 320;

/// The middle pane width on a compact window (design §6.1).
const double kListWidthCompact = 280;

/// The minimum width of the right pane (design §6.1).
const double kDetailMinWidth = 360;

/// The responsive shape a window width resolves to (design §6.1).
enum ShellLayout {
  /// `>= kWideBreakpoint`: three panes always visible, full-width rail.
  wide,

  /// `[kNarrowBreakpoint, kWideBreakpoint)`: three panes, collapsed rail.
  compact,

  /// `< kNarrowBreakpoint`: two levels (list ⇄ detail), collapsed rail.
  narrow,
}

/// Resolves a window [width] to its [ShellLayout] (design §6.1).
ShellLayout layoutForWidth(double width) {
  if (width >= kWideBreakpoint) {
    return ShellLayout.wide;
  }
  if (width >= kNarrowBreakpoint) {
    return ShellLayout.compact;
  }
  return ShellLayout.narrow;
}

/// Presentation for a [ShellModule]: its rail label and icon.
extension ShellModuleUi on ShellModule {
  /// The Chinese rail label.
  String get label => switch (this) {
        ShellModule.conversations => '会话',
        ShellModule.recentFiles => '最近文件',
        ShellModule.archived => '已归档',
        ShellModule.settings => '设置',
      };

  /// The rail icon (the selected state is expressed with colour + fill).
  IconData get icon => switch (this) {
        ShellModule.conversations => Icons.forum,
        ShellModule.recentFiles => Icons.history,
        ShellModule.archived => Icons.archive,
        ShellModule.settings => Icons.settings,
      };
}

/// Presentation for a [RightTab].
extension RightTabUi on RightTab {
  /// The tab label.
  String get label => switch (this) {
        RightTab.messages => '消息',
        RightTab.files => '文件',
      };
}
