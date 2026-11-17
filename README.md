# lanlink

局域网文件互传工具。形态是「**设备 = 长期会话，文件 = 消息**」：不是「选文件 → 发送 → 关掉」的一次性工具，而是像聊天软件那样按设备保留会话、把每个文件当成一条消息。

A LAN file-transfer app for Windows and Android, built around long-lived per-device conversations instead of one-shot transfers. Self-hosted protocol, no account, no cloud, no relay.

> **项目定位**：个人自用工具，不承诺路线图；issue 与 PR 可能不会及时处理。
> 代码有可读之处，故开放源码；不建议作为通用传输工具的替代品。

> **代码由 AI 生成**：由 DeepSeek 驱动，在 WorkBuddy 的多智能体环境中完成；需求、取舍与验收由人负责。
> 详见文末 [「代码来源与分工」](#代码来源与分工)。

> **仅需使用、不阅读代码**：见 [「下载即用」](#下载即用)。发行包为已编译产物，无需构建环境。

---

## 它是什么 / 不是什么

| 是 | 不是 |
|---|---|
| 同一个 Wi-Fi 里、自己两台设备之间的直传 | 公网传输（比如从公司连回家里）、跨路由器中转（没做穿透） |
| 设备 → 会话，文件 → 消息（可翻历史、可搜索） | 一次性的「选文件发送」工具 |
| 自己的协议、自己的证书、自己的数据 | 依赖任何账号、云盘或第三方服务器 |
| Windows + Android | macOS / Linux / iOS |

---

## 功能

**传输**
- 单文件、多选、整个文件夹（文件夹保留子目录结构）
- 多选的文件在**两端都聚合成一条消息**（发送端 1 条 N 附件，接收端也合成 1 条）
- 传输中显示总进度与「第 k/N 个」、剩余时间、实时速率
- 接收为**总开关**：开启后自动接收，不逐条征求确认

**会话**
- 设备即会话：历史按设备保留，切设备不丢上下文
- 时间线气泡：文字 / 文件 / 文件夹卡片，带日期分隔与时间戳
- 「媒体与文件」：该会话的图片 / 视频 / 文件三分类媒体墙，可**点开**、可**转到消息**（回到时间线并居中定位）
- 文字消息可拖选复制；右键菜单（复制 / 转发到… / 删除消息）
- 多选模式（删除 / 转发）、未发送成功一键全部重试
- 对方不在线时，消息先排着队，等它上线自动发出去

**平台特性**
- **Android**：注册系统「分享」菜单，分享进来的文件**不自动发送**——先问「发给谁」，选一台进那个会话的「待发送」，选定后可以改发到另一台，取消则留在会话列表等你点；收到的文件保存至 `Download/lanlink`（文件管理器可见，是否进入相册取决于系统）；退至后台后传输继续
- **Windows**：支持拖入文件直接发送、拖出会话文件至资源管理器；窗口尺寸有下限，不会压缩至布局溢出

**设备发现**
1. 处于同一 Wi-Fi 时自动发现，无需输入地址（同时使用组播与广播两种方式，提高受限网络下的成功率）
2. 自动发现失败时可手动填写对方 IP；地址会被保存并定时探测。广播被网络阻断时，这是唯一可用的连接方式

---

## 平台

| 平台 | 状态 |
|---|---|
| Windows 10/11 x64 | 已验证 |
| Android 7.0 及以上 | 已验证 |
| macOS / Linux / iOS | 不支持（工程里没有对应平台目录） |

---

## 下载即用

### Windows

1. 将 `lanlink-电脑版-x.y.z-正式版.zip` 完整解压至任意目录。`lanlink_app.exe` 依赖同目录下的
   `data` 文件夹与若干 `.dll` 文件，不可单独取出该程序。
2. 运行 `lanlink_app.exe`。
3. 首次运行时可能出现两处系统提示，均可放行：
   - **「Windows 已保护你的电脑」**：选择「更多信息」→「仍要运行」。
     原因为本项目未购买代码签名证书，与文件安全无关。
   - **防火墙提示**：勾选「专用网络」并允许访问。若拒绝，其他设备将无法向其发送文件。

### Android

1. 安装 `lanlink-手机版-x.y.z-正式版.apk`。
2. 系统提示「未知来源」时允许一次。非应用商店分发的安装包均需此步骤。

两端处于同一 Wi-Fi 后即可互相发现。无法发现时，参见「常见问题」中的网络排查条目。

> 少数精简版 Windows 缺少系统运行库，运行时提示缺少 `msvcp140.dll`。该运行库已随 zip 分发，
> 通常不会出现；若出现，安装微软官方「Microsoft Visual C++ 可再发行组件」（约 25 MB）。

---

## 从源码编译

> 已有发行包的用户可跳过本节，无需安装下列任何组件。

以下组件缺一即构建失败。

| 需要 | 版本 / 说明 |
|---|---|
| Flutter | **≥ 3.44**（`app/pubspec.lock` 里 `flutter:` 的真实下限；开发与验证用的是 3.47.6） |
| Dart | **≥ 3.12**（同上，`dart: ">=3.12.0 <4.0.0"`）。`pubspec.yaml` 只写 `sdk: ^3.6.0`，比 lock 宽松，**以 lock 为准** |
| **Visual Studio 2022** | 勾选「**使用 C++ 的桌面开发**」工作负载；Windows 桌面构建必需 |
| **Windows 开发者模式** | 开（设置 → 系统 → 开发者选项）。不开的话 Flutter 给插件建符号链接会失败 |
| **JDK 17** | Android 构建必需（`sourceCompatibility` / `jvmTarget` 都是 17） |
| Android SDK | 编译 SDK 与 build-tools 按 `app/android/app/build.gradle.kts` 装 |
| 可用内存 | **≥ 8 GB**（`app/android/gradle.properties` 里 `org.gradle.jvmargs=-Xmx8G`；内存小的机器要自己往下调，否则 Gradle daemon 起不来） |
| 工程路径 | **建议放在纯英文、无空格的路径下**。路径含非 ASCII 字符时，release 构建的 AOT 快照器会读不了文件而失败（debug 不受影响） |

---

## 编译与运行

**四个包必须并列**（`app` 用 `path:` 依赖 `../core` 与 `../store`），单独拿 `app/` 一个目录是跑不起来的。

### Windows

```bash
cd app
flutter pub get
flutter run -d windows                  # 开发运行
flutter build windows --release         # 出包 → build/windows/x64/runner/Release/
```

出包目录里的可执行文件依赖 **MSVC 运行时**（`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll`）。目标机器没装 VC++ 运行库时，把这三个 DLL 一起带上。

### Android

```bash
cd app
flutter pub get
flutter run -d <设备 id>
flutter build apk --release             # → build/app/outputs/flutter-apk/app-release.apk
```

> **签名**：仓库**不带** keystore，但**有**读 `key.properties` 的机制。`app/android/app/build.gradle.kts` 在 `app/android/key.properties` 存在时用里面的 release 钥匙签名，不存在就回落到 **debug 签名**（所以上面的命令在裸克隆上照样能跑通）。
>
> 要出一个能覆盖升级的正式包，建 `app/android/key.properties`，四个字段：
>
> ```properties
> storePassword=<口令>
> keyPassword=<口令>
> keyAlias=<alias>
> storeFile=E:/path/to/your-release.jks
> ```
>
> `app/android/.gitignore` 已经忽略 `key.properties`、`*.jks`、`*.keystore`，不会误提交。
> **该密钥丢失后无法再向已安装用户推送升级**（Android 仅接受同一私钥签名的包，更换密钥等同于更换应用）。生成后应立即备份至仓库之外。
>
> 版本的写法是 `x.y.z+N`（`app/pubspec.yaml` 的 `version:`）：`N` 就是 Android 的 **versionCode**，每次发版必须**只增不减**，否则系统拒绝覆盖安装；`x.y.z` 是 versionName，就是界面上显示的那个。当前是 `0.2.63+63`。

### 命令行版

```bash
cd cli
dart pub get
dart run bin/lanlink.dart --help        # discover / announce / send / history
```

### 测试与静态检查

```bash
cd app    && flutter test && dart analyze
cd core   && dart test && dart analyze
cd store  && dart test && dart analyze
cd cli    && dart test && dart analyze
```

仓库包含 CI（`.github/workflows/ci.yml`）：每次提交或 PR，GitHub 会启动一台 Windows 机器，
安装相同版本的 Flutter 并执行上述四组命令。**页面上的通过标记表示上述测试已在非开发机上实际执行。**

---

## 常见问题

以下按报错信息索引。多数为环境缺失，而非代码缺陷。

**`was resolved to … but … requires SDK version ^3.6.0` / `requires Flutter >=3.44.0`**
→ Flutter 装太旧了。`flutter --version` 看一眼，按上面「想自己编译？」那节表里的版本装（**以 `pubspec.lock` 记的 3.44 为准，不是 pubspec 里那个 3.6**）。

**`flutter pub get` 卡住不动、或者超时**
→ 无法访问 pub.dev，国内网络环境下常见。先确认 `pub.dev` 可达；必要时为终端设置代理后重试。**不应通过清空代理规避**，否则会阻塞在隐式 `pub get` 上。

**`Unable to find a Visual Studio installation` / `MSB8020` / 找不到 `cl.exe`**
→ Visual Studio 已安装但缺少「**使用 C++ 的桌面开发**」工作负载，需补装（约 2–3 GB）。

**`Building with plugins requires symlink support`**
→ 没开 Windows 开发者模式。设置 → 系统 → 开发者选项 → 打开「开发人员模式」。

**Android 报 `Unsupported class file major version` / `invalid source release: 17`**
→ JDK 不是 17。这条项目固定用 JDK 17，21 也可能行但没验过；8 和 11 一定不行。

**Gradle 卡在 `Download https://services.gradle.org/distributions/gradle-9.3.1-all.zip`**
→ Gradle 本体约 200 MB，部分网络下较慢或中断。可临时修改 `app/android/gradle/wrapper/gradle-wrapper.properties` 的 `distributionUrl` 指向可访问的镜像；**构建完成后应恢复原值**，否则其他使用者与 CI 无法获取。

**`Java heap space` / Gradle daemon 起不来 / 机器卡死**
→ `app/android/gradle.properties` 中 `org.gradle.jvmargs=-Xmx8G`。内存较小的机器需下调（如 `-Xmx2G`）；8 GB 内存的机器在同时运行浏览器时易因内存不足失败。

**`flutter analyze` 直接崩、没有任何输出**
→ 工程路径里有中文或空格时会出现。改用 `dart analyze lib test`（本仓库一直用这个），或者把工程挪到纯英文路径。

**`release` 构建报 `Unable to read file: …app.dill`、路径里出现乱码**
→ AOT 快照器读不了非 ASCII 路径。**release 必须在纯英文路径下构建**（debug 不受影响）。这就是 `docs` 里说「复制到英文目录再构建」的原因。

**装好了、两台设备互相看不见**
→ 依次排查：① 两台设备是否处于**同一网段**（同名 Wi-Fi 不代表同网段）；② Windows 防火墙是否拦截 49494；③ 路由器是否启用「客户端隔离 / AP 隔离」（启用后双方均无法发现对方）；④ 以上均排除后，使用手动填写 IP（中栏 ⋮ → 手动填写 IP 连接）。

**`SocketException: address already in use` / 端口 49494 被占**
→ 已有 lanlink 实例在运行，或其他程序占用了 49494。退出全部实例后重新启动。

---

## 目录结构

```
core/    纯 Dart：协议常量、帧编解码、发现层、TLS、上传/接收、哈希 worker
store/   纯 Dart：SQLite 五张表（devices / conversations / messages / files / transfers）、
         幂等消息 ID、消息状态机、SessionStore 门面
cli/     纯 Dart：命令行前端（discover / announce / send / history）
app/     Flutter：三栏（窄屏两级）+ Windows 原生拖出 + Android 前台服务与 MediaStore 发布
```

依赖方向是单向的、可检查的：`app → core + store`，`cli → core + store`，`store → core`；
`core` 与 `store` **都不依赖 Flutter**（因此可以在纯 Dart 环境里测）。

> 代码注释中的 `(docs/13 §4)` 等编号指向作者本地的设计文档；这些文档包含真实设备与网络信息，
> 未随仓库发布。保留编号是为了让注释中的因果关系可追溯，注释本身已说明原因。

---

## 协议与安全

> 本节描述内部实现，面向需要阅读代码或评估协议的使用者。仅使用发行包时可跳过。

- 自有协议 `lanlink/v1`：`/api/lanlink/v1`，默认端口 **49494**
- 帧类型：`announce / hello / hello.reply / prepare / prepare.reply / text / ack / put.reply / resume.reply / error`；
  `put` 与 `cancel` 是 **HTTP 路径**（`/api/lanlink/v1/put`、`/cancel`），不是帧类型
- 传输走 TLS；设备身份是一张**自签证书**，其 SHA-256 指纹就是设备 ID
- 首次连接是「首次使用即信任」（TOFU），之后**指纹固定**：对端证书变了会拒绝
  （**此条仅在主动发送时成立**；接收方向的身份校验见下文）
- `resume`（断点续传）端点目前是**占位**，固定返回 501

> 本实现面向**自己可控的局域网**。未提供证书轮换、身份吊销与审计日志，不适用于企业环境。

> **注意方向不对称**：TLS 仅保护出站方向（本方发起），不保护入站方向（他方发来）。

- **接收端不验证发送方身份。** 服务端不要求客户端证书（`peer_server.dart` 里没有任何客户端证书校验），
  `hello` 帧里的设备指纹是**对方自报的**，接收端直接采信并写进设备表。
  ⟹ 同一网段内任何程序按该协议发送一帧，即可将文件写入本机接收目录；
  它还可自报为已有设备的指纹，**冒充该设备**出现在会话列表中。
- **接收默认是开着的，且没有逐条确认**（`acceptByDefault = true`）。关闭后，其他设备发来的文件会被直接拒收（对方显示「已被拒收」）。
- **收到的文件落在公共目录**：Android 是 `Download/lanlink`，Windows 是接收目录。
- **应用内可以直接安装 APK**：manifest 声明了 `REQUEST_INSTALL_PACKAGES`，打开 `.apk` 会唤起系统安装器。

上述条件叠加后：在共享网络中保持接收开启，同网段的其他主机可推送一个 `.apk`，
该文件会作为一条消息出现在会话中，打开即进入系统安装界面。

该行为源于设计前提：**同一局域网内的设备被视为可信**。代码公开后此前提可被任何人读到，故在此明示。
**在办公、宿舍、公共 Wi-Fi 等共享网络中，建议关闭接收。**

- 协议与数据表中另有 `pin` / `trusted` / `paired_at` / `group_code` 四个**预留字段**，目前未接线，不应在安全上依赖。

---

## 已知限制

- **没有断点续传**：连接一断，整个文件从头再传
- **只在同一个 Wi-Fi 里能用**：跨网络（比如从公司连回家里）不行，也没有穿透
- **没有额外加密**：传输链路本身加密，但不具备「仅通信双方可见」的第二层保障；亦无跨设备剪贴板
- 「删除消息」仅删除本机记录，**不修改磁盘文件**，也**不删除对方侧的消息**
- 「N 个未收到」仅在会话静止超过 90 秒后显示，避免对方仍在传输时误报
- 没有 macOS / Linux / iOS 版本
- **仓库不提供发布签名**：未配置 `key.properties` 时使用调试签名，可正常安装；但调试签名与本机绑定，
  换机重建后无法覆盖已安装的旧包。对外分发前应自建 keystore，做法见「编译与运行 → Android」

---

## 代码来源与分工

本项目代码由 AI 生成，非手写。第一行至 0.2.63 全部由 AI 产出，人类承担的是另一部分工作。
说明这一点是为了标明代码性质，而非免责。

| 角色 | 职责 |
|---|---|
| **需求与验收**：kk339 | 提出需求、决定取舍、在真机上验收；每一版是否通过由其判断 |
| **实现**：DeepSeek 驱动的 AI 代理（运行于 WorkBuddy 多智能体环境） | 架构设计、编码、测试、缺陷定位、出包、文档 |

具体分工：

- **人类完成的部分**：定义需求与边界；否决不必要的范围（仓库中多数功能边界由其决定）；
  在真机上验证并描述异常现象，多项缺陷由此定位。
- **AI 完成的部分**：协议设计、界面实现、1075 条测试、`windows/` 下的 C++ 拖出实现；
  以及每一轮「问题上报 → 定位 → 修复 → 补充回归测试」。

### 阅读代码时的注意事项

1. **代码未经人类逐行审阅。** 可保证的是行为正确（真机运行两个月），无法保证每处边界条件均已检查。
   涉及安全的假设应自行复核，重点为 `core/lib/src/security/` 下的路径校验与证书处理。
2. **测试是本项目唯一的完成标准。** 1075 + 224 + 182 + 12 条断言全部通过，每个新增功能配有可失败的用例；
   但测试覆盖不等同于设计完备，未覆盖的边界仍会通过。
3. **风格不完全统一。** 开发期间更换过模型、调整过方案、推翻过结论，因此注释密度、命名习惯、
   同一问题的处理方式可能存在差异。此为过程遗留，非疏漏。

若这份代码有参考价值，其中一部分来自需求判断：做什么、不做什么，无法由 AI 独立决定。

### 关于仓库历史

本仓库仅有一次提交，为有意为之。原始开发历史（两个多月、260 余次提交）包含设备名、
内网地址、人员姓名与内部工作记录，逐条脱敏不具可行性。
**故此处为代码快照，而非开发过程。** 每处改动的动机保留在代码注释中。

---

## 许可

[MIT](LICENSE)

第三方依赖的许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
应用内「关于 → 开源许可」页由 Flutter 自动汇总全部依赖的许可证。
