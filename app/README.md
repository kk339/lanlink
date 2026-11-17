# lanlink_app — 会话界面

把「设备 = 长期会话、文件 = 消息」做成一个 Flutter 应用，建立在 `lanlink_core`
（发现 + 传输）与 `lanlink_store`（会话数据层）之上。这一层**只做 UI 与接线**，
数据层保持冻结。

**三栏外壳**：左栏是模块导航（会话 / 最近文件 / 已归档 / 设置）+ 接收开关，中栏是当前
模块的列表，右栏是详情。窄窗（< 760px）自动折叠成「列表 ⇄ 详情」两级。
**唯一的挂载点是 `ShellPage`**（`lib/ui/shell/shell_page.dart`）——旧的多页 `Navigator`
栈（`lib/ui/pages/**`）已随之删除。

---

## 运行

前置：Flutter ≥ 3.24（含 Dart ≥ 3.6）。

```bash
cd app
flutter pub get

# 桌面（Windows）
flutter run -d windows
```

### 为什么 Windows 上还需要两样东西

- **Visual Studio「使用 C++ 的桌面开发」工作负载（Build Tools 即可）**
  —— `flutter build windows` / `flutter run -d windows` 需要它来编译 C++ 宿主。
- **Windows 开发人员模式（Developer Mode）**
  —— 打开方式：`设置 → 系统 → 开发者选项 → 开发人员模式`。
  Flutter 的插件机制在 Windows 上会创建**符号链接**，未开启开发人员模式时
  `flutter build windows` 会以「无法创建符号链接 / symlink」之类的错误失败。
  这是本工程踩过的坑，**先开开发人员模式再构建**。

---

## 测试与静态检查

```bash
cd app

# 全部 widget / 单元测试
flutter test
```

- 测试用**纯 Dart 假实现**驱动（无 socket、无磁盘、无真实时钟），见 `test/support/`。
- 挂载点统一是 `pumpShell(tester, …)`（`test/support/pump_app.dart`），它把
  `ShellPage(…)` 挂到同一个 `AppScope → MaterialApp` 下：`initialModule` 选模块、
  `initialPeer` 选会话（详见同文件的文档注释，含「重复挂载需先卸载」的注意事项）。
- 端到端的边界情况走查（E1–E13，外加改版新增的 E14/E15/E16）在
  `test/widget/edge_cases_test.dart`；右栏「文件」tab 的 E20–E22 在
  `test/widget/conversation_files_tab_test.dart`；夹具都在 `lib/data/fake/scenarios.dart`。

### ⚠️ 受限环境里 `flutter test` 报 WebSocket 错——是**代理**，不是「跑不了」

若 `flutter test` 以
`Unable to connect to flutter_tester process: WebSocketException: Invalid WebSocket
upgrade request` 失败，**不要**下结论说「这个环境只能到 `dart analyze`、跑不了测试」——
**那不是沙箱限制**。真实原因是**代理环境变量**（`http_proxy` / `https_proxy` 及大写的
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`）指向本机代理时，`flutter_tester` 子进程连
**回环地址 `127.0.0.1`** 的 WebSocket 也被代理截胡了。**放行回环即可** ——
但 **★ 别把代理整个清掉** ✗：`flutter test` 在 `pubspec.yaml` 变动后会先自动 `pub get`，
代理一清就**连不上 pub.dev 而挂住** ✗（实测：干了 5 分钟没输出）。
**保留代理、只加 `NO_PROXY`** ✓：

```bash
# 保留代理（pub get / 其它网络仍可用），只让回环地址绕过它（flutter_tester 要连 127.0.0.1）
NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" flutter test
```

（`flutter test test/widget/xxx_test.dart` 单文件同理。）**`dart analyze` 不受影响**，
一直可跑；它覆盖 `lib/**` + `test/**` 的**编译期**，但**不执行断言**——所以**它能过 ≠ 测试能过**，
真正的绿仍须 `flutter test` 实跑。

### 静态检查

```bash
dart analyze
```

> ⚠️ **若 `flutter analyze` 在启动分析器子进程时崩溃**（已知会在工程路径含非 ASCII
> 字符时发生），改用 **`dart analyze`**。若个别受限环境里连 `dart analyze` 也起不来，
> 可退而用 `dart run test/<file>.dart` 逐文件真跑测试（等价于 `dart test`）。
> 格式化用 `dart format`。

---

## 架构铁律（一句话）

> `domain/` + `data/fake/` + `controllers/` + `ui/`（以及 `bootstrap/create_deps*.dart`
> 的 **stub** 分支）**不得** import `dart:io` / `dart:ffi` / `package:lanlink_core` /
> `package:lanlink_store`；**只有** `data/real/**` 和 `bootstrap/create_deps_native.dart`
> 允许。

这条分层同时保证 `lib/domain/**`、`lib/data/fake/**`、`lib/controllers/**`、
`lib/ui/**` 与纯 Dart 的 `dart test` 可跑：这些文件不碰 native，任何环境下都能编译。

---

## 接收开关的语义（左栏 / 设置页是同一个开关）

- **记住选择**：打开后**一直生效**，**下次启动仍然是开**（写盘由
  `SettingsController.setAccepting` 这**唯一**一个写入口负责，左栏与设置页都走它）。
- **关闭时**：对方发来的文件会被**直接拒绝**，且对方会看到「被拒绝」。
- 我方界面会留下一条**中性提示**（不是错误红色、也不是一条聊天消息）：说清**是谁**、
  **为什么**被拒。`PeerServer.onUploadRejected` 是 core 层的回调，`LanTransferService`
  把它转成 `uploadRejected` 流，`HomeController.transferNotice` 持有最近一条，
  左栏下方用 `NoticeBanner` 展示、可关闭。

---

## 改哪里（小地图）

| 你要改的东西 | 去哪 |
| --- | --- |
| 三栏外壳（左栏导航 / 中栏列表 / 右栏详情） | `lib/ui/shell/` |
| 中栏各模块与右栏详情（列表、抽屉、文件详情…） | `lib/ui/panes/` |
| 可复用组件（气泡、设备行、文件行、状态片、缩略图…） | `lib/ui/widgets/` |
| 单色主题 + 七态配色 | `lib/ui/theme.dart` |
| 全部 UI 文案与格式化（状态文字 / 大小 / 日期） | `lib/ui/format.dart` |
| 页面状态与业务编排（手写 `ChangeNotifier`） | `lib/controllers/` |
| 六个端口的契约（纯 Dart 接口） | `lib/domain/*.dart` |
| 纯派生逻辑（设备卡合并、最近文件聚合/分组/搜索） | `lib/domain/selectors.dart` |
| 内存假实现（测试用） | `lib/data/fake/` |
| 端到端边界情况的具名夹具（E1–E13 + E14/E15/E16） | `lib/data/fake/scenarios.dart` |
| 真实现（`dart:io` + `core` + `store`） | `lib/data/real/` |
| 依赖装配 / 平台选择 | `lib/bootstrap/`（`create_deps.dart` 是 conditional export） |
| 应用根（`AppScope → MaterialApp → ShellPage`）与入口 | `lib/app.dart` / `lib/main.dart` |
| 测试辅助（`pumpApp` / `pumpShell`、共享假实现） | `test/support/` |

> **`AppScope` 必须包在 `MaterialApp` 外面**（`lib/app.dart`）：`MaterialApp` 弹出的任何
> 路由 / 对话框都是 `home` 的**兄弟节点**，把 `AppScope` 放进 `home` 里会让它们读不到
> `context.deps` 而崩（三栏外壳已不再做页面级 `Navigator.push`，但这条约定不变）。
> 测试里同样如此（`test/support/pump_app.dart`）。

---

## 目录

```
app/
├── lib/
│   ├── main.dart                # 入口：createAppDeps() → LanlinkApp
│   ├── app.dart                 # AppScope → MaterialApp → ShellPage
│   ├── bootstrap/               # AppDeps / AppConfig + 平台 conditional export
│   ├── domain/                  # 纯 Dart：模型、端口、selectors、异步值
│   ├── data/
│   │   ├── fake/                # 内存假实现；scenarios.dart = E1–E13(+E14/E15/E16/E20) 夹具入口
│   │   └── real/                # dart:io + core + store 适配器（仅 native）
│   ├── controllers/             # 手写 ChangeNotifier（零状态管理库）
│   └── ui/                      # theme / format / scope + shell + panes + widgets
└── test/
    ├── support/                 # fakes.dart（barrel）+ pump_app.dart（pumpApp / pumpShell）
    ├── widget/                  # 三栏外壳与边界情况的 widget 测试
    └── *.dart                   # selectors / 控制器的纯单元测试
```
