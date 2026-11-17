/// The 「使用帮助」 page (**new in 0.2.21**).
///
/// The six steps below **used to live at the bottom of the 关于 page**. They were
/// moved here verbatim — not re-worded, not shortened — because they were the
/// reason the About page read like a manual: steps ③–⑥ are troubleshooting (the
/// receive switch, the foreground notification, where a received file lands, where
/// the log is) plus an explanation of why a link's speed is what it is. None of
/// that is "about the app"; all of it is "how to use it", which is what this page
/// is for.
///
/// **The copy was re-written once, and only in voice (not in content).** The user
/// said 「教人使用那一块你写的正常一点，现在看着感觉像是跟我聊天」. Every step
/// had been phrased as an argument with the reader: three of them paused to
/// reassure (the notification is not a sign of anything being transferred; the
/// speed difference comes from the link, not from a defect; the log's first line
/// is enough on its own, no need to ask anyone), and the titles were questions or
/// warnings (a noun phrase that named the reader's failure before explaining
/// anything). A manual states; it does not defend itself. So:
///
/// * **titles became noun phrases** — no question marks, no 「先看…」;
/// * **bodies became declarative** — no self-justification, no addressing the
///   reader's imagined doubts;
/// * **nothing was dropped**: every fact (the switch's memory, the notification's
///   purpose and its Android 13 permission, both default folders, both log paths,
///   the link ladder) is still here, and ④ is *more* accurate than before — see
///   below.
///
/// ④ named the phone's receive folder as the private app directory
/// (`…/lanlink/received`). That stopped being where the file ends up in **0.2.19**,
/// when verified files started being published into the public `Download/lanlink`
/// collection (`ReceivedFilePublisher` → `MediaStore.Downloads`) and the private
/// copy is deleted. The step now states `Download/lanlink`, which is the folder the
/// user opens.
///
/// **Copy is verbatim from `docs/16-关于页与使用简介-文案.md`** §2 — the
/// anti-drift doc (its §4 table maps each claim to the code that makes it true).
/// The step order is the order of "what you have to do the first time", so do not
/// re-sort it.
///
/// **Layering (design §9.6):** imports only `package:flutter/**` and sibling
/// `ui/**`.
library;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Standalone 「使用帮助」 page pushed from the 关于 page.
class HelpPage extends StatelessWidget {
  /// Creates the page.
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      // A pushed page: the AppBar's back arrow is the way out, so no custom
      // leading widget and no extra "close" affordance.
      appBar: AppBar(title: const Text('使用帮助')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        children: <Widget>[
          _step(
            theme,
            1,
            '让两台设备处于同一局域网',
            '连接同一个 WiFi 即可。没有路由器时，可让其中一台开启热点，'
                '另一台连接该热点。',
          ),
          _step(
            theme,
            2,
            '首次发送需对方确认',
            '选择文件与目标设备后，发送方进入等待确认状态；对方点击「接受」后开始传输。'
                '对方开启自动接收时不再询问。',
          ),
          _step(
            theme,
            3,
            '接收开关与常驻通知',
            '接收开关关闭时，其他设备发来的文件会被直接拒绝，对方看到「被拒绝」。'
                '该开关保存上次的状态。\n'
                '手机端会常驻一条通知，用于保持息屏或切到后台后不掉线；'
                '该通知与传输进度无关。通知未显示时，请检查通知权限'
                '（Android 13 及以上需允许通知）。',
          ),
          _step(
            theme,
            4,
            '收到的文件位置',
            '默认接收位置如下，可在「设置」中修改：\n'
                '· Windows：%LOCALAPPDATA%\\lanlink\\received\n'
                '· 手机：Download/lanlink（文件管理器和相册可见）',
          ),
          _step(
            theme,
            5,
            '日志位置',
            '日志文件为 lanlink.log，第一行记录日志自身的完整路径。\n'
                '手机端另存一份到 /Android/data/<包名>/files/lanlink.log，'
                '可通过文件管理器或 USB 取出。',
          ),
          _step(
            theme,
            6,
            '传输速度',
            '速度由链路决定：网线 > 5GHz WiFi > 2.4GHz WiFi。'
                '出现 2–3 MB/s 通常表示连接在 2.4GHz 或信号较弱；'
                '切换至 5GHz 或使用网线可明显提升。',
          ),
        ],
      ),
    );
  }

  /// A numbered step: a filled brand-coloured index, then title over body.
  ///
  /// Kept byte-for-byte in behaviour from the 关于 page's `_step` (same radius 11,
  /// same [kSeedColor] fill, same 12px gap after each step) so the move is a
  /// change of location, not of appearance.
  Widget _step(ThemeData theme, int index, String title, String body) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CircleAvatar(
              radius: 11,
              backgroundColor: kSeedColor,
              child: Text(
                '$index',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
