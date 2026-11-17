/// 「发送整个文件夹」 的**纯策略层**（0.2.33）：一次发送里到底包含哪些文件、
/// 跳过多少、什么时候必须停下来告诉用户。
///
/// **为什么它不在 UI 里、也不在适配器里。** 三个决定必须有同一个答案：
///  * 递归多深、最多几个文件（上限是产品约束，不是平台细节）；
///  * 隐藏文件与 0 字节文件要不要发（答案都是「不发」，但要**计数**；
///    悄悄少发几个是这里最不能出现的结果）；
///  * 超限时是「截断到 200 个」还是「停下来问用户」——本项目一律选后者：
///    静默截断会让用户以为整批都到了。
///
/// 这个文件只依赖「列出某个目录」这一个注入进来的能力（[FolderLister]），
/// 所以桌面（`dart:io`）、Android（`DocumentsContract`，在原生侧完成）与测试
/// （内存里的假目录树）跑的是同一份判断，而不是三份彼此会漂的副本。
library;

/// 一次发送最多展开几层目录（含根目录的**下一层**算第 1 层）。
///
/// **0.2.38 起从 3 改成 6**（`docs/22` §6·T03 主理人裁定）。原来的 3 是照
/// 「一批素材」的通常深度（`素材/2026/婚礼`）定的，但一个真实交付目录更常见
/// 的形状是 `2026/10/素材/角色/立绘/x.png` —— 它已经有 5 层，第 3 层就被
/// 截断会让用户以为发全了，而这正是本文件最不能出现的结果。
///
/// 加深的代价被另外两个上限挡住了：文件数上限 [kFolderSendMaxFiles]（200）
/// 与计数上限 [kFolderSendCountCap]（2000）都**没有变**，所以「6 层」不会
/// 变成「扫得更久」—— 宽而浅的目录仍然在第 200 个文件处停下，
/// 深而空的目录最多多走三层。
const int kFolderSendMaxDepth = 6;

/// 一次发送最多包含多少个文件（**送得出去的上限**，不是扫描上限）。
///
/// 超过就整批不发并如实告知。200 与 `kLargePickedFileHintBytes` 那类常量不同：
/// 后者是提示，这个是硬门槛——200 个文件在接收端是 200 条消息、200 次落盘。
const int kFolderSendMaxFiles = 200;

/// 计数到多少个就停止（超限提示只需要"很多"，不需要"到底多少"）。
///
/// 用户的相册目录可能有几万个文件；为了报一句「有 12000 个文件」而遍历完整个
/// 树，会让选择目录这一步卡住十几秒——那是比"数字不精确"更糟的体验。
const int kFolderSendCountCap = 2000;

/// 判断「接收端会不会要不了这个位置」——**注入进来，不在这里实现**（CR-2 ②）。
///
/// 接收端对 `path` 有一套自己的规则（`core/lib/src/security/relative_path.dart`
/// 的 `normalizeRelativePath`：≤ 180 字符、≤ 8 段、每段清理后不能为空），并且
/// **一条不合格就整批 400**（`peer_server.dart` 的 `prepare`）。发送端原来对这套
/// 规则一无所知——它只有自己的「深度 6」——所以一个长目录名会让 200 个文件在
/// 哈希全部算完之后**整批失败**，而且说不清为什么。
///
/// 判定必须复用接收端真正跑的那一份 `normalizeRelativePath`，而 `lanlink_core`
/// 会把 `dart:io` 拉进依赖图，`domain/` 不许碰（M4 §1.3 分层规则：整个 domain
/// 层要能在 Web 上编译）。所以这里只声明**形状**，实现在
/// `data/real/receiver_path_budget.dart`（`receiverRejectsPath`），全仓一份。
///
/// `null` 参数（= 位置未知，整批平铺发送）必须返回 `false`：没有位置就没有
/// 可疑的东西，而"未知"不是文件本身的错。
typedef ReceiverPathCheck = bool Function(String? relativePath);

/// 「选择文件夹发送」的结果（0.2.33）。
/// 与 [PickDownloadsFolderOutcome] 分开：那是"改保存目录"（只允许 `Download`
/// 之下、并且要校验），这里是"发这个文件夹里的东西"——任何目录都合法，
/// 两者共用一个枚举就会把保存目录的校验一起松掉。
enum PickSendFolderOutcome {
  /// 拿到了可发送的文件列表（[SendFolderSelection.paths] 非空）。
  picked,

  /// 用户取消了选择。**不是错误**：什么都不做、也不提示。
  cancelled,

  /// 目录里没有可发送的文件（全是隐藏/空文件，或本来就是空的）。
  empty,

  /// 文件数超过 [kFolderSendMaxFiles]：**整批不发**。
  tooMany,

  /// 这个平台没有目录选择能力（Web）。
  unsupported,

  /// 选完了但出错（权限、provider 拒绝、枚举异常）。
  failed,
}

/// 一个**可发送**的文件：本地路径 + 它在文件夹里的位置（0.2.38）。
///
/// 0.2.33 的扫描结果只有 `List<String> paths`（绝对路径），层级信息在扫描那
/// 一步就丢了 —— 于是线上是一堆平铺文件，"文件夹"只是发送侧的措辞。这个类型
/// 是补上那一半：`relativePath` 让接收端能重建目录树（`docs/22` §1.1）。
class FolderScanFile {
  /// 创建一个可发送项。
  const FolderScanFile({
    required this.path,
    required this.relativePath,
    required this.size,
  });

  /// 可直接交给 `sendPaths` 的本地路径（Android 上是复制到 cache 后的路径）。
  final String path;

  /// 相对扫描根、`/` 分隔、**不含**根目录名、不含前导 `/`。
  ///
  /// `null` = 位置未知。桌面扫描总能给出；Android 只有在原生回包的
  /// `relativePaths` 与 `paths` 同序同长且每项都是非空字符串时才给得出，
  /// 否则整批为 `null`（错位比丢层级严重得多，见
  /// `android_folder_picker.parseSendFolderReply`）。
  ///
  /// **不含根目录名**：文件夹名在线上只出现一次（`folder.name`），
  /// 每个文件的 `path` 只描述"在这个文件夹里的哪儿"。
  final String? relativePath;

  /// 字节数。
  final int size;

  @override
  String toString() => 'FolderScanFile($relativePath, ${size}B)';
}

/// 「发送这个文件夹」的完整答案：发什么、多大、跳过了什么。
///
/// 一次给出全部，而不是让 UI 再问一轮平台——确认框要在**发送之前**把
/// 「N 个文件 / X MB / 跳过几个」同时讲清楚。
class SendFolderSelection {
  /// 创建一个答案。
  const SendFolderSelection({
    required this.outcome,
    this.files = const <FolderScanFile>[],
    this.totalBytes = 0,
    this.skippedHidden = 0,
    this.skippedEmpty = 0,
    this.skippedTooDeep = 0,
    this.skippedPathTooLong = 0,
    this.failedCopies = 0,
    this.availableCount = 0,
    this.countCapped = false,
    this.folderName,
    this.reason,
  });

  /// 一个"用户取消"的答案。
  const SendFolderSelection.cancelled({this.folderName})
      : outcome = PickSendFolderOutcome.cancelled,
        files = const <FolderScanFile>[],
        totalBytes = 0,
        skippedHidden = 0,
        skippedEmpty = 0,
        skippedTooDeep = 0,
        skippedPathTooLong = 0,
        failedCopies = 0,
        availableCount = 0,
        countCapped = false,
        reason = null;

  /// 发生了什么。
  final PickSendFolderOutcome outcome;

  /// 会真正发出去的文件，含各自在文件夹里的位置。
  final List<FolderScanFile> files;

  /// 可以直接交给 `sendPaths` 的本地文件路径（Android 上是复制到 cache 后的路径）。
  ///
  /// 派生自 [files]，不是第二个真相：0.2.33 的 `paths` 字段与层级信息分家，
  /// 才会出现"发了 3 个、路径里只有 2 个"这种只能靠肉眼发现的问题。
  List<String> get paths =>
      <String>[for (final FolderScanFile file in files) file.path];

  /// 与 [paths] **同序同长**的相对路径，或 `null`（= 平铺发送）。
  ///
  /// 全有或全无，不是"尽量给"：只要有一个文件的位置未知，整批就退回平铺。
  /// 半套相对路径会让接收端把文件放进它本来不属于的目录，而"少一层目录"
  /// 只是难看 —— 两害相权，这条是结构性的（`sendPaths` 还会再校验一次长度）。
  List<String>? get relativePaths {
    if (files.isEmpty) {
      return null;
    }
    final List<String> resolved = <String>[];
    for (final FolderScanFile file in files) {
      final String? value = file.relativePath;
      if (value == null || value.isEmpty) {
        return null;
      }
      resolved.add(value);
    }
    return resolved;
  }

  /// 这些文件的字节总数（用于「共 X MB」）。
  final int totalBytes;

  /// 因为名字以 `.` 开头被跳过的条目数（文件或目录，目录不展开）。
  final int skippedHidden;

  /// 因为大小是 0 被跳过的文件数。
  final int skippedEmpty;

  /// 因为超过 [kFolderSendMaxDepth] 而没有展开的目录数。
  final int skippedTooDeep;

  /// 因为**接收端放不下**而没有进批次的文件数（CR-2 ②）。
  ///
  /// 覆盖接收端会拒绝或必须改写的每一种位置（见 [ReceiverPathCheck]）：超过
  /// 字符预算、超过段数、某一段清理后为空。它们不进 [files]，因此不会被声明给
  /// 对端；**其余文件照常发送**——一个坏路径不再拖垮整批。
  ///
  /// 这是"少发了几个"的**唯一**记账处：没有它，用户点发送之后只会看到一句裸的
  /// 失败，或者更糟——以为整批都到了。
  final int skippedPathTooLong;

  /// Android 上复制失败、因此没进 [paths] 的文件数。
  final int failedCopies;

  /// 目录里**可发送文件**的总数（即使超过上限也照实给出，用于提示）。
  final int availableCount;

  /// [availableCount] 是否已到 [kFolderSendCountCap] 而停止计数。
  final bool countCapped;

  /// 用户选的目录名（`素材`），用于确认框标题。
  final String? folderName;

  /// 失败原因（outcome 是 [PickSendFolderOutcome.failed] 时）。
  final String? reason;

  /// 是否真的可以发送。
  bool get canSend =>
      outcome == PickSendFolderOutcome.picked && files.isNotEmpty;

  /// 有一批文件要发，但**它们的位置全丢了**（0.2.38）。
  ///
  /// 只在 Android 上可能出现：原生回包的 `relativePaths` 缺失、长度不对或含
  /// 非字符串时，整批按平铺发送（见 [relativePaths]）。这条不是错误——文件
  /// 照样发得出去——所以它是可查询的状态而不是失败，但必须有名字：否则
  /// "文件夹发过去变成散文件"这种退化只能靠用户发现。
  bool get lostHierarchy => files.isNotEmpty && relativePaths == null;

  /// 「N 个文件」里的 N：真正会发出去的个数。
  int get fileCount => files.length;

  @override
  String toString() => 'SendFolderSelection($outcome, files: ${files.length}, '
      'bytes: $totalBytes, hidden: $skippedHidden, empty: $skippedEmpty, '
      'tooDeep: $skippedTooDeep, failed: $failedCopies, '
      'pathTooLong: $skippedPathTooLong, '
      'available: $availableCount${countCapped ? '+' : ''})';
}

/// 目录里的一个条目（文件或子目录）。
///
/// 只有"名字 / 路径 / 是否目录 / 大小"四件事——扫描需要的全部，别的一律不读：
/// 读 mtime、读权限只会让桌面与 Android 的实现更难对齐。
class FolderEntry {
  /// 创建一个条目。
  const FolderEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
  });

  /// 文件（或目录）名，含扩展名，不含路径。
  final String name;

  /// 完整路径（Android 侧是复制后的本地路径 / 桌面是真实路径）。
  final String path;

  /// 是否是目录。
  final bool isDirectory;

  /// 字节数（目录为 0）。
  final int size;
}

/// 列出一个目录的直接子项。桌面是 `Directory.listSync`，测试是内存表。
typedef FolderLister = Future<List<FolderEntry>> Function(String path);

/// 一次扫描的结果（纯数据，不含平台概念）。
class FolderScan {
  /// 创建结果。
  const FolderScan({
    required this.files,
    required this.totalBytes,
    required this.skippedHidden,
    required this.skippedEmpty,
    required this.skippedTooDeep,
    required this.skippedPathTooLong,
    required this.availableCount,
    required this.countCapped,
  });

  /// 可发送的文件（最多 [kFolderSendMaxFiles] 个），含相对路径。
  final List<FolderScanFile> files;

  /// 可发送的路径（最多 [kFolderSendMaxFiles] 个）。派生自 [files]。
  List<String> get paths =>
      <String>[for (final FolderScanFile file in files) file.path];

  /// 这些路径的字节总数。
  final int totalBytes;

  /// 跳过的隐藏条目数。
  final int skippedHidden;

  /// 跳过的空文件数。
  final int skippedEmpty;

  /// 因为太深没有展开的目录数。
  final int skippedTooDeep;

  /// 因为接收端放不下而没有进批次的文件数（CR-2 ②，见
  /// [SendFolderSelection.skippedPathTooLong]）。
  final int skippedPathTooLong;

  /// 目录里可发送文件的总数（可能大于 [paths] 的长度，见 [tooMany]）。
  final int availableCount;

  /// 是否在 [kFolderSendCountCap] 处停止计数。
  final bool countCapped;

  /// 文件数超过上限——调用方必须**整批不发**并如实告知。
  bool get tooMany => availableCount > kFolderSendMaxFiles;

  /// 一个可发送的文件都没有。
  bool get isEmpty => files.isEmpty;
}

/// 扫描 [root]，返回**可发送**的文件与各项跳过计数。
///
/// 规则，逐条都可测：
/// * 广度优先、最多 [maxDepth] 层（根目录的直接子项是第 1 层）；
/// * 名字以 `.` 开头的条目整体跳过（目录也不展开），计入 `skippedHidden`；
///   这条同时挡住 `.DS_Store`、`.thumbnails`、macOS 的 `._x` 资源叉；
/// * 大小为 0 的文件跳过并计入 `skippedEmpty`——0 字节文件发过去只会让对方
///   收到一个打不开的空壳；
/// * **不截断**：可发送文件一旦超过 [maxFiles]，[paths] 不再增长，但
///   `availableCount` 继续数到 [countCap]，调用方据此整批拒绝；
/// * 超过 [maxDepth] 的目录不展开，`.skippedTooDeep` 计数，绝不静默；
/// * 位置是**接收端要不了**的那种（[rejectsPath] 说不），该文件不进批次，
///   `.skippedPathTooLong` 计数，**其余文件照发**（CR-2 ②）。
///
/// 每个文件同时得到它在 [root] 里的位置（[FolderScanFile.relativePath]）：
/// 相对、`/` 分隔、不含 [root] 的名字。这一条是 0.2.38 加的 —— 层级必须在
/// **扫描的同一遍**里带出来，任何"事后再按路径前缀推算一次"的做法都会在
/// 平台分隔符上分叉（本文件禁止用 `Platform.pathSeparator`，见文件头）。
///
/// [rejectsPath] 是 CR-2 ② 加的**注入点**：判定用的是接收端真跑的那一份
/// `normalizeRelativePath`，而它住在 `lanlink_core` 里（`domain/` 不许 import，
/// 见 [ReceiverPathCheck]）。`null` = 不预筛，只对"反正也发不出去"的调用者
/// 成立——两个生产入口（桌面 `describeFolderForSending`、Android
/// `parseSendFolderReply`）都必须传。
///
/// [list] 抛出的异常向上传播（调用方转成 `failed`）：一个读到一半失败的目录
/// 如果被当成"到此为止"，用户会以为发全了。
Future<FolderScan> scanFolderForSending({
  required String root,
  required FolderLister list,
  int maxDepth = kFolderSendMaxDepth,
  int maxFiles = kFolderSendMaxFiles,
  int countCap = kFolderSendCountCap,
  ReceiverPathCheck? rejectsPath,
}) async {
  final List<FolderScanFile> files = <FolderScanFile>[];
  int totalBytes = 0;
  int skippedHidden = 0;
  int skippedEmpty = 0;
  int skippedTooDeep = 0;
  int skippedPathTooLong = 0;
  int available = 0;
  bool capped = false;

  // (目录路径, 该目录的层号, 该目录相对 root 的前缀)。根目录是 0，它的直接
  // 子项是 1。前缀不带前导 `/`，并以 `/` 结尾（根目录是空串），所以
  // `'$relPrefix${entry.name}'` 永远是"相对 root 的路径"。
  final List<(String, int, String)> queue = <(String, int, String)>[(root, 0, '')];
  int index = 0;
  while (index < queue.length) {
    if (capped) {
      break;
    }
    final (String directory, int depth, String relPrefix) = queue[index];
    index += 1;
    final List<FolderEntry> entries = await list(directory);
    for (final FolderEntry entry in entries) {
      if (entry.name.startsWith('.')) {
        skippedHidden += 1;
        continue;
      }
      if (entry.isDirectory) {
        if (depth + 1 <= maxDepth) {
          queue.add((entry.path, depth + 1, '$relPrefix${entry.name}/'));
        } else {
          skippedTooDeep += 1;
        }
        continue;
      }
      if (entry.size <= 0) {
        skippedEmpty += 1;
        continue;
      }
      // CR-2 ② — the position this file would be declared with, judged by the
      // receiver's own rules. Checked **before** it counts as available: a file
      // the receiver cannot place is not "one of the 200 we were going to send",
      // and letting it count would turn one bad name into a whole-batch refusal
      // (`tooMany`) instead of one honest skip.
      final String relativePath = '$relPrefix${entry.name}';
      if (rejectsPath != null && rejectsPath(relativePath)) {
        skippedPathTooLong += 1;
        continue;
      }
      available += 1;
      if (available > countCap) {
        capped = true;
        break;
      }
      if (files.length < maxFiles) {
        files.add(
          FolderScanFile(
            path: entry.path,
            // Built with `/`, never `Platform.pathSeparator`: this file is
            // pure Dart and the *wire* form is `/` on every platform
            // (`docs/22` §4.3a / §3.2).
            relativePath: relativePath,
            size: entry.size,
          ),
        );
        totalBytes += entry.size;
      }
    }
  }

  return FolderScan(
    files: List<FolderScanFile>.unmodifiable(files),
    totalBytes: totalBytes,
    skippedHidden: skippedHidden,
    skippedEmpty: skippedEmpty,
    skippedTooDeep: skippedTooDeep,
    skippedPathTooLong: skippedPathTooLong,
    availableCount: capped ? countCap : available,
    countCapped: capped,
  );
}
