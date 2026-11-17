/// The one place that says **which language Flutter's own widgets speak**
/// (0.2.35).
///
/// Every string this app writes itself is Chinese, hard-coded at the call site.
/// The strings that are **not** ours — the text-selection toolbar
/// (「复制 / 全选」), a `TextField`'s long-press menu (「粘贴 / 剪切」), an `AppBar`
/// tooltip (「返回」), the date / time pickers, `showDialog`'s default
/// (「取消 / 确定」) — come from `MaterialLocalizations` / `WidgetsLocalizations`.
/// Until 0.2.35 this app declared **no** `localizationsDelegates` at all, so
/// Flutter fell back to `DefaultMaterialLocalizations`, which only ships
/// **English**: those menus rendered "Paste / Select all / Copy" in the middle of
/// an otherwise all-Chinese screen.
///
/// 0.2.31 patched the one symptom the user had actually reported by
/// hand-translating the three labels of the timeline's selection menu
/// (`conversation_thread.dart::_selectionContextMenu`). That fixed a *call site*;
/// the cause was the missing delegates. Declaring the three `Global*Localizations`
/// delegates fixes **every** framework-owned string at once, which is why that
/// hand-translation is gone as of 0.2.35.
///
/// **Scope, deliberately:** this file does *not* start an i18n project. There is
/// no ARB, no `AppLocalizations`, no `intl` message extraction — the app's own
/// copy stays written-in-Chinese at the call site. The only thing being declared
/// is the locale that the **framework** should use for its own strings.
///
/// **Why [kLanlinkLocale] is pinned rather than following the system:** with no
/// translation pipeline there is exactly one language in this app. Left to
/// follow the OS, an English-locale machine would get English *framework*
/// strings next to Chinese *app* strings — half-and-half, and the unreadable
/// half would be the framework's. Pinning `zh_CN` makes the whole screen one
/// language on every machine, which is the state the UI is designed for.
///
/// This file imports nothing from the project on purpose, so it can be used by
/// the app root ([LanlinkApp]), the startup-failure surface, **and** the widget
/// tests' mount helper without any risk of an import cycle.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// The only locale this app ships (see the library doc for why it is pinned).
const Locale kLanlinkLocale = Locale('zh', 'CN');

/// The locales `MaterialApp.supportedLocales` advertises.
///
/// A single entry: the app is Chinese-only, and listing more would let Flutter
/// resolve a different one from the platform.
const List<Locale> kLanlinkSupportedLocales = <Locale>[kLanlinkLocale];

/// The delegates that make framework-owned strings Chinese.
///
/// * `GlobalMaterialLocalizations` — `MaterialLocalizations`: selection toolbar,
///   `TextField` context menu, tooltips, `showDialog` / picker buttons, date and
///   time formatting.
/// * `GlobalWidgetsLocalizations` — `WidgetsLocalizations`: text direction
///   (needed because `WidgetsApp` requires a delegate for it, and the
///   `DefaultWidgetsLocalizations` fallback is what pins `en_US`).
/// * `GlobalCupertinoLocalizations` — `CupertinoLocalizations`: the iOS-shaped
///   affordances (`CupertinoAlertDialog`, `CupertinoDatePicker`). Nothing in this
///   app builds them directly, but adaptive widgets and text-selection toolbars
///   on iOS do, and a missing delegate there throws at build time rather than
///   rendering English — so it is declared up front.
///
/// The list is typed `<LocalizationsDelegate<dynamic>>` to match
/// `MaterialApp.localizationsDelegates`' own declared type: the three delegates
/// have three *different* type arguments, so no narrower element type fits all
/// of them.
const List<LocalizationsDelegate<dynamic>> kLanlinkLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];
