/// 接收端的**路径预算**——全仓唯一一份（CR-2 ②）。
///
/// **为什么单独一个文件。** 判定必须和接收端跑的是同一份代码：接收端在
/// `core/lib/src/security/relative_path.dart` 里用 `normalizeRelativePath` 决定
/// 一条 `path` 收不收，超预算就是 `null`，而 `null` 会让 `peer_server.dart` 对
/// **整批** `prepare` 回 400。发送端原来对这套规则一无所知（它的上限只有"深度
/// 6"），于是一个长目录名能让 200 个文件在哈希全部算完之后整批失败。
///
/// **为什么不在 `domain/folder_send.dart` 里。** 那里是纯 Dart 层，不许 import
/// `package:lanlink_core`（M4 §1.3：整个 domain 层要能在 Web 上编译，而 core 会
/// 把 `dart:io` 拉进依赖图）。所以 domain 只声明形状
/// （`ReceiverPathCheck`），实现在这里——`data/real/**` 本来就只被
/// `bootstrap/create_deps_native.dart` 引用，Web 构建永远不会解析它。
///
/// **为什么不是"另外写一个 180"。** 两个包各自写一遍阈值，就是两端开始漂移的
/// 那一天：这里多了个字符、那里少了个判断，而症状是"发送按钮点了没反应"。
/// 所以字符预算直接读 `kMaxRelativePathChars`，其余规则（段数、清理后为空、
/// 绝对路径）**一次也不重写**，一律问 `normalizeRelativePath`。
library;

import 'package:lanlink_core/lanlink_core.dart'
    show kMaxRelativePathChars, normalizeRelativePath;

import '../../domain/folder_send.dart';

/// 一个位置（`FolderScanFile.relativePath`）接收端会不会要不了。
///
/// 三种答案都算"要不了"，因为接收端对三种都回同一个 400：
///
///  * **超过 [kMaxRelativePathChars]**：接收端本可以把文件名截短（rule 8），
///    但那意味着文件到了对方那里**改了名**。发送端在这里选择"不发并说明"——
///    用户至少知道少了哪一个，而不是对着一个改了名的文件找原文件。
///  * **超过 8 段**（`kMaxRelativePathSegments`）：接收端拒绝。扫描本身只走 6
///    层，所以这条今天是兜底；把 `kFolderSendMaxDepth` 调深的人会需要它。
///  * **某一段清理之后什么都不剩**（`a/.../b.bin`）：接收端拒绝 —— 悄悄丢掉
///    这一段会把发送端刻意分开的两个目录合并成一个。
///
/// `null`（位置未知 = 整批平铺发送）返回 `false`：没有位置就没有可疑的东西，
/// 而"未知"不是这个文件的错。
///
/// 段数上限没有单独判断：`normalizeRelativePath` 已经包了它，多写一次就是多一
/// 处会漂的规则。
bool receiverRejectsPath(String? relativePath) {
  if (relativePath == null || relativePath.isEmpty) {
    return false;
  }
  if (relativePath.length > kMaxRelativePathChars) {
    return true;
  }
  return normalizeRelativePath(relativePath) == null;
}

/// 对一批已成形的位置做同一件事，返回能发的、跳过的个数与跳过的字节数
/// （Android 用）。
///
/// 桌面走 `scanFolderForSending(rejectsPath: receiverRejectsPath)`，在扫描的
/// 同一遍里就筛掉（`totalBytes` 因此天然只算留下的那些）；Android 的清单是原生
/// 侧走完才回包的（`DocumentsContract`），只能在这里补同一刀 —— 所以它还得把
/// 跳过的字节数减掉，否则确认框上的「共 X MB」会把没发的东西算进去。
///
/// 两边用的是**同一个** [receiverRejectsPath]，所以"哪个平台跳过了什么"不会有
/// 两套答案。
///
/// [FolderScanFile.relativePath] 为 `null` 的项原样保留：那是"位置未知"的整批
/// 平铺，这时没有位置可判，文件必须照发（丢层级是退化，丢文件不是）。
({
  List<FolderScanFile> files,
  int skippedPathTooLong,
  int skippedBytes,
}) applyReceiverPathBudget(List<FolderScanFile> files) {
  final List<FolderScanFile> kept = <FolderScanFile>[];
  int skipped = 0;
  int skippedBytes = 0;
  for (final FolderScanFile file in files) {
    if (receiverRejectsPath(file.relativePath)) {
      skipped += 1;
      skippedBytes += file.size;
      continue;
    }
    kept.add(file);
  }
  return (
    files: List<FolderScanFile>.unmodifiable(kept),
    skippedPathTooLong: skipped,
    skippedBytes: skippedBytes,
  );
}
