/// 「打开」一个本地附件的**唯一**实现。
///
/// 2026-11-10（0.2.59 起）：在此之前同一件事有两份私有拷贝 ——
/// `conversation_files.dart` 的 `_open` 与 `conversation_thread.dart` 的
/// `_openAttachment`，逻辑逐字相同（都在 `await` 之前捕获 messenger，都先
/// `exists` 再 `openFile`，失败都出提示）。设备墙也要「点开」时就会出现第三份，
/// 于是抽成这里。
///
/// **行为（三处必须一致，改这里就是同时改三处）：**
///  * 没有路径 → 「这个附件没有可打开的位置」；
///  * 探到不在盘上 → 交给共用的 [SourceAvailability] 记一笔，让调用方重绘，
///    然后说「文件已不在原位置，无法打开」；
///  * 平台拒绝打开 → 「打开失败：…」，而不是看着像没反应。
///
/// **不自己判断"文件在不在"**：[SourceAvailability] 是那份判断的唯一定义处，
/// 这里只是它的一批写入方之一（时间线、文件页、设备墙、最近文件是同一条规则）。
library;

import 'package:flutter/material.dart';

import '../../domain/platform_ports.dart';
import '../../domain/source_availability.dart';
import '../notices.dart';
import '../scope.dart';

/// 用系统程序打开 [path]，或者把「为什么打不开」说出来。
///
/// [sources] 与 [onRepaint] 由调用方给：`markGone` 之后那一行/那一张卡片要
/// 立刻变成「不可用」，而重绘是各个 State 自己的事（本函数不持有 State）。
Future<void> openLocalPath(
  BuildContext context, {
  required String? path,
  required SourceAvailability sources,
  required VoidCallback onRepaint,
}) async {
  final PlatformPorts platform = context.deps.platform;
  // 在第一个 `await` 之前捕获：提示不能去够一个可能已经失效的 `BuildContext`
  //（`attachment_menu.dart` / `message_bubble.dart` 同一条规矩）。
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  if (path == null || path.isEmpty) {
    showTransientNoticeOn(
      messenger,
      '这个附件没有可打开的位置',
      bottomInset: kComposerNoticeInset,
    );
    return;
  }
  final bool onDisk = await platform.exists(path);
  if (!context.mounted) {
    return;
  }
  if (!onDisk) {
    sources.markGone(path);
    onRepaint();
    showTransientNoticeOn(
      messenger,
      '文件已不在原位置，无法打开',
      bottomInset: kComposerNoticeInset,
    );
    return;
  }
  try {
    await platform.openFile(path);
  } on Object catch (error) {
    showTransientNoticeOn(
      messenger,
      '打开失败：$error',
      bottomInset: kComposerNoticeInset,
    );
  }
}
