/// The single source of UI copy and derived display values (spec §2 / §8.4).
///
/// Widgets must not inline these strings or these small formatting rules:
/// status text, file size, dates/times and the file-type icon all come from
/// here, so there is exactly one place to change the app's wording. The
/// mime → category fallback reuses the pure table in `domain/selectors.dart`
/// (the single extension-classification source) — `ui/format.dart` never
/// re-declares that table, it imports it.
///
/// Layering (spec §8.1): `ui/**` may import `package:flutter/*` and this
/// package's `domain/**`; it never imports `lanlink_core` / `lanlink_store` /
/// `dart:io`.
library;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/peer_discovery.dart';
import '../domain/selectors.dart';

/// The seven status labels (spec §8.4) — the app's only status copy.
///
/// Exhaustive by construction: adding a [MessageStatus] is a compile error here
/// until it is given a label.
String statusText(MessageStatus status) => switch (status) {
      MessageStatus.pending => '排队中',
      MessageStatus.awaitingConfirm => '等待对方确认',
      MessageStatus.transferring => '传输中',
      MessageStatus.done => '已完成',
      MessageStatus.failed => '失败（可重新发送）',
      MessageStatus.canceled => '已取消',
      MessageStatus.rejected => '对方已拒绝',
    };

/// Human-readable size for [size] bytes.
///
/// An unknown size ([size] < 0, e.g. `-1` from the wire) renders as "未知大小"
/// — never as "0 B" or "-1 B" (spec §8.4). A genuine `0` renders as "0 B".
String fileSizeText(int size) {
  if (size < 0) {
    return '未知大小';
  }
  const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  if (size < 1024) {
    return '$size B';
  }
  double value = size.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final String digits = value.toStringAsFixed(value < 10 ? 1 : 0);
  return '$digits ${units[unit]}';
}

/// The remaining-time line for an in-flight transfer (0.2.25).
///
/// One copy rule for one question: "要不要等？". Three shapes, chosen by what a
/// human can use at that distance:
///
/// * `<= 1 秒` → `即将完成` — a countdown of "剩 1 秒" reads as stuck at the end;
/// * `< 60 秒` → `剩 45 秒` — second precision still helps;
/// * `< 60 分钟` → `剩 3 分 20 秒` — the seconds only where the minutes are few
///   enough to matter (both parts always shown, so the number visibly moves);
/// * else → `剩 1 小时 5 分` — minutes are noise past an hour.
///
/// The unit words are the same ones [fileSizeText] and the status labels use
/// (no `minutes` / `mins` mix), and the leading `剩` is what makes the line read
/// as a forecast rather than another byte count next to the percentage.
String remainingTimeText(Duration remaining) {
  if (remaining <= const Duration(seconds: 1)) {
    return '即将完成';
  }
  final int seconds = remaining.inSeconds;
  if (seconds < 60) {
    return '剩 $seconds 秒';
  }
  final int minutes = seconds ~/ 60;
  if (minutes < 60) {
    final int restSeconds = seconds % 60;
    return restSeconds == 0 ? '剩 $minutes 分' : '剩 $minutes 分 $restSeconds 秒';
  }
  final int hours = minutes ~/ 60;
  final int restMinutes = minutes % 60;
  return restMinutes == 0 ? '剩 $hours 小时' : '剩 $hours 小时 $restMinutes 分';
}

/// [instant] as the **local** calendar day (`yyyy-MM-dd`).
///
/// Delegates to `domain/selectors.dart::localDateKey`, so the recent-files group
/// headers and the UI share one date formatter (spec §8.3: storage is UTC, only
/// rendering converts to local time).
String dateText(DateTime instant) => localDateKey(instant);

/// [instant] as the **local** 24-hour clock time (`HH:mm`).
String timeText(DateTime instant) {
  final DateTime local = instant.toLocal();
  final String hour = local.hour.toString().padLeft(2, '0');
  final String minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// [instant] as `yyyy-MM-dd HH:mm` in **local** time.
String dateTimeText(DateTime instant) =>
    '${dateText(instant)} ${timeText(instant)}';

/// The type icon for a file, resolved from its mime when usable and otherwise
/// from its extension (spec §8.4 / E8).
///
/// Thumbnails are never generated (spec §8.4: `thumbnail_path` is always NULL),
/// so a file is always represented by one of these four icons.
IconData fileTypeIcon(String fileName, {String? mime}) {
  switch (categorizeFile(fileName, mime: mime)) {
    case FileCategory.image:
      return Icons.image;
    case FileCategory.video:
      return Icons.movie;
    case FileCategory.file:
      return Icons.description;
    case FileCategory.other:
      return Icons.insert_drive_file;
  }
}

/// The `[类型]` prefix for a list-row summary (PRD §2.3 / design §9.4).
///
/// Derived from the **same** `domain/selectors.dart::classifyFile` the icons and
/// the recent-files tabs use — there is no second classification table. Only
/// three labels exist (image / video / everything else), so a multi-file summary
/// (no usable mime, name `"N files"`) reads `[文件]`; that precision limit is
/// intentional and must not be "fixed" into a fake file name (PRD §3.4-②).
///
/// No enum value is added anywhere — this switches over the existing seven
/// [FileClass] values (design §11-R1).
String fileSummaryPrefix(String fileName, {String? mime}) =>
    switch (classifyFile(fileName, mime: mime)) {
      FileClass.image => '[图片]',
      FileClass.video => '[视频]',
      FileClass.audio => '[文件]',
      FileClass.installer => '[文件]',
      FileClass.archive => '[文件]',
      FileClass.document => '[文件]',
      FileClass.other => '[文件]',
    };

/// The date-separator label drawn between message groups (PRD §2.4).
///
/// `今天` / `昨天` for the two most recent local days, else `yyyy/MM/dd`
/// (local). The day comparison reuses `localDateKey`, so the separator and the
/// recent-files grouping agree on what "a day" is (spec §8.3: storage is UTC,
/// only rendering converts to local).
String dateSeparatorText(DateTime now, DateTime at) {
  final String atKey = localDateKey(at);
  if (atKey == localDateKey(now)) {
    return '今天';
  }
  if (atKey == localDateKey(now.subtract(const Duration(days: 1)))) {
    return '昨天';
  }
  return atKey.replaceAll('-', '/');
}

/// [at] as a compact middle-pane row timestamp (PRD §3.2 / design §1.3).
///
/// Today → `HH:mm`; yesterday → `昨天`; anything older → `M/D` (local). The day
/// comparison reuses [localDateKey], so the row, the recent-files grouping and
/// the message separators all agree on what "a day" is (spec §8.3: storage is
/// UTC, only rendering converts to local).
String rowTimeText(DateTime now, DateTime at) {
  final String atKey = localDateKey(at);
  if (atKey == localDateKey(now)) {
    return timeText(at);
  }
  if (atKey == localDateKey(now.subtract(const Duration(days: 1)))) {
    return '昨天';
  }
  final DateTime local = at.toLocal();
  return '${local.month}/${local.day}';
}

/// [at] as a **day** label for a file row's inline meta line: `10月23日`.
///
/// Only used where the surface has no `发送时间` column — a phone has no room for
/// one (`docs/22` §5.3), so the date rides on the size line instead. No year: a
/// folder in this app is a transfer from the last few days, and `10月23日` short
/// enough to sit beside `9.4 MB · 小甲` on a 360 dp row.
String dayText(DateTime at) {
  final DateTime local = at.toLocal();
  return '${local.month}月${local.day}日';
}

/// The direction word for a message row (design §9.4): `收到` / `发出`.
String directionText(MessageDirection direction) => switch (direction) {
      MessageDirection.incoming => '收到',
      MessageDirection.outgoing => '发出',
    };

/// The notice shown when this device refuses an inbound transfer (P0-7
/// follow-up).
///
/// A plain explanation, not an accusation: it names the sender when we know it
/// and otherwise calls it an unknown device, and it distinguishes the case the
/// user actually needs — "接收没开" (the switch) — from a size / session /
/// validation refusal.
String transferRejectedText(UploadRejected event) {
  final String? alias = event.peer?.alias.trim();
  final String who = (alias == null || alias.isEmpty) ? '有一台设备' : '「$alias」';
  return switch (event.reason) {
    InboundRejectReason.acceptingDisabled => '$who想发文件过来，但你的「接收」当前是关闭的，所以被拒绝了。'
        '打开左栏的接收开关后就能收到。',
    InboundRejectReason.tooLarge => '$who想发送的文件超过了大小上限，已被拒绝。',
    InboundRejectReason.sessionCapReached =>
      '$who想发送文件，但同时进行的接收已达上限，已被拒绝，稍后可重试。',
    InboundRejectReason.badRequest => '$who发来的发送请求不完整，已被拒绝。',
    InboundRejectReason.unauthorized => '$who发来的发送请求校验未通过，已被拒绝。',
  };
}

/// The receive-mode note shown beside the receiver toggle (P0-7 follow-up).
///
/// It spells out the two things the toggle's semantics are not obvious about,
/// after a real-device walkthrough where the user asked "can't it just stay on?":
///
/// 1. the choice is **remembered** — turning it on keeps it on at the next
///    launch, it is not a per-session switch; and
/// 2. while it is **off** an incoming transfer is refused outright, and the
///    sender **sees "被拒绝"** on their side.
///
/// Phrased as a plain explanation, not a warning (design/P0-7 wording ruling).
const String kReceiveModeNote =
    '开启后会一直生效，下次启动仍然是开启；关闭时，对方发来的文件会被直接拒绝，对方会看到「被拒绝」。';

/// [fingerprint] normalised to upper-case hex and cut to 8 characters.
///
/// The same normalisation `domain/selectors.dart` uses as the merge key, so the
/// shown prefix matches how the app compares fingerprints. Hoisted here from
/// `home_page._shortFingerprint` so the rail and the detail header share one
/// implementation (design §9.4 / K3).
String shortFingerprint(String fingerprint) {
  final String hex =
      fingerprint.replaceAll(RegExp('[^0-9a-fA-F]'), '').toUpperCase();
  final String source = hex.isEmpty ? fingerprint.toUpperCase() : hex;
  return source.length <= 8 ? source : source.substring(0, 8);
}

// ── 手动填写对端地址 (0.2.54) ────────────────────────────────────────────────
//
// Six strings for one feature: the entry point, its one-line reason for
// existing, and the four sentences a failed probe turns into. They live here —
// the app's single copy source (§8.4) — so the dialog, the settings block and
// the controller all say the same thing, and so a wording change is one edit.

/// The primary button on the empty device list.
const String kManualPeerActionLabel = '手动填写 IP 连接';

/// The one grey line under [kManualPeerActionLabel]: why the button exists.
///
/// Stated as the *situation* ("发现被网络挡住时"), not as a feature name: the user
/// who needs it has already concluded that discovery is broken, and a second
/// unexplained button would read as noise to the user who does not.
const String kManualPeerActionHint = '发现被网络挡住时，用这个直接连';

/// The dialog's title.
const String kManualPeerDialogTitle = '手动添加设备';

/// The settings block's heading (「手动添加的设备」).
const String kManualPeerListTitle = '手动添加的设备';

/// What the settings block says about a stored address, and how to drop it.
const String kManualPeerListHint = '这些地址会每隔一会儿自动重连一次；连不上的会一直等到它上线。';

/// The add row at the bottom of 「手动添加的设备」 (0.2.56).
///
/// **Why a second door exists.** Until 0.2.56 the only way to add an address was
/// the *empty* device list, and that state stops existing the first time any
/// conversation is created — a card outlives discovery (it is rebuilt from the
/// stored device row / the conversation). So on a machine that had ever
/// transferred anything, "再加一台设备，自动发现又没扫到" had no entry at all.
/// The list's ⋮ is the other door; this row is the one that also shows the count.
const String kManualPeerAddLabel = '添加设备地址';

/// The add row's right-hand side once [kMaxManualPeers] addresses are stored.
///
/// The row goes **disabled** rather than opening a dialog that can only refuse:
/// a button that always ends in an error sentence is the "tappable but inert"
/// shape this project ruled out (docs/18 §8.2). The number must match
/// `kMaxManualPeers`, the same way [kManualPeerAtCapacity] does.
const String kManualPeerFullLabel = '已满 8 个';

/// The capacity refusal — the ninth address (see `kMaxManualPeers`).
///
/// It must name the number **and** the way out: "最多 8 个" alone leaves the user
/// with a dead message on a screen that shows no count.
const String kManualPeerAtCapacity = '最多保存 8 个手动地址，先删一个再加。';

/// `badInput` — the string is not an address at all, nothing was dialled.
const String kManualPeerBadInput =
    '地址格式不对。填 `192.168.1.23` 或 `192.168.1.23:49494`。';

/// `unreachable` — nothing answered (refused, or no reply within the deadline).
const String kManualPeerUnreachable =
    '连不上。确认对方开着 lanlink、两台在同一 Wi-Fi，且没开『AP 隔离』。';

/// `certificateMismatch` — something answered, but its identity is not the
/// device the user thinks it is.
const String kManualPeerCertificateMismatch =
    '这个地址上的设备身份对不上。可能对方重装过，或这个 IP 分给了别的机器。';

/// `notLanlink` — TCP + TLS worked, but the peer does not speak lanlink.
const String kManualPeerNotLanlink = '这个地址上不是 lanlink。确认端口是 49494。';

/// The peer **did** answer, but the address could not be written down.
///
/// A separate sentence on purpose: "连不上" would be a lie (the device is in the
/// list and sendable right now), and silence would make the address vanish at the
/// next launch with no explanation.
const String kManualPeerNotRemembered = '连上了，但这个地址没能存下来（下次启动要重新填一次）。';

/// The address could not be removed from the settings document.
const String kManualPeerRemoveFailed = '没能删掉这条地址，请再试一次。';

// ── 「本机地址」 — the other half of 手动添加设备 (0.2.58) ────────────────────
//
// Why these exist at all. The dialog used to ask for the *peer's* address and
// say nothing about **this** device, and on a desktop there was nowhere at all
// to read our own `IP:port` — `about_page.dart` was the only place a port
// appeared, and it was a hard-coded 49494. So the one fact the other machine
// needs ("what do I type on that computer?") could only be learned by walking
// to the phone. The dialog now states it, and states it *only* when it is real.

/// The heading of the dialog's 本机地址 block.
///
/// The second half (「让对方填这一串」) is not decoration: the block answers "what
/// do I type over there", and saying so is what stops it being read as "your
/// address, for your information".
const String kManualPeerLocalAddressTitle = '本机地址 · 让对方填这一串';

/// Drawn instead of that block while the NIC has not been chosen yet.
///
/// It **names the action** ("先确认接收模式已开启"), because the address is only
/// published once the receiver is running. The alternative — printing a
/// plausible-looking `192.168.x.x` — is how a dialog sends the user to a device
/// that does not exist.
const String kManualPeerLocalAddressMissing = '本机地址未获取 · 先确认接收模式已开启';

/// The port row's label inside the block.
const String kManualPeerPortLabel = '端口';

/// The block's copy buttons' tooltip — and what a screen reader announces.
const String kManualPeerCopyLabel = '复制';

/// The port's stand-in when the address is known but the port is not.
///
/// `DiscoveryStatus.selfPort` is `int?`, and "address but no port" is a real
/// state (the socket is up, the status rebuild has not landed yet). The row stays
/// — its copy button goes disabled instead, so nothing is ever copied that is not
/// a port.
const String kManualPeerLocalPortMissing = '未获取';

// ── 本机信息 (0.2.58) ────────────────────────────────────────────────────────
//
// The settings row that opens `LocalInfoSheet`. The sheet has its own title as a
// literal (`local_info_sheet.dart`, deliberately untouched); this constant is
// what the row that opens it says, and the two must read the same — a test
// asserts it, rather than a comment hoping so.

/// The settings row's title, and the sheet's, in words.
const String kLocalInfoTitle = '本机信息';

/// `DiscoveryStatus.selfAddress`'s placeholder once the sheet/dialog needs a
/// string: "the NIC has not been chosen yet". Never an address.
const String kSelfAddressUnknown = '（未获取）';

/// `DiscoveryStatus.selfAlias`'s placeholder before the user names the device.
const String kSelfAliasUnknown = '（未命名）';

/// The one sentence a manual-probe failure turns into.
///
/// Exhaustive by construction: a new [ManualProbeFailure] is a compile error
/// here until it is given words, exactly like [statusText]. The four cases are
/// the four *different actions* a user can take (fix the typing / check the
/// network / check the identity / check the port), which is why this is not one
/// generic "连接失败".
String manualProbeFailureText(ManualProbeFailure reason) => switch (reason) {
      ManualProbeFailure.badInput => kManualPeerBadInput,
      ManualProbeFailure.unreachable => kManualPeerUnreachable,
      ManualProbeFailure.certificateMismatch => kManualPeerCertificateMismatch,
      ManualProbeFailure.notLanlink => kManualPeerNotLanlink,
    };

/// One stored address as the settings row shows it: `192.168.1.23:49494`.
///
/// The port is always drawn, even when it is the default: the row's job is to
/// tell the user exactly what will be dialled, and hiding the default would make
/// `:5000` (the one case where the port matters) indistinguishable at a glance.
String manualPeerText(ManualPeerTarget target) => '${target.host}:${target.port}';
