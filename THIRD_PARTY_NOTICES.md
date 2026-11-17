# 第三方组件与许可

本仓库自身以 [MIT](LICENSE) 发布。下面是**直接依赖**的许可证。

应用打包后，Flutter 会把这些组件（以及它们的传递依赖）的完整许可证文本汇总进产物的 `NOTICES` 资源，
应用内「关于 → 开源许可」页展示的就是那一份，分发二进制时无需额外操作。

| 组件 | 用于 | 许可证 |
|---|---|---|
| Flutter SDK / `flutter_localizations`（含 `intl`） | 全部界面 | BSD-3-Clause（Flutter Authors） |
| `path` | 四包 | BSD-3-Clause（Dart Authors） |
| `crypto` | `core`（SHA-256） | BSD-3-Clause（Dart Authors） |
| `basic_utils` | `core`（X.509 / 证书解析） | MIT |
| `pointycastle` | `core`（RSA 密钥与签名） | MIT |
| `sqlite3` | `store` | MIT（Simon Binder；内含 SQLite 本体，属公有领域） |
| `sqlite3_flutter_libs` | `app` | MIT（Simon Binder） |
| `path_provider` | `app` | BSD-3-Clause（Flutter Authors） |
| `file_selector` | `app`（桌面选文件） | BSD-3-Clause（Flutter Authors） |
| **`desktop_drop`** | `app`（Windows 拖入） | **Apache-2.0** |

## 关于 `desktop_drop`（唯一一个 Apache-2.0 直接依赖）

Apache-2.0 不是传染性许可证，可以与本项目一起以 MIT 分发。它的要求是：
随分发物**附带许可证全文**、保留原始版权声明、并标注被修改过的文件（我们**没有修改**它的源码）。

- 许可证全文：<https://www.apache.org/licenses/LICENSE-2.0>
- 上游项目：<https://pub.dev/packages/desktop_drop>
- 版权：`Copyright [2021] [Mixin]` —— 上游 `MixinNetwork/flutter-plugins`（这是 Apache-2.0 §4(c) 要求保留的原文，不能改写成别的名字）

不修改源码时，`NOTICES`（由 Flutter 构建自动生成，随产物分发）已满足这些要求。

## 致谢（非代码来源）

协议 `lanlink/v1` 是本项目自写的（`/api/lanlink/v1`、端口 49494、组播 224.0.0.168），
不包含任何第三方协议的实现代码。设计早期参考过 [LocalSend](https://github.com/localsend/localsend)
（Apache-2.0）的协议分层思路 —— 仅思路，未复制其源码。

界面形态参考了若干成熟产品（Flix、飞书、Telegram）的**交互结构**。
仓库内**不含**任何第三方产品的截图或素材。
