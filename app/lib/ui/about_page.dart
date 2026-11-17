/// The 「关于」 page (M5 §F, **reshaped in 0.2.21**).
///
/// **The shape is the one mainstream apps use**, because that is what the user
/// asked for ("你看别人家关于咋写的你就咋写"):
///
/// ```
///              [ the real icon, 64dp ]
///                     lanlink
///                   版本 0.2.21
///
///          局域网直传 · 不过云 · 不要账号
///
///   ── 信息 ─────────────────────────────────────
///   数据去向     只在你与对端设备之间，不经任何服务器
///   接收位置     Windows：%LOCALAPPDATA%\lanlink\received
///                手机：Download/lanlink
///                可在「设置」中修改
///   局域网端口   49494
///
///   ── 其他 ─────────────────────────────────────
///   使用帮助                              ›
///   开源许可                              ›
///   隐私说明                              ›
///
///                    © 2026 lanlink
/// ```
///
/// **What changed and why (0.2.21).** The page used to be "one-liner + three
/// bullets + a six-step 使用简介", and steps 3–6 of that list were
/// troubleshooting and a lecture on link speed — a manual sitting inside the
/// About page. The six steps now live on their own page ([HelpPage]); only the
/// two groups an About page is *expected* to have remain here.
///
/// **What changed in the 信息 group and why.** Two corrections, both of them
/// facts rather than taste:
///
/// * **`接收位置` now names the two folders.** It used to say 「见「设置」— 可查看
///   与修改」, which was true when the private app-support directory *was* the
///   destination. Since 0.2.19 the phone publishes verified files into the public
///   `Download/lanlink` collection (`ReceivedFilePublisher` → Android
///   `MediaStore.Downloads`) and drops the private copy, so the old wording hid
///   the single fact a user needs when a file seems to have vanished. The row
///   states both platforms' defaults and adds where they can be changed — one
///   sentence, no second place to look.
/// * **The protocol row is gone.** 「lanlink v1（自有帧格式，纯 Dart）」 is a
///   statement about our own implementation; it answers no question the user of
///   this app can act on (the port stays, because a firewall exception is
///   something they *do*). Developer-facing facts belong in `docs/13`, not on a
///   user-facing page — the user said as much: 「关于页的协议写那么多吗」.
///
/// **The two groups have two different shapes, and they must not be confused**
/// (`docs/18` §8.2 — a control that cannot be tapped must not look tappable):
///
/// * 信息 — **read-only**: label on the left, value on the right in
///   `onSurfaceVariant`, no ink response, **no `ListTile`**, no `›`;
/// * 其他 — **tappable**: a `ListTile` that ends in `›`, and every one of the
///   three rows is backed by something real (Flutter's own licence page, a
///   dialog, the help page). No decorative arrow.
///
/// **Copy is verbatim from `docs/16-关于页与使用简介-文案.md`** — the anti-drift
/// doc. Do not re-word it here without updating that doc (its §4 table maps every
/// fact to the code that makes it true, which is how a lie here becomes
/// detectable rather than shipped).
///
/// The version is the single code constant [kAppVersion] (kept in step with
/// `pubspec.yaml` by a guard test) — never a second hand-maintained copy.
///
/// **Layering (design §9.6):** imports only `package:flutter/**` and sibling
/// `ui/**` (plus [app_info] for the identity constants) — never `dart:io`, never
/// `lanlink_core`. That is also why the port is **printed copy** rather than a
/// value read from `ProtocolConfig`: this page has no deps, and the number's
/// single source (`core/lib/src/protocol/constants.dart`, `kDefaultPort`) is
/// recorded in `docs/16` §4 so drift is catchable there.
library;

import 'package:flutter/material.dart';

import '../app_info.dart';
import 'help_page.dart';
import 'theme.dart';

/// Standalone 「关于」 page pushed over the shell.
class AboutPage extends StatelessWidget {
  /// Creates the page.
  const AboutPage({super.key});

  /// The copyright line. **The year is written, not computed** — a computed
  /// `DateTime.now().year` would make the widget test's literal assertion depend
  /// on the machine clock, i.e. the test would break on New Year's Day for a
  /// reason that has nothing to do with the page.
  static const String _copyright = '© 2026 lanlink';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        children: <Widget>[
          // ── identity ───────────────────────────────────────────────────────
          Center(child: _mark()),
          const SizedBox(height: 16),
          Center(child: Text(kAppName, style: theme.textTheme.headlineSmall)),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '版本 $kAppVersion',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '局域网直传 · 不过云 · 不要账号',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),

          // ── 信息 (read-only) ───────────────────────────────────────────────
          const SizedBox(height: 28),
          _sectionHeader(theme, '信息'),
          const SizedBox(height: 4),
          _infoRow(theme, '数据去向', '只在你与对端设备之间，不经任何服务器'),
          _infoRow(
            theme,
            '接收位置',
            // Three lines on purpose: one per platform plus where to change it.
            // `\\` is an escaped backslash — the copy shows a real Windows path.
            // The Windows line names the `received` folder itself, the same one
            // `HelpPage` ④ names: the label asks 「接收位置」, so the answer is
            // where the *file* lands, not where the app's own directory sits.
            'Windows：%LOCALAPPDATA%\\lanlink\\received\n'
                '手机：Download/lanlink\n'
                '可在「设置」中修改',
          ),
          _infoRow(theme, '局域网端口', '49494'),

          // ── 其他 (tappable) ────────────────────────────────────────────────
          const SizedBox(height: 28),
          _sectionHeader(theme, '其他'),
          _navRow(
            theme,
            title: '使用帮助',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const HelpPage(),
              ),
            ),
          ),
          _navRow(
            theme,
            title: '开源许可',
            // Flutter's own licence page — no dependency, and it lists the
            // licences of everything actually bundled (including `sqlite3`).
            onTap: () => showLicensePage(
              context: context,
              applicationName: kAppName,
              applicationVersion: kAppVersion,
            ),
          ),
          _navRow(
            theme,
            title: '隐私说明',
            onTap: () => _showPrivacy(context),
          ),

          // ── footer ─────────────────────────────────────────────────────────
          const SizedBox(height: 32),
          Center(
            child: Text(
              _copyright,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// The app's **real** artwork, 64dp square (0.2.21).
  ///
  /// The old `CircleAvatar` + `Icons.swap_horiz` was a stand-in drawn because no
  /// logo existed; the icon the user drew does exist and is already published, so
  /// the About page — the one place an app is expected to show it — shows it.
  ///
  /// * [kBrandMarkAssetHiRes] (192px) rather than the 96px file: 64dp at 3x is
  ///   192 device px, so this is the copy that is *sharp* here instead of merely
  ///   adequate. See the constant's own comment for why it is not a `2.0x/`
  ///   variant directory.
  /// * **No `ClipRRect`**: the PNG is transparent artwork with no plate, so it
  ///   has no corners to round — rounding it would clip the prisms for nothing.
  /// * `excludeFromSemantics`: the name is painted right below it; announcing a
  ///   nameless "image" before "lanlink" is noise for a screen reader (the same
  ///   reasoning as the top bar's mark, `home_brand_test`).
  Widget _mark() => Image.asset(
        kBrandMarkAssetHiRes,
        width: 64,
        height: 64,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      );

  /// A group header: the word, then a hairline running to the right edge.
  Widget _sectionHeader(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: <Widget>[
            Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Divider(height: 1, thickness: 1, color: dividerColor(theme)),
            ),
          ],
        ),
      );

  /// A **read-only** fact row: label left, value right (docs/18 §8.2).
  ///
  /// Deliberately not a `ListTile`: no ink, no `›`, no tap handler — nothing that
  /// would promise an action. The label keeps a fixed width so the three values
  /// line up; the value may wrap to two lines (right-aligned) on a narrow phone,
  /// and `接收位置` uses embedded `\n` so its three facts are three lines whatever
  /// the width — a wrapped path is unreadable, a broken-out one is not.
  Widget _infoRow(ThemeData theme, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 80,
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );

  /// A **tappable** row, marked as such by the trailing `›` (docs/18 §8.2).
  ///
  /// `contentPadding: zero` keeps its text on the same left edge as the 信息
  /// labels above, so the page reads as one column rather than two.
  Widget _navRow(
    ThemeData theme, {
    required String title,
    required VoidCallback onTap,
  }) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        trailing: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
        onTap: onTap,
      );

  /// The 隐私说明 dialog — three statements, each one **checkable**.
  ///
  /// `docs/16` §3 forbids marketing language here, and the doc's §4 table is what
  /// keeps these three true: no account exists anywhere in the app; the transfer
  /// path is peer-to-peer inside the LAN (`docs/13` — our own endpoints, no
  /// server); and nothing in the app opens an outbound connection except the
  /// discovery/transfer peers themselves (no analytics SDK in `pubspec.yaml`).
  /// **If any of that ever changes, this dialog is part of the change** — a
  /// privacy statement that quietly becomes false is worse than none.
  void _showPrivacy(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('隐私说明'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('没有账号，也不需要注册。装好打开就能用。'),
            SizedBox(height: 12),
            Text('文件只在这台设备与对端设备之间直传，不经过任何服务器；'
                '本应用不收集、不上传文件内容。'),
            SizedBox(height: 12),
            Text('除局域网内的设备发现与传输外，本应用不发起任何外部网络请求：'
                '没有统计上报，也没有广告。'),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
