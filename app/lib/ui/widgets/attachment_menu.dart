import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/downloads_folder.dart' show isInLanlinkDownloadsFolder;
import '../../domain/models.dart';
import '../../domain/platform_ports.dart';
import '../../domain/selectors.dart' show fileExtension;
import '../format.dart';
import '../scope.dart';
import '../notices.dart';
import 'fast_menu.dart';

/// The context menu for one attachment card.
///
/// **Every entry is backed by a capability that already exists** on
/// `PlatformPorts` — `openFile` / `revealInFolder` / `shareFile` / `exists` /
/// `viewInDownloads` plus the text clipboard. Nothing here is a stub: an entry
/// that could not work is either **greyed out** or **not built at all**
/// (docs/19 §9.6).
///
/// Opened from a right-click on the desktop and a long-press on a phone, so the
/// platform split is decided **here**, not by each caller.
///
/// [onDelete] adds the trailing 「删除」 row (0.2.36) and is invoked when it is
/// chosen; `null` means the row is **not built at all**, which is the case for a
/// message that is still in flight (`ConversationController.canDelete`). The
/// callback performs the deletion *and* its own confirmation — this file only
/// reports the tap, exactly like [onOpenFile] / `revealInFolder` report theirs.
///
/// [onForward] adds 「转发到…」 (0.2.46) — the entry the user asked for
/// (*"右键一条消息就能转发"*), on the surface that right-clicks a **file**. Like
/// [onDelete] it is the caller's business: this file does not know which message
/// a card belongs to, and the forwarding itself is
/// `ConversationController.forwardMessagesTo`. `null` ⇒ the row is not built,
/// which keeps the folder-browse page's file menu exactly as it was (that page
/// has an attachment but no message, so there is nothing to forward).
Future<void> showAttachmentMenu(
  BuildContext context, {
  required FileAttachment file,
  required Offset position,
  VoidCallback? onDelete,
  VoidCallback? onForward,
}) async {
  final PlatformPorts platform = context.deps.platform;
  final bool mobile = platform.isMobile;
  final String? path = file.localPath;

  // One stat before the menu opens: a missing file must show up as a greyed-out
  // entry, never as a tap that silently does nothing.
  final bool exists = path != null && path.isNotEmpty &&
      await platform.exists(path);
  if (!context.mounted) {
    return;
  }

  // ── 「在下载里查看」 (0.2.24) ───────────────────────────────────────────────
  //
  // Built **only** when it can actually land somewhere, which takes two facts:
  //  * the platform offers the action at all (`supportsViewInDownloads` — Android
  //    only; the desktop already has 「打开所在位置」, Web has no shell);
  //  * the file really sits in `Download/lanlink`, the folder 0.2.19 publishes
  //    received files into.
  //
  // The second test is not a formality. Files received by an **older** build are
  // recorded with a private path (`/data/user/0/<pkg>/…/received/x.mp4`); the
  // folder action would open 下载/lanlink and the user would find nothing — the
  // exact "tappable row that cannot work" this menu is built to avoid. So those
  // rows are **not built** (nothing to grey out: the action does not exist for
  // that file), while 打开 / 分享 / 复制 stay untouched.
  // 0.2.29: the folder is whatever the user configured (`Download/素材`), so the
  // judgement takes it too. A file left in the **default** folder by an earlier
  // build does not qualify once the setting moved on — see `_run`'s note.
  final String subdirectory = platform.receivedSubdirectory;
  final bool canViewInDownloads = platform.supportsViewInDownloads &&
      path != null &&
      path.isNotEmpty &&
      isInLanlinkDownloadsFolder(path, subdirectory: subdirectory);

  // A mouse menu is not a touch menu. Material's `PopupMenuItem` defaults to 48
  // (the *finger* floor); five items at 48 read as a long, airy strip, which is
  // exactly what the user reported ("是不是有点太长了"). Windows / Office /
  // Feishu desktop menus are 28-36. So: **36 with a mouse, 48 with a finger** —
  // the ≥48 rule in this project is a *touch* rule and stays intact on the phone.
  // The type drops one step (16 -> 14, `bodyMedium`): 13 is not a step in our
  // scale, and inventing one would put the menu off the ramp.
  final double rowHeight = mobile ? kMinInteractiveDimension : 36;

  // `showFastMenu` (not `showMenu`): 150 ms on the Fluent curve, and it flips up
  // near the bottom edge. See `fast_menu.dart` for why the Material route's
  // fixed 300 ms + size transition reads as sluggish with a mouse.
  final String? choice = await showFastMenu(
    context,
    position: position,
    rowHeight: rowHeight,
    items: <FastMenuItem>[
      FastMenuItem(value: 'open', label: '打开', enabled: exists),
      if (!mobile)
        FastMenuItem(value: 'reveal', label: '打开所在位置', enabled: exists),
      // Sits exactly where the desktop keeps 「打开所在位置」 — it is the same
      // intent ("take me to where this file is"), the phone's landing.
      //
      // **Deliberately not gated on `exists`**: what opens is the *folder*, and
      // that is still the right place to look when the file itself has been
      // deleted (or renamed) — same reasoning as 复制文件路径 below. Only the
      // platform/path pair decides whether the row exists at all.
      if (canViewInDownloads)
        const FastMenuItem(value: 'viewInDownloads', label: '在下载里查看'),
      const FastMenuItem(
          value: 'copyName', label: '复制文件名', dividerBefore: true),
      // A path is worth copying even when the file is gone (to go looking for
      // it), so this stays enabled whenever we know a path at all.
      FastMenuItem(
          value: 'copyPath',
          label: '复制文件路径',
          enabled: path != null && path.isNotEmpty),
      if (mobile)
        FastMenuItem(value: 'share', label: '分享…', enabled: exists),
      const FastMenuItem(
          value: 'details', label: '详细信息…', dividerBefore: true),
      // 0.2.46 — 「转发到…」. A **message-level** action (it re-sends the whole
      // message, not this one card), which is why it sits below the divider with
      // 详细信息 / 删除 instead of up among the file actions.
      //
      // Greyed out when **this** card's file is gone, and that is not an
      // approximation: `_forwardOne` refuses the whole message as soon as **any**
      // of its sources is missing (sending the rest would deliver a batch the
      // sender never chose), so a missing file here is a guaranteed failure —
      // exactly the "drawn but inert" state the menu is allowed to show, and the
      // reason the row is not simply built-and-broken.
      if (onForward != null)
        FastMenuItem(value: 'forward', label: '转发到…', enabled: exists),
      // 0.2.36 — 「删除」 deletes the **message**, not the file: the row is here
      // because this menu is the only secondary tap a *file* bubble still owns
      // (a text bubble's right click belongs to the selection layer). Last, in
      // its own group, and never enabled-greyed: `onDelete == null` (a send still
      // in flight) means the row is not built.
      if (onDelete != null)
        const FastMenuItem(
            value: 'delete', label: '删除', dividerBefore: true),
    ],
  );
  if (choice == null || !context.mounted) {
    return;
  }
  await _run(
    context,
    choice,
    file: file,
    path: path,
    mobile: mobile,
    subdirectory: subdirectory,
    onDelete: onDelete,
    onForward: onForward,
  );
}

Future<void> _run(
  BuildContext context,
  String choice, {
  required FileAttachment file,
  required String? path,
  required bool mobile,
  required String subdirectory,
  required VoidCallback? onDelete,
  required VoidCallback? onForward,
}) async {
  final PlatformPorts platform = context.deps.platform;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    switch (choice) {
      case 'open':
        if (path != null) {
          await platform.openFile(path);
        }
      case 'reveal':
        if (path != null) {
          await platform.revealInFolder(path);
        }
      case 'viewInDownloads':
        if (path != null) {
          await _viewInDownloads(platform, messenger, path, subdirectory);
        }
      case 'share':
        if (path != null) {
          await platform.shareFile(path);
        }
      case 'copyName':
        await Clipboard.setData(ClipboardData(text: file.fileName));
        showTransientNoticeOn(messenger, '已复制文件名',
            bottomInset: kComposerNoticeInset);
      case 'copyPath':
        if (path != null) {
          await Clipboard.setData(ClipboardData(text: path));
          showTransientNoticeOn(messenger, '已复制文件路径',
              bottomInset: kComposerNoticeInset);
        }
      case 'details':
        if (context.mounted) {
          await showAttachmentDetails(context, file: file);
        }
      case 'forward':
        // Same division of labour as 删除: the caller owns the device list, the
        // serial fan-out and the per-device sentence (0.2.46). This file only
        // reports the tap — it does not even know which message it belongs to.
        onForward?.call();
      case 'delete':
        // The caller owns the deletion and the confirmation: it is the one that
        // holds the message (and therefore its id), and "已删除" must be the same
        // 2 s floating notice the rest of the app shows (0.2.36).
        onDelete?.call();
    }
  } on Object catch (error) {
    // Opening can fail for reasons we cannot see (no handler for the type, the
    // shell refused). Say so instead of appearing to do nothing.
    showTransientNoticeOn(messenger, '操作失败：$error',
        bottomInset: kComposerNoticeInset);
  }
}

/// The context menu for a **folder card** (0.2.46).
///
/// A folder message draws one card instead of N rows (0.2.38), so it never
/// reaches [showAttachmentMenu]: there is no single [FileAttachment] to 打开 or
/// 复制文件名, and offering those rows for one arbitrary member of a 200-file
/// folder would be a menu about nothing. Until 0.2.46 a folder card therefore
/// had **no** secondary tap at all — right-clicking it did nothing.
///
/// What it gets now is exactly the two **message-level** actions:
///
/// * 「转发到…」 — [onForward]. Not gated on a disk check: proving a folder's
///   every source is still there costs one `exists` per file, and paying a
///   200-stat pre-flight to *draw a menu* is the wrong trade. A gone source is
///   already answered out loud by the forward itself (源文件已不在本地，无法转发,
///   and nothing is sent — no empty message);
/// * 「删除」 — [onDelete], built only when the caller says the message may be
///   deleted, exactly like [showAttachmentMenu]'s row.
///
/// Both `null` ⇒ nothing is shown at all: an empty menu is not a menu.
Future<void> showFolderMessageMenu(
  BuildContext context, {
  required Offset position,
  VoidCallback? onForward,
  VoidCallback? onDelete,
}) async {
  if (onForward == null && onDelete == null) {
    return;
  }
  final bool mobile = context.deps.platform.isMobile;
  // Same row heights as the attachment menu: 36 under a mouse, 48 under a
  // finger (the ≥48 rule is a *touch* rule — see [showAttachmentMenu]).
  final String? choice = await showFastMenu(
    context,
    position: position,
    rowHeight: mobile ? kMinInteractiveDimension : 36,
    items: <FastMenuItem>[
      if (onForward != null)
        const FastMenuItem(value: 'forward', label: '转发到…'),
      if (onDelete != null)
        const FastMenuItem(
            value: 'delete', label: '删除', dividerBefore: true),
    ],
  );
  if (choice == null || !context.mounted) {
    return;
  }
  switch (choice) {
    case 'forward':
      onForward?.call();
    case 'delete':
      onDelete?.call();
  }
}

/// 「在下载里查看」: hand the folder to the platform, then **answer honestly**.
///
/// Three of the five outcomes are dead ends, and every one of them ends the same
/// way — the path really is put on the clipboard, then the user is told so:
///
/// * [ViewInDownloadsOutcome.noApp] — no app on this ROM can open a folder
///   (DocumentsUI stripped, an exotic launcher build);
/// * [ViewInDownloadsOutcome.noDirectory] — `Download/lanlink` does not exist
///   (nothing received on this phone since 0.2.19);
/// * [ViewInDownloadsOutcome.unsupported] / [ViewInDownloadsOutcome.failed] —
///   the same fallback, because the row is only built where the action is
///   supported, so reaching this means the bridge itself is broken.
///
/// **The copy comes first, then the message** — a toast that says "路径已复制"
/// before anything reached the clipboard is a lie the user can catch by pasting;
/// [Clipboard.setData] is awaited for that reason.
///
/// [ViewInDownloadsOutcome.opened] says nothing: a menu action that worked should
/// not pop a toast over the folder the user just opened.
Future<void> _viewInDownloads(
  PlatformPorts platform,
  ScaffoldMessengerState messenger,
  String path,
  String subdirectory,
) async {
  final ViewInDownloadsOutcome outcome =
      await platform.viewInDownloads(path, subdirectory: subdirectory);
  switch (outcome) {
    case ViewInDownloadsOutcome.opened:
      return;
    case ViewInDownloadsOutcome.noApp:
    case ViewInDownloadsOutcome.noDirectory:
      await Clipboard.setData(ClipboardData(text: path));
      showTransientNoticeOn(
        messenger,
        '这个系统没有能打开文件夹的应用，路径已复制到剪贴板',
        bottomInset: kComposerNoticeInset,
      );
    case ViewInDownloadsOutcome.unsupported:
    case ViewInDownloadsOutcome.failed:
      await Clipboard.setData(ClipboardData(text: path));
      showTransientNoticeOn(
        messenger,
        '打开文件夹失败，路径已复制到剪贴板',
        bottomInset: kComposerNoticeInset,
      );
  }
}

/// A small read-only sheet: what this file is, without leaving the conversation.
///
/// Every field comes from data we already hold (`size`, `mime`, `localPath`) plus
/// one `exists()` probe — no new capability, and no "calculated" value that could
/// disagree with the card next to it.
Future<void> showAttachmentDetails(
  BuildContext context, {
  required FileAttachment file,
}) async {
  final PlatformPorts platform = context.deps.platform;
  final String? path = file.localPath;
  final bool exists = path != null && path.isNotEmpty &&
      await platform.exists(path);
  if (!context.mounted) {
    return;
  }
  final List<(String, String)> rows = <(String, String)>[
    ('文件名', file.fileName),
    ('类型', file.mime?.isNotEmpty == true
        ? file.mime!
        : (fileExtension(file.fileName).isEmpty
            ? '未知'
            : fileExtension(file.fileName).toUpperCase())),
    ('大小', fileSizeText(file.size)),
    ('状态', exists ? '文件在位' : '文件已不在原位置'),
    if (path != null && path.isNotEmpty) ('路径', path),
  ];

  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('详细信息'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final (String label, String value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 64,
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => unawaited(() async {
            final String text = rows.map((r) => '${r.$1}：${r.$2}').join('\n');
            await Clipboard.setData(ClipboardData(text: text));
          }()),
          child: const Text('复制全部'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
