/// Short-lived, **floating** notices — one implementation for the whole app
/// (0.2.36).
///
/// **The defect it answers:** *"提示条挡输入框、太久"*. Every notice in the app was
/// a bare `showSnackBar(SnackBar(content: Text(...)))`, i.e. the Material
/// default: **fixed to the bottom edge for four seconds**, which is precisely
/// where the composer is in a conversation. Send something to an offline peer and
/// the answer to "what happened?" lands on top of the thing you type into.
///
/// Three properties, and each one is a decision:
/// * **floating** — a snackbar that is part of the layout's bottom edge cannot be
///   given a margin; the floating behaviour can, and the `margin` below is the
///   only way to keep it off the composer;
/// * **2 seconds** — a one-line confirmation (「已复制」/「已取消」) does not need
///   four; a notice that outstays its welcome is what made it feel like an
///   obstacle;
/// * **`clearSnackBars()` first** — notices used to *queue*. Click cancel twice
///   and the second answer waited behind the first, so the screen kept talking
///   after the user had moved on. The newest notice is the truth; older ones are
///   already stale.
library;

import 'package:flutter/material.dart';

/// How long a notice stays up.
const Duration kNoticeDuration = Duration(seconds: 2);

/// The bottom margin for a notice on a surface **without** a composer.
const double kNoticeBottomInset = 16;

/// The bottom margin a notice needs to stay **off the conversation composer**.
///
/// Measured, not guessed: at 1400×1000 the composer occupies the last **60 dp**
/// of the thread (8 dp padding + 44 dp of controls + 8 dp padding, read off
/// `find.byTooltip('发送')` and the `TextField` in
/// `test/widget/notice_margin_test.dart`), plus the 1 dp `Divider` that separates
/// it from the timeline. 60 + 1 + a 15 dp gap = **76**, so a floating notice's
/// bottom edge sits just above the divider and never on the box being typed in.
const double kComposerNoticeInset = 76;

/// Shows [message] as a short, floating notice (see the library doc).
///
/// [bottomInset] is the distance to leave under the notice: pass
/// [kComposerNoticeInset] on any surface where the conversation composer can be
/// on screen, and leave the default elsewhere.
void showTransientNotice(
  BuildContext context,
  String message, {
  double bottomInset = kNoticeBottomInset,
}) =>
    showTransientNoticeOn(
      ScaffoldMessenger.of(context),
      message,
      bottomInset: bottomInset,
    );

/// [showTransientNotice] for a caller that had to **capture** the messenger
/// before an `await` (a notice shown after a clipboard write or a network call
/// must not reach for a `BuildContext` that may already be unmounted — the rule
/// `attachment_menu.dart` and `message_bubble.dart` already follow).
void showTransientNoticeOn(
  ScaffoldMessengerState messenger,
  String message, {
  double bottomInset = kNoticeBottomInset,
}) {
  // No queue: the newest notice replaces whatever was still counting down.
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: kNoticeDuration,
      margin: EdgeInsets.fromLTRB(16, 0, 16, bottomInset),
    ),
  );
}
