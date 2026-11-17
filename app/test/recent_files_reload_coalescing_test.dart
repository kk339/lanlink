/// **80 arrivals must not cause 80 whole-database reads** (0.2.50).
///
/// The second half of the 卡顿 report. `RecentFilesController` used to listen to
/// the repository with `events.listen((_) => unawaited(load()))`, and every
/// [load] walks **the entire database**:
///
/// ```
/// conversations(includeArchived: true)
///   → history(conversation) for each
///     → filesOf(message) for each message
///       → one platform.exists per distinct path
/// ```
///
/// A multi-select send pushes one `MessageAdded` per file, so an 80-file batch
/// was 80 of those sweeps — for a page that is not even visible: the controller
/// is built with the shell (`shell_page.dart`) and survives every module switch,
/// so on the 会话 screen it was reading the whole database for nobody.
///
/// The fix is a **coalescing window**: the first event arms a 250 ms timer, the
/// rest of the burst is absorbed by it. These tests count `load` calls (the
/// judge) rather than wall-clock time (which on this machine swings by 2× and is
/// therefore not a judge at all).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/recent_files_controller.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/selectors.dart';

import 'support/fakes.dart';

const String _fp = 'C0DE';
const String _conv = 'c-recent';

/// A [RecentFilesController] that counts how many times it actually loaded.
///
/// This is the number the user pays for: each [load] is a full database read.
class _CountingController extends RecentFilesController {
  _CountingController({
    required super.repo,
    required super.platform,
  });

  int loads = 0;

  @override
  Future<void> load() {
    loads++;
    return super.load();
  }
}

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fp,
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// One conversation with one already-received file, plus a controller watching
/// the same repository.
///
/// The controller's own [RecentFilesController.load] (the shell's startup call)
/// is counted from zero: everything measured below is event-driven.
class _Harness {
  _Harness(this.backend, this.repo, this.controller);

  final FakeBackend backend;
  final FakeSessionRepository repo;
  final _CountingController controller;

  /// Delivers one incoming file, exactly as the receiver does on arrival — one
  /// `MessageAdded` event per file, which is what the batch was paying for.
  void arriveFile(int i) {
    repo.recordIncoming(
      sender: _peer(),
      file: IncomingFile(
        fileId: 'batch-$i',
        fileName: 'file-$i.bin',
        size: 1024,
        sha256: 'AA',
        savedPath: 'C:\\incoming\\file-$i.bin',
      ),
    );
  }
}

Future<_Harness> _harness() async {
  final FakeBackend backend = FakeBackend();
  final FakeSessionRepository repo = backend.repo;
  repo.addConversation(
    id: _conv,
    deviceFingerprint: _fp,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  // One landed file, so `load()` has real work to do and the aggregation is not
  // trivially empty.
  repo.recordIncoming(
    sender: _peer(),
    file: const IncomingFile(
      fileId: 'seed-1',
      fileName: 'seed.bin',
      size: 1024,
      sha256: 'AA',
      savedPath: r'C:\incoming\seed.bin',
    ),
  );

  final _CountingController controller = _CountingController(
    repo: repo,
    platform: backend.platform,
  );
  await controller.load();
  controller.loads = 0;
  return _Harness(backend, repo, controller);
}

void main() {
  // ── criterion 2: one burst of 80 events costs one reload ───────────────────
  testWidgets('★ criterion 2: 80 repository events in one burst → exactly 1 load',
      (WidgetTester tester) async {
    final _Harness h = await _harness();
    // `dispose` cancels the pending timer — called explicitly at the end of the
    // body rather than in a tearDown, because `flutter_test` checks for leftover
    // timers *before* tear-downs run.
    addTearDown(h.backend.dispose);

    for (int i = 0; i < 80; i++) {
      h.arriveFile(i);
    }
    // The events are delivered on the microtask queue; the coalescing window has
    // not elapsed yet, so nothing has loaded.
    await tester.pump();
    expect(h.controller.loads, 0,
        reason: 'the window is what makes the burst cheap — loading on the '
            'first event would be 1 of 80 again');

    await tester.pump(const Duration(milliseconds: 300));
    expect(h.controller.loads, 1,
        reason: '80 events → **one** whole-database read. Before the fix this '
            'was 80, and each read walked every conversation, every message, '
            'every attachment and stat\'ed every distinct path');

    // …and the one load actually saw the batch: coalescing must delay the read,
    // not drop it.
    final List<RecentFileItem> items = h.controller.all.valueOrNull!;
    expect(items.length, greaterThanOrEqualTo(80),
        reason: 'the page still ends up showing the arrived files');

    h.controller.dispose();
  });

  // ── criterion 2b: a sustained stream is bounded, never starved ─────────────
  testWidgets(
      '★ criterion 2b: 80 events at 10 ms spacing (≈0.8 s) cost ≤ 4 loads — the '
      'page stays live during a long arrival', (WidgetTester tester) async {
    final _Harness h = await _harness();
    addTearDown(h.backend.dispose);

    for (int i = 0; i < 80; i++) {
      h.arriveFile(i);
      // 10 ms per arrival: a fast LAN delivering 80 small files over ~0.8 s.
      await tester.pump(const Duration(milliseconds: 10));
    }
    // Let the last window expire so no load is left pending.
    await tester.pump(const Duration(milliseconds: 300));

    // ignore: avoid_print
    print('COALESCING: 80 events over 0.8 s → ${h.controller.loads} loads '
        '(before the fix: 80)');

    expect(h.controller.loads, lessThanOrEqualTo(4),
        reason: '0.8 s / 250 ms ≈ 3 windows, so at most 4 loads; a restarting '
            'tail timer would give **0** here, which is the starvation this '
            'window shape avoids');
    expect(h.controller.loads, greaterThanOrEqualTo(2),
        reason: 'and it must not be zero: a sustained stream has to refresh, '
            'otherwise the page is frozen for the length of the transfer');

    h.controller.dispose();
  });

  // ── the window must not outlive the controller ─────────────────────────────
  testWidgets('★ dispose cancels the pending coalesced reload',
      (WidgetTester tester) async {
    final _Harness h = await _harness();
    addTearDown(h.backend.dispose);

    h.arriveFile(0);
    await tester.pump();
    h.controller.dispose();
    await tester.pump(const Duration(milliseconds: 300));

    expect(h.controller.loads, 0,
        reason: 'a disposed controller must not read the database afterwards — '
            'the shell disposes it when the page goes away');
  });
}
