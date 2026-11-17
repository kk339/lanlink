/// **The Windows runner's minimum window size** (`docs/21-剩余工作.md` §2.7 P3).
///
/// The note on P3 says the three-pane shell can be dragged narrow enough that a
/// `RenderFlex` overflows by 3.4 px. Changing the layout to fix that is the
/// wrong move — the layout is right at every width it is *meant* to serve; what
/// is wrong is that Windows lets the window reach a width the layout was never
/// designed for. So the fix lives in the runner: `windows/runner/win32_window.cpp`
/// answers `WM_GETMINMAXINFO` with a `ptMinTrackSize` of **784 x 480** logical
/// pixels (`kMinimumContentWidth` / `kMinimumContentHeight`).
///
/// **Where those two numbers come from** (measured, not chosen — the whole
/// sweep is described in the comment above the constants):
///
/// * width — no client width overflows at all (swept 1280 → 704 in 1 px steps on
///   the real window, and 1400 → 380 in widget tests across 13 states, DPR
///   1.25–2.0 and text scale 1.15–1.5). What the width has is a **design floor**:
///   below `kNarrowBreakpoint` (760) the shell stops being three panes and
///   becomes the two-level phone shell. 760 + 24 = 784 (already a multiple of 8).
/// * height — a real boundary: 316 is the shortest client height that lays out
///   clean, 315 overflows the rail by exactly 1 px. Reproduced identically on the
///   real window (at 1280 and at 784 wide) and here. 316 + 24 = 340, and 344
///   would be the bare 8-aligned floor, but the thread then shows ~1.5 bubbles,
///   so the shipped number is 480.
///
/// This file is the Dart half of that contract: the numbers are read **out of
/// the C++ source** (so drifts are caught even before a window is shown), and
/// the layout is then mounted **at exactly those numbers** to prove nothing
/// overflows there.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/shell/detail_pane.dart';
import 'package:lanlink_app/ui/shell/list_pane.dart';
import 'package:lanlink_app/ui/shell/nav_rail.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// The runner source the minimum lives in, relative to the package root.
const String _runnerSource = 'windows/runner/win32_window.cpp';

/// The measured height boundary: `316` lays out clean, `315` overflows the rail
/// by 1 px (real window *and* widget test — the agreeing numbers are what make
/// it trustworthy).
const double kMeasuredCleanHeight = 316;

/// The initial window is 1280 x 720 *physical*, i.e. 1264 x 681 of client area at
/// 96 dpi (measured with `GetClientRect` on the running runner). The minimum may
/// never exceed it, or the app could not open at its own initial size.
const Size kInitialClientArea = Size(1264, 681);

/// Reads `kMinimumContentWidth` / `kMinimumContentHeight` out of the runner.
({double width, double height}) readRunnerMinimum() {
  final File file = File(_runnerSource);
  expect(file.existsSync(), isTrue,
      reason: 'run this test from the package root ($_runnerSource missing)');
  final String source = file.readAsStringSync();

  double valueOf(String name) {
    final RegExpMatch? match =
        RegExp('constexpr int $name = (\\d+);').firstMatch(source);
    expect(match, isNotNull,
        reason: 'the runner must declare `constexpr int $name = <number>;`');
    return double.parse(match!.group(1)!);
  }

  return (width: valueOf('kMinimumContentWidth'),
      height: valueOf('kMinimumContentHeight'));
}

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A backend with one conversation and three text messages — a *real*
/// conversation, because the three panes only mean anything with one open.
FakeBackend _seededBackend() {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c-min',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  for (int i = 0; i < 3; i++) {
    backend.repo.addMessage(
      id: 'm-$i',
      conversationId: 'c-min',
      direction: i.isEven ? MessageDirection.incoming : MessageDirection.outgoing,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '第 $i 条消息，用来把三栏撑满之后仍然不溢出。',
      createdAt: fixedEpoch.add(Duration(minutes: i)),
      updatedAt: fixedEpoch.add(Duration(minutes: i)),
    );
  }
  return backend;
}

void main() {
  testWidgets(
      'at the runner minimum the three panes are all there and nothing '
      'overflows', (WidgetTester tester) async {
    final ({double width, double height}) minimum = readRunnerMinimum();
    useSurfaceSize(tester, Size(minimum.width, minimum.height));
    final FakeBackend backend = _seededBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(false);
    await pumpShell(tester, backend: backend, settle: true, initialPeer: _peer());

    // 1. No RenderFlex overflow anywhere — an unconsumed overflow would fail this
    //    test on its own, and the explicit assertion names the size that broke.
    expect(tester.takeException(), isNull,
        reason: 'the window minimum must be a size the layout survives '
            '(${minimum.width} x ${minimum.height})');

    // 2. The three panes the P3 note is about are all mounted: rail, list,
    //    conversation.
    expect(find.byType(NavRail), findsOneWidget,
        reason: 'the navigation rail is the first column');
    expect(find.byType(ListPane), findsOneWidget,
        reason: 'the middle column');
    expect(find.byType(DetailPane), findsOneWidget,
        reason: 'the right column');
    expect(find.byType(ConversationThread), findsOneWidget,
        reason: 'the right column really is a conversation, not its empty state');

    // 3. And the conversation column still has a usable width: it takes what the
    //    collapsed rail (64), the two seams (8 + 8) and the compact list (280)
    //    leave over, which at 784 is 424 — above the design's kDetailMinWidth.
    final double detail = tester.getSize(find.byType(DetailPane)).width;
    expect(detail, minimum.width - kRailCollapsedWidth - 2 * kPaneSeam -
        kListWidthCompact);
    expect(detail, greaterThan(kDetailMinWidth),
        reason: 'a minimum that leaves the conversation narrower than the '
            'design floor is not a minimum, it is a squeeze');
  });

  testWidgets(
      'one pixel below the measured height boundary the rail still breaks — '
      'which is why the minimum is not smaller', (WidgetTester tester) async {
    // A boundary pin, on purpose: it is the evidence the height number was
    // measured instead of guessed. If this ever goes green, the layout below
    // 316 changed and kMinimumContentHeight should be re-measured (it may be
    // small enough to lower).
    useSurfaceSize(tester, const Size(784, kMeasuredCleanHeight - 1));
    final FakeBackend backend = _seededBackend();
    addTearDown(backend.dispose);
    backend.platform.setMobile(false);
    await pumpShell(tester, backend: backend, settle: true, initialPeer: _peer());

    expect(tester.takeException(), isNotNull,
        reason: 'at ${kMeasuredCleanHeight - 1} the rail overflows by 1 px; if '
            'this is now clean, the boundary moved and the minimum should be '
            're-measured rather than left at 480');
  });

  test('the runner minimum is 8-aligned, above the layout floor, and below the '
      'initial window', () {
    final ({double width, double height}) minimum = readRunnerMinimum();

    // The width floor: below this the shell is not three panes any more, so a
    // minimum smaller than it would let the window reach a layout the note is
    // not about.
    expect(minimum.width, greaterThanOrEqualTo(kNarrowBreakpoint),
        reason: 'below kNarrowBreakpoint the shell degrades to the two-level '
            'phone shell — there are no three panes left to protect');
    // The measured height floor.
    expect(minimum.height, greaterThan(kMeasuredCleanHeight),
        reason: 'the minimum must leave headroom above the measured boundary');
    // Deliberate 8 px grading, so the numbers look chosen and stay round.
    expect(minimum.width % 8, 0);
    expect(minimum.height % 8, 0);
    // …and a minimum larger than the initial window would be a bug of its own:
    // the app opens at 1264 x 681, so a bigger floor could not be honoured.
    expect(minimum.width, lessThan(kInitialClientArea.width));
    expect(minimum.height, lessThan(kInitialClientArea.height));
  });
}
