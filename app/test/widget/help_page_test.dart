/// Widget tests for the 「使用帮助」 page (**new in 0.2.21**).
///
/// The page is the six-step 使用简介 **moved out of the 关于 page** (0.2.21) and
/// **re-voiced** later at the user's request (「你写的正常一点，现在看着感觉像是
/// 跟我聊天」) — content kept, argumentative phrasing dropped. So these assertions
/// are deliberately about **content identity, not shape**: each step is matched by
/// its **exact full string** (title and body). That is the only form of assertion
/// that can catch the failure this copy invites — someone "polishing" a sentence,
/// losing a `\n` and letting two lines merge, or sliding back into the second
/// person and the self-defending tone the user objected to. `docs/16` §2 is the
/// source; if the copy legitimately changes, the doc changes first and this file
/// follows.
///
/// The surface is very tall so that all six steps are laid out: a `ListView` does
/// not build children outside the viewport, and a "missing" step would then be a
/// measurement artefact rather than a finding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/ui/help_page.dart';
import 'package:lanlink_app/ui/theme.dart';

import '../support/pump_app.dart';

/// Step titles, in order (docs/16 §2 ①–⑥).
///
/// **None of these is a question** — 0.2.21's ③ read 「收不到？先看…」, which made
/// the page open with the reader's failure before it had explained anything. The
/// last test pins that property directly (no `？` anywhere in a title) so a future
/// rewrite cannot quietly reintroduce it.
const List<String> _titles = <String>[
  '让两台设备处于同一局域网',
  '首次发送需对方确认',
  '接收开关与常驻通知',
  '收到的文件位置',
  '日志位置',
  '传输速度',
];

/// Step bodies, **verbatim** — a space, a `\n`, a `·`, or the en dash in `2–3`
/// differing by one character means the copy drifted.
const List<String> _bodies = <String>[
  '连接同一个 WiFi 即可。没有路由器时，可让其中一台开启热点，另一台连接该热点。',
  '选择文件与目标设备后，发送方进入等待确认状态；对方点击「接受」后开始传输。'
      '对方开启自动接收时不再询问。',
  '接收开关关闭时，其他设备发来的文件会被直接拒绝，对方看到「被拒绝」。'
      '该开关保存上次的状态。\n'
      '手机端会常驻一条通知，用于保持息屏或切到后台后不掉线；该通知与传输进度无关。'
      '通知未显示时，请检查通知权限（Android 13 及以上需允许通知）。',
  '默认接收位置如下，可在「设置」中修改：\n'
      '· Windows：%LOCALAPPDATA%\\lanlink\\received\n'
      '· 手机：Download/lanlink（文件管理器和相册可见）',
  '日志文件为 lanlink.log，第一行记录日志自身的完整路径。\n'
      '手机端另存一份到 /Android/data/<包名>/files/lanlink.log，'
      '可通过文件管理器或 USB 取出。',
  '速度由链路决定：网线 > 5GHz WiFi > 2.4GHz WiFi。'
      '出现 2–3 MB/s 通常表示连接在 2.4GHz 或信号较弱；'
      '切换至 5GHz 或使用网线可明显提升。',
];

void main() {
  /// Mounts [HelpPage] alone: it is a leaf page with no deps, so the honest mount
  /// is a `MaterialApp` with the app's real theme.
  Future<void> pumpHelp(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 1800));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        home: const HelpPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('使用帮助: the AppBar carries the title and the page is reachable '
      'as its own page', (WidgetTester tester) async {
    await pumpHelp(tester);

    expect(find.byType(HelpPage), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('使用帮助')),
      findsOneWidget,
      reason: 'the title says where the steps live now',
    );
    // The steps are NOT under a 使用简介 heading any more — the page IS the help.
    expect(find.text('使用简介'), findsNothing);
  });

  testWidgets('使用帮助: all six steps are present, title AND body verbatim',
      (WidgetTester tester) async {
    await pumpHelp(tester);

    expect(_titles.length, 6);
    expect(_bodies.length, 6);

    for (int i = 0; i < _titles.length; i++) {
      expect(find.text(_titles[i]), findsOneWidget,
          reason: 'step ${i + 1} title: 「${_titles[i]}」');
      // ★ The full-string match is the anti-drift assertion: a re-worded or
      // re-wrapped body (a lost `\n`, a dropped 「」) fails here.
      expect(find.text(_bodies[i]), findsOneWidget,
          reason: 'step ${i + 1} body must be byte-identical to docs/16 §2');
      // The number itself is painted (the circle), so the order is visible.
      expect(find.text('${i + 1}'), findsOneWidget,
          reason: 'step ${i + 1} carries its index');
    }
  });

  testWidgets('使用帮助: the six steps keep their order top to bottom',
      (WidgetTester tester) async {
    // docs/16 §2 is ordered by "what you do first"; a re-sort would read as a
    // different procedure. Comparing `dx`/`dy` is the cheap way to pin it.
    await pumpHelp(tester);

    double previous = -1;
    for (final String title in _titles) {
      final double top = tester.getRect(find.text(title)).top;
      expect(top, greaterThan(previous),
          reason: '「$title」 must sit below the step before it');
      previous = top;
    }
  });

  testWidgets('★ 使用帮助: no title is a question and no body argues with the '
      'reader', (WidgetTester tester) async {
    // The user's complaint, expressed as a test: 「现在看着感觉像是跟我聊天」.
    // A question-mark title opens with the reader's problem before explaining
    // anything, and a body that defends the software instead of telling them what
    // to do reads as an argument. Both are cheap to reintroduce and impossible to
    // see in a diff that "reads fine", so they are pinned.
    await pumpHelp(tester);

    for (final String title in _titles) {
      expect(title.contains('？'), isFalse,
          reason: '「$title」 is a question — a manual states, it does not ask');
      expect(title.contains('?'), isFalse,
          reason: '「$title」 is a question (ASCII) — see above');
      expect(find.text(title), findsOneWidget, reason: '「$title」 is rendered');
    }

    // ★ The retired phrases are assembled from adjacent literals **on purpose**:
    // the assertion has to compare the rendered strings, but a repository-wide
    // grep for the old copy should stay at zero hits (docs/16 §3), and writing
    // these out here would be the one place they survive.
    for (final String phrase in <String>[
      '不是' ' bug', // "not a bug" — the software explaining itself
      '不是' '广告', // "not an ad"
      '不用' '问别人', // "no need to ask anyone"
      '应用' '自己的目录', // the retired phone folder wording
    ]) {
      expect(find.textContaining(phrase), findsNothing,
          reason: '「$phrase」 is self-defence, not instruction');
    }
  });

  testWidgets('使用帮助: the facts a user is told to look for are really there — '
      'the receive switch, the notification, the default folder, the log file, '
      'the link ladder', (WidgetTester tester) async {
    // Keyword-level checks (the step-by-step verbatim match above is the strict
    // one). These exist because each keyword is the actionable bit of its step: if
    // a future rewrite drops one, the step stops being usable even if it still
    // reads nicely.
    await pumpHelp(tester);

    for (final String keyword in <String>[
      '接收开关',
      '常驻通知',
      'Android 13',
      // 0.2.19 moved Android's received files here; until this revision the page
      // still sent the user to the private app directory, where nothing lands.
      'Download/lanlink',
      r'%LOCALAPPDATA%\lanlink\received',
      'lanlink.log',
      '/Android/data/<包名>/files/lanlink.log',
      '网线 > 5GHz WiFi > 2.4GHz WiFi',
      '2–3 MB/s',
    ]) {
      expect(find.textContaining(keyword), findsWidgets,
          reason: 'the help page must still tell the user about 「$keyword」');
    }
  });
}
