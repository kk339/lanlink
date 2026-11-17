/// Widget tests for the bubble's `剩 N 秒` line (0.2.25).
///
/// What is asserted, and why each one can fail:
///
/// * a steady 10 MiB/s with 100 MiB left prints `剩 10 秒` — the whole point of
///   the feature, and the number a wrong unit / wrong divisor breaks;
/// * under 2 s of history the bubble shows **no** `剩` at all (a 1 s window
///   projects noise);
/// * a **stalled** link shows nothing either — not `剩 ∞`, not a number that
///   climbs every tick;
/// * the line is present **only** while `transferring`: `pending` /
///   `awaitingConfirm` / `done` / `failed` / `canceled` must all be clean, so an
///   implementation that simply leaves the last text in place is red;
/// * the styling contract (same row as the percentage, `bodySmall`,
///   `onSurfaceVariant`) and the 320 dp layout: no overflow, and the file name —
///   which lives on its own row — still has room.
///
/// Time comes from a [FixedClock] the test advances, never from a real clock or
/// a `sleep`: the bubble reads its clock once per build and hands the instant to
/// the pure estimator, so 10 s of transfer is 10 pumps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/clock.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/remaining_time.dart';
import 'package:lanlink_app/ui/format.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const int _mib = 1024 * 1024;

/// One outgoing file message, the shape progress attaches to.
ChatMessage _message({MessageStatus status = MessageStatus.transferring}) =>
    ChatMessage(
      id: 'm-eta',
      conversationId: 'c-eta',
      direction: MessageDirection.outgoing,
      kind: MessageKind.file,
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      status: status,
    );

FileAttachment _file(String name, int size) => FileAttachment(
      id: 'f-eta',
      messageId: 'm-eta',
      fileName: name,
      size: size,
      sha256: '00',
      localPath: '/src/$name',
    );

MessageBubble _bubble({
  required TransferProgress progress,
  required Clock clock,
  MessageStatus status = MessageStatus.transferring,
  String fileName = 'big.iso',
  bool isMobile = false,
}) =>
    MessageBubble(
      message: _message(status: status),
      files: <FileAttachment>[_file(fileName, progress.bytesTotal)],
      progress: progress,
      clock: clock,
      isMobile: isMobile,
    );

/// Mounts/replaces [bubble] under the same [backend] so the element tree — and
/// therefore the progress bar's `State`, which holds the sample history — is
/// **reused** across pumps, exactly as it is when the controller pushes a new
/// progress value into a live bubble.
Future<void> _pump(
  WidgetTester tester,
  FakeBackend backend,
  Widget bubble,
) async {
  await tester.pumpWidget(
    appWithScope(child: Scaffold(body: bubble), deps: testDeps(backend)),
  );
  await tester.pump();
}

/// The one rendered `剩 …` text, or `null`.
String? _etaText(WidgetTester tester) {
  final Finder finder = find.textContaining('剩 ');
  if (finder.evaluate().isEmpty) {
    return null;
  }
  expect(finder, findsOneWidget, reason: 'exactly one ETA line per bubble');
  return tester.widget<Text>(finder).data;
}

/// Drives [ticks] one-second progress updates at [bytesPerTick] from [from].
///
/// Returns the clock it used, so a caller can continue the same history.
Future<FixedClock> _drive(
  WidgetTester tester,
  FakeBackend backend, {
  required int from,
  required int bytesPerTick,
  required int total,
  int ticks = 10,
  MessageStatus status = MessageStatus.transferring,
  String fileName = 'big.iso',
  bool isMobile = false,
  FixedClock? clock,
}) async {
  final FixedClock time = clock ?? FixedClock(DateTime.utc(2026, 1, 7, 12));
  for (int i = 0; i <= ticks; i++) {
    await _pump(
      tester,
      backend,
      _bubble(
        progress: TransferProgress(
          fileId: 'f-eta',
          bytesDone: from + bytesPerTick * i,
          bytesTotal: total,
        ),
        clock: time,
        status: status,
        fileName: fileName,
        isMobile: isMobile,
      ),
    );
    if (i < ticks) {
      time.advance(const Duration(seconds: 1));
    }
  }
  return time;
}

void main() {
  testWidgets(
      'steady 10 MiB/s with 100 MiB left reads 剩 10 秒, beside the percentage',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    // 10 s at 10 MiB/s, file of 200 MiB → 100 MiB left, so ~10 s.
    await _drive(
      tester,
      backend,
      from: 0,
      bytesPerTick: 10 * _mib,
      total: 200 * _mib,
    );

    final Finder etaFinder = find.textContaining('剩 ');
    expect(etaFinder, findsOneWidget);
    final Text eta = tester.widget<Text>(etaFinder);
    expect(eta.data, anyOf('剩 9 秒', '剩 10 秒', '剩 11 秒'),
        reason: 'remaining / window rate, ±1 s for the smoothing lag');

    // Same row as the byte/percentage label, same size, muted colour.
    final Finder labelFinder = find.textContaining('· 50%');
    expect(labelFinder, findsOneWidget);
    expect(
      tester.getTopLeft(etaFinder).dy,
      closeTo(tester.getTopLeft(labelFinder).dy, 0.5),
      reason: 'the ETA is a remark on the numbers, not a new block',
    );
    expect(eta.style?.fontSize, tester.widget<Text>(labelFinder).style?.fontSize);
    final BuildContext context = tester.element(etaFinder);
    expect(eta.style?.color, Theme.of(context).colorScheme.onSurfaceVariant);
  });

  testWidgets('under 2 s of history prints no 剩 at all — no noise estimate',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    final FixedClock clock = FixedClock(DateTime.utc(2026, 1, 7, 12));
    // Two samples, 1 s apart: the span is below kRemainingTimeMinSpan.
    await _pump(
      tester,
      backend,
      _bubble(
        progress: const TransferProgress(
          fileId: 'f-eta',
          bytesDone: 0,
          bytesTotal: 200 * _mib,
        ),
        clock: clock,
      ),
    );
    clock.advance(const Duration(seconds: 1));
    await _pump(
      tester,
      backend,
      _bubble(
        progress: const TransferProgress(
          fileId: 'f-eta',
          bytesDone: 10 * _mib,
          bytesTotal: 200 * _mib,
        ),
        clock: clock,
      ),
    );

    expect(find.textContaining('剩'), findsNothing);
    // The rest of the line is still there — the feature hides, it does not
    // break the progress display.
    expect(find.text('10 MB / 200 MB · 5%'), findsOneWidget);
  });

  testWidgets('a stalled transfer prints nothing (no 剩 ∞, no ever-growing '
      'number)', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    // Five seconds, zero bytes moved.
    await _drive(
      tester,
      backend,
      from: 40 * _mib,
      bytesPerTick: 0,
      total: 200 * _mib,
      ticks: 5,
    );

    expect(find.textContaining('剩'), findsNothing);
    expect(find.textContaining('∞'), findsNothing);
  });

  testWidgets(
      'the line is drawn ONLY while transferring: done / failed / canceled / '
      'pending / awaitingConfirm all show nothing', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    // Build a real history first, so the text exists and can only disappear
    // because of the status — not because nothing was ever measured.
    final FixedClock clock = await _drive(
      tester,
      backend,
      from: 0,
      bytesPerTick: 10 * _mib,
      total: 300 * _mib,
    );
    expect(_etaText(tester), isNotNull);

    for (final MessageStatus status in <MessageStatus>[
      MessageStatus.done,
      MessageStatus.failed,
      MessageStatus.canceled,
      MessageStatus.pending,
      MessageStatus.awaitingConfirm,
    ]) {
      await _pump(
        tester,
        backend,
        _bubble(
          progress: const TransferProgress(
            fileId: 'f-eta',
            bytesDone: 100 * _mib,
            bytesTotal: 300 * _mib,
          ),
          clock: clock,
          status: status,
        ),
      );
      expect(
        find.textContaining('剩'),
        findsNothing,
        reason: '${status.name} must not carry an ETA',
      );
    }

    // …and it comes back when the same bubble is transferring again — but only
    // after it has a window: the five non-transferring pumps disposed the
    // progress bar's State, so its sample history went with it (nothing polls a
    // finished bubble). Three more seconds of transfer rebuild a measurement,
    // which is exactly what a resumed transfer looks like on a real device.
    await _drive(
      tester,
      backend,
      from: 100 * _mib,
      bytesPerTick: 10 * _mib,
      total: 300 * _mib,
      ticks: 3,
      clock: clock,
    );
    expect(_etaText(tester), isNotNull);
  });

  testWidgets(
      '320 dp: the progress line wraps instead of overflowing, and the file name '
      'keeps its own row', (WidgetTester tester) async {
    // 320 logical px is the narrowest phone this app targets.
    useSurfaceSize(tester, const Size(320, 780));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    // A long, realistic ISO name plus an ETA long enough to be the worst case
    // (`剩 16 分 30 秒`): 1 MiB/s on a 1000 MiB file, 10 MiB in.
    await _drive(
      tester,
      backend,
      from: 0,
      bytesPerTick: 1 * _mib,
      total: 1000 * _mib,
      isMobile: true,
      fileName: 'ubuntu-24.04.1-desktop-amd64.iso',
    );

    // No RenderFlex / RenderBox overflow anywhere (Flutter reports one as an
    // exception, which `takeException` turns into a failure).
    expect(tester.takeException(), isNull);

    final String? eta = _etaText(tester);
    expect(eta, isNotNull);
    expect(eta, startsWith('剩 '), reason: 'the worst case is a minutes-long ETA');

    final Finder etaFinder = find.text(eta!);
    final Finder labelFinder = find.textContaining('·').first;
    final Finder nameFinder = find.text('ubuntu-24.04.1-desktop-amd64.iso');

    // The width the row is actually offered: the progress bar's own box, which
    // is the bubble's content box (cap − 2×12 px padding). Measuring the
    // `MessageBubble` itself would report the whole pane — `Align` fills it — so
    // the bar is the honest probe.
    final double contentWidth =
        tester.getSize(find.byType(LinearProgressIndicator)).width;
    final double cap = 320 * kBubbleMaxWidthFactor < kBubbleMaxWidthPx
        ? 320 * kBubbleMaxWidthFactor
        : kBubbleMaxWidthPx;
    expect(contentWidth, closeTo(cap - 24, 1.0),
        reason: 'the row is capped at 78% of the 320 dp pane, minus padding');

    final Size labelSize = tester.getSize(labelFinder);
    final Size etaSize = tester.getSize(etaFinder);
    final Size nameSize = tester.getSize(nameFinder);

    expect(labelSize.width, greaterThan(0));
    expect(etaSize.width, greaterThan(0));
    // The file name survives: it is a row of its own, so a wide progress line
    // can never squeeze it — that is the property under test, not a coincidence.
    expect(nameSize.width, greaterThan(0));
    expect(nameSize.height, greaterThan(0));
    // And the name is not clipped to nothing by the thumbnail row above it: a
    // 33-character name still gets real width (ellipsised inside it, per
    // FileTile, but not squeezed by the progress line, which lives lower).
    expect(nameSize.width, greaterThan(60),
        reason: 'the progress line cannot shrink the name row: they are '
            'siblings in a Column, each widthed by the bubble');

    // Geometric evidence for the report: one line means the two pieces share a
    // top; a wrap shows up as the ETA sitting a line lower.
    final double dyDelta =
        (tester.getTopLeft(etaFinder).dy - tester.getTopLeft(labelFinder).dy).abs();
    final bool sameLine = dyDelta < 1;

    // Either way the pair must fit **inside** the bubble: measured against the
    // content width, not against the window.
    expect(
      sameLine
          ? labelSize.width + 8 + etaSize.width
          : (labelSize.width <= contentWidth && etaSize.width <= contentWidth),
      isTrue,
      reason: 'sameLine=$sameLine label=${labelSize.width.toStringAsFixed(1)} '
          'eta=${etaSize.width.toStringAsFixed(1)} content='
          '${contentWidth.toStringAsFixed(1)}',
    );

    // Report the numbers the review asked for.
    // ignore: avoid_print
    print('320dp layout: content=${contentWidth.toStringAsFixed(1)} '
        'label=${labelSize.width.toStringAsFixed(1)} '
        'eta=${etaSize.width.toStringAsFixed(1)} ("$eta") '
        'sameLine=$sameLine dy=${dyDelta.toStringAsFixed(1)} '
        'nameRow=${nameSize.width.toStringAsFixed(1)}x'
        '${nameSize.height.toStringAsFixed(1)}');
  });

  testWidgets('the estimator the bubble feeds really is the 3 s window one',
      (WidgetTester tester) async {
    // Guards the wiring itself: with the default estimator constants the widget
    // must agree with the pure function on the same history. A bubble that
    // invented its own averaging (whole-run, or a fixed 1 s tick) disagrees.
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);

    const int bytesPerTick = 10 * _mib;
    const int total = 200 * _mib;
    final FixedClock time = await _drive(
      tester,
      backend,
      from: 0,
      bytesPerTick: bytesPerTick,
      total: total,
    );

    final DateTime start = DateTime.utc(2026, 1, 7, 12);
    final Duration? expected = estimateRemainingTime(
      <ProgressSample>[
        for (int i = 0; i <= 10; i++)
          ProgressSample(
            bytesDone: bytesPerTick * i,
            at: start.add(Duration(seconds: i)),
          ),
      ],
      bytesTotal: total,
    );
    expect(expected, isNotNull);
    expect(_etaText(tester), remainingTimeText(expected!));
    expect(kRemainingTimeWindow, const Duration(seconds: 3));
    expect(time.nowUtc(), start.add(const Duration(seconds: 10)));
  });
}
