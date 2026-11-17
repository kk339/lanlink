/// The **CJK font fallback chain** — the single place this app says which
/// typeface Chinese is drawn with (0.2.36).
///
/// **The defect it answers:** *"中文显示的不是正常中文黑体……我都怀疑你是不是找的临近
/// 汉语文化国家用的汉字"*. He was reading 「处」-type glyphs and he was right:
/// nothing in this app ever named a font, so Flutter's Windows default
/// ([`Segoe UI`]) covered the Latin text and the CJK characters fell through to
/// **Skia's own fallback**, which on a ja-JP-capable Windows lands on a
/// **Japanese** face (Yu Gothic UI). Same code points, wrong regional glyph
/// shapes — 「直」「骨」「处」 all differ between the Chinese and Japanese forms.
///
/// **Why `fontFamilyFallback` and not `fontFamily`:** naming a family outright
/// would take the Latin text off the platform's own UI font (Segoe UI on
/// Windows, Roboto on Android) and change the look of every English string and
/// number in the app. A fallback list is only consulted for the code points the
/// primary family cannot draw, i.e. exactly the CJK run — the Latin text is
/// untouched and the Chinese gains a Chinese face.
///
/// **Why no bundled font file:** a CJK face is 10–20 MB. Every target platform
/// already ships one (see the list), so shipping a copy would grow the app by an
/// order of magnitude to fix a *selection* problem, not a *missing glyph*
/// problem. If a platform ever lacks all of these, the last entries degrade
/// gracefully to `sans-serif` and then to Skia's fallback — i.e. exactly
/// today's behaviour.
///
/// **Order matters**, and it is: the platform we ship first, then the others.
/// A name that does not exist on the running system is simply skipped by the
/// engine, so one list serves every platform.
library;

import 'package:flutter/material.dart';

/// CJK fallback families, most-preferred first.
///
/// * `Microsoft YaHei UI` / `Microsoft YaHei` — Windows. Both come from
///   `C:\Windows\Fonts\msyh.ttc` (verified on the reference machine); the `UI`
///   cut is the slightly tighter one Windows itself uses for UI text, and it is
///   a **separate family name** inside that file, so both have to be listed.
/// * `PingFang SC` — macOS / iOS.
/// * `Noto Sans CJK SC` / `Noto Sans SC` — Android and most Linux desktops
///   (`NotoSansSC-VF.ttf` is also installed on the Windows reference machine).
/// * `Source Han Sans SC` — the same typeface under its Adobe name.
/// * `sans-serif` — the generic request, so the engine picks its own default UI
///   sans rather than whatever it would otherwise choose for CJK.
const List<String> kCjkFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'Source Han Sans SC',
  'sans-serif',
];

/// Returns [base] with [kCjkFallback] attached to **every** style.
///
/// `TextStyle.fontFamilyFallback` is a per-style property — `ThemeData` has no
/// top-level `fontFamilyFallback` — so the theme's text themes have to be mapped
/// style by style, which is what [TextTheme.apply] does.
///
/// Applied to both `textTheme` and `primaryTextTheme`: the second one is what an
/// `AppBar` (and anything else on a coloured surface) draws its title with, and
/// a title in Japanese glyphs beside body text in Chinese glyphs would be the
/// same bug in half the window.
TextTheme withCjkFallback(TextTheme base) =>
    base.apply(fontFamilyFallback: kCjkFallback);
