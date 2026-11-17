/// The narrow-window bottom-navigation vocabulary (M5 spec §3.2).
///
/// Three tabs — 设备 / 文件 / 设置 — express the four wide-rail `ShellModule`s
/// as **three** bottom destinations: [ShellModule.archived] folds into the 文件
/// tab as a secondary segment (the Q8 ruling), so `phoneTabOf(archived) ==
/// PhoneTab.files`. The label and icon of a tab are **derived** from the module
/// it maps to, so there is a single icon source and the rail and the bottom bar
/// can never disagree.
///
/// **Layering (design §9.6):** `ui/**` may import `package:flutter/*` and this
/// package's `domain/**`; it never imports `dart:io` / `dart:ffi` /
/// `lanlink_core` / `lanlink_store`.
library;

import 'package:flutter/material.dart';

import 'shell_module.dart';

/// The three bottom-navigation tabs, left to right (PRD §3.1).
enum PhoneTab {
  /// Device / conversation list — the default tab.
  devices,

  /// Recent files, with 已归档 as a secondary segment.
  files,

  /// The three V1 settings.
  settings,
}

/// Presentation for a [PhoneTab]: its label, its icon and the module it opens.
extension PhoneTabUi on PhoneTab {
  /// The Chinese bottom-bar label (PRD §3.1).
  String get label => switch (this) {
        PhoneTab.devices => '设备',
        PhoneTab.files => '文件',
        PhoneTab.settings => '设置',
      };

  /// The icon — a **single icon source**: reused from the mapped
  /// [ShellModule.icon], so the parallel rail and bottom bar stay identical.
  IconData get icon => switch (this) {
        PhoneTab.devices => ShellModule.conversations.icon, // Icons.forum
        PhoneTab.files => ShellModule.recentFiles.icon, // Icons.history
        PhoneTab.settings => ShellModule.settings.icon, // Icons.settings
      };

  /// The **primary** module a tap on this tab selects (the 文件 tab's secondary
  /// segment — 已归档 — is chosen separately, never by a bottom-bar tap).
  ShellModule get module => switch (this) {
        PhoneTab.devices => ShellModule.conversations,
        PhoneTab.files => ShellModule.recentFiles,
        PhoneTab.settings => ShellModule.settings,
      };
}

/// The bottom-navigation tab a [ShellModule] belongs to.
///
/// **已归档 folds into 文件** (Q8 / constraint #6): the bottom bar has exactly
/// three slots, and the read-only archive is a low-frequency secondary segment
/// of the files page — never a fourth tab.
PhoneTab phoneTabOf(ShellModule module) => switch (module) {
      ShellModule.conversations => PhoneTab.devices,
      ShellModule.recentFiles => PhoneTab.files,
      ShellModule.archived => PhoneTab.files,
      ShellModule.settings => PhoneTab.settings,
    };
