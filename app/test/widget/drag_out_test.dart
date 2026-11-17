/// Widget tests for **dragging a file out of the app** (0.2.45).
///
/// What can be asserted here, and what cannot:
///  * **Here:** the gesture reaches the platform port exactly once, with the real
///    `localPath`s; nothing is started when a file is gone; a folder message hands
///    over every file that is still there and skips the ones that are not; a
///    `move` answer is a failure, not a success; and a path that disappeared during
///    the drag leaves the attachment in the existing 「源文件不可用」 state.
///  * **Not here:** that the file really lands on the desktop. That answer comes
///    from Explorer, through `DoDragDrop`, which no unit test can run. The runner
///    logs it (`LANLINK_DRAG_OUT_LOG=1`) and `docs` describe the manual steps.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/drag_out.dart';
import 'package:lanlink_app/domain/models.dart';
// `RightTab.label` — the tab names the user reads (`RightTabUi`).
import 'package:lanlink_app/ui/shell/shell_module.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _conversationId = 'c-drag';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'DD01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// One attachment with a real-looking absolute [path].
FileAttachment _file(
  String id,
  String name,
  String path, {
  String messageId = 'm-drag',
}) =>
    FileAttachment(
      id: id,
      messageId: messageId,
      fileName: name,
      size: 2048,
      sha256: 'AA',
      localPath: path,
    );

/// Mounts the desktop shell on a conversation holding [files] in one message.
///
/// [folder] non-null makes it a **folder message** (one card, N attachments);
/// [supportsDragOut] defaults to `true` because every test here but one is about
/// the gesture that only exists when the platform offers it.
Future<FakeBackend> _pump(
  WidgetTester tester, {
  required List<FileAttachment> files,
  String? folder,
  int folderFiles = 0,
  bool supportsDragOut = true,
  MessageDirection direction = MessageDirection.incoming,
  MessageStatus status = MessageStatus.done,
}) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setSupportsDragOut(supportsDragOut);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'DD01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-drag',
    conversationId: _conversationId,
    direction: direction,
    status: status,
    kind: MessageKind.file,
    folderName: folder,
    folderFiles: folderFiles,
    files: files,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  await pumpShell(
    tester,
    backend: backend,
    settle: true,
    initialPeer: _peer(),
  );
  return backend;
}

/// Presses [target] with a **mouse** and moves by [delta], then lets the test see
/// what the app did.
///
/// The pointer kind is not incidental. Drag-out exists on Windows only and is done
/// with a mouse, and Flutter's slop for a precise pointer (2 dp) is a different
/// number from a finger's (18 dp) — a test that pressed with a finger would be
/// measuring a gesture no Windows user makes (and would lose the arena to the
/// timeline's scroll drag, which is exactly what happens on a touch screen and is
/// the documented non-goal here).
///
/// The gesture is left **down** on purpose: a real drag is still running while the
/// platform reports nothing, and `pumpAndSettle` with a button held is the state
/// that catches a "fires twice" bug.
Future<TestGesture> _drag(
  WidgetTester tester,
  Finder target, {
  Offset delta = const Offset(0, 40),
}) async {
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  // In steps, like a real mouse: a drag is a stream of small moves, and one
  // synthetic jump would skip the moment the threshold is crossed.
  const int steps = 4;
  for (int step = 0; step < steps; step += 1) {
    await gesture.moveBy(delta / steps.toDouble());
    await tester.pump();
  }
  // Two more pumps: the first flushes the gesture → callback, the second the
  // port's answer and the re-check that follows it.
  await tester.pump();
  await tester.pump();
  return gesture;
}

/// The [DragOutException] the copy-only contract produces for `move`.
///
/// Built through the **real** parser rather than spelled out, so the widget test
/// and the contract test cannot drift into asserting different sentences.
DragOutException _moveFailure() {
  try {
    parseDragOutEffect(kDragOutMove);
  } on DragOutException catch (error) {
    return error;
  }
  fail('parseDragOutEffect("move") must throw');
}

void main() {
  testWidgets(
      'press + move past the threshold starts ONE drag with the real localPath',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );

    final TestGesture gesture =
        await _drag(tester, find.text('a.bin'));

    expect(backend.platform.dragOutRequests, hasLength(1));
    expect(
      backend.platform.dragOutRequests.single,
      <String>[r'C:\received\a.bin'],
      reason: 'the payload must be the file’s real path — not its id, not a '
          'relative name',
    );

    // Still holding the button: no second drag may start (DoDragDrop is modal).
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(backend.platform.dragOutRequests, hasLength(1));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a press that never moves is not a drag (still a click)',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );

    // Below [kDragOutSlop]: a click's tremor, not a drag.
    final TestGesture gesture =
        await _drag(tester, find.text('a.bin'), delta: const Offset(0, 4));
    expect(backend.platform.dragOutRequests, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'a source file that is no longer on disk starts NO drag and says why',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      files: <FileAttachment>[
        _file('f-1', 'gone.bin', r'C:\received\gone.bin'),
      ],
    );
    backend.platform.setExists(r'C:\received\gone.bin', false);

    final TestGesture gesture = await _drag(tester, find.text('gone.bin'));

    expect(
      backend.platform.dragOutRequests,
      isEmpty,
      reason: 'a drag that cannot move anything must not be started at all',
    );
    expect(find.text('源文件已不在本地，无法拖出'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'a folder message hands over every file that still exists — and only those',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      folder: '素材',
      folderFiles: 3,
      files: <FileAttachment>[
        _file('f-1', 'one.bin', r'C:\received\one.bin'),
        _file('f-2', 'two.bin', r'C:\received\two.bin'),
        _file('f-3', 'three.bin', r'C:\received\three.bin'),
      ],
    );
    // The middle one was deleted after it landed.
    backend.platform.setExists(r'C:\received\two.bin', false);

    final TestGesture gesture = await _drag(tester, find.text('素材'));

    expect(backend.platform.dragOutRequests, hasLength(1));
    expect(
      backend.platform.dragOutRequests.single,
      <String>[r'C:\received\one.bin', r'C:\received\three.bin'],
      reason: '3 declared, 2 present → exactly those 2 real paths',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a `move` answer is a FAILURE, never a silent success',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );
    backend.platform.failDragOutWith(_moveFailure());

    final TestGesture gesture = await _drag(tester, find.text('a.bin'));

    expect(backend.platform.dragOutRequests, hasLength(1));
    expect(find.textContaining('拖出失败'), findsOneWidget);
    expect(find.textContaining('只允许复制'), findsOneWidget);
    // The file is still there, so nothing is marked unavailable — the failure is
    // the contract, not the disk.
    expect(find.text('源文件不可用'), findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'a path that vanished during the drag leaves the attachment in the '
      'existing 源文件不可用 state', (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );
    // The target moved it out from under us: the file is gone by the time the
    // drag loop returns (recorded inside `startDrag`, i.e. before it answers).
    backend.platform.onStartDrag = () =>
        backend.platform.setExists(r'C:\received\a.bin', false);

    final TestGesture gesture = await _drag(tester, find.text('a.bin'));

    expect(backend.platform.dragOutRequests, hasLength(1));
    expect(find.text('源文件不可用'), findsWidgets);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a successful copy is silent — no notice at all',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );

    final TestGesture gesture = await _drag(tester, find.text('a.bin'));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(backend.platform.dragOutRequests, hasLength(1));
    expect(find.textContaining('拖出'), findsNothing);
    expect(find.text('源文件不可用'), findsNothing);
  });

  testWidgets('a cancelled drag (Esc / drop on nothing) is silent too',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );
    backend.platform.setDragOutEffect(DragOutEffect.canceled);

    final TestGesture gesture = await _drag(tester, find.text('a.bin'));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(backend.platform.dragOutRequests, hasLength(1));
    expect(find.textContaining('拖出'), findsNothing);
  });

  testWidgets(
      'where the platform cannot drag out, the row has no such gesture at all',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      supportsDragOut: false,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );

    final TestGesture gesture =
        await _drag(tester, find.text('a.bin'), delta: const Offset(0, 60));

    expect(
      backend.platform.dragOutRequests,
      isEmpty,
      reason: 'a phone / Web build must not mount a drag that cannot work',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
      '★ 0.2.48 criterion 3: the 源文件不可用 mark survives leaving and re-entering '
      'the thread (it used to be a `State` field)', (WidgetTester tester) async {
    final FakeBackend backend = await _pump(
      tester,
      // An **outgoing** `done` message: the shape the defect was reported on. The
      // old probe only asked about `failed` / `canceled` messages, so nothing
      // would have re-read this row — and the drag mark lived in the thread's
      // `State`, which `DetailPane` throws away on every tab switch.
      direction: MessageDirection.outgoing,
      files: <FileAttachment>[
        _file('f-1', 'a.bin', r'C:\received\a.bin'),
      ],
    );
    backend.platform.onStartDrag = () =>
        backend.platform.setExists(r'C:\received\a.bin', false);

    final TestGesture gesture = await _drag(tester, find.text('a.bin'));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('源文件不可用'), findsWidgets);
    // 0.2.49: 这条用例的本职是"标记扛过切 tab"；它原先顺手断言了"灰按钮存在"，
    // 但 done 行的重发永远不可用（`canResend` 只认 failed/canceled），那是假控件。
    // 断言改成"没有按钮"——标记仍然要报（上面那行），按钮不再画。
    expect(find.widgetWithText(TextButton, '重新发送'), findsNothing,
        reason: 'a `done` row can never be re-sent, so it must offer no button');

    // Leave the timeline and come back — the tab switch re-creates the thread,
    // so this is exactly the sequence that used to lose the flag.
    await tester.tap(find.text(RightTab.files.label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(RightTab.messages.label));
    await tester.pumpAndSettle();

    expect(find.text('源文件不可用'), findsWidgets,
        reason: 'the mark is a fact about the disk, not about one `State`');
    expect(find.widgetWithText(TextButton, '重新发送'), findsNothing,
        reason: 'and it is still not offered after the re-entry');
  });
}
