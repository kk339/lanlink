/// **0.2.32 — a drag may cross bubbles, but it may not pick up the chrome.**
///
/// The user: *"复制的时候，比方说我从这个气泡复制到另一个，貌似会复制到气泡周围的
/// 重新发送啊，取消发送这些东西"*.
///
/// This is the direct consequence of 0.2.30 putting **one** `SelectionArea` above
/// the whole timeline: every `Text` under it became selectable, so a drag from one
/// message to the next swept up 「重新发送」「取消」「已完成」「复制」「失败」 —
/// the bubble's own buttons and chips — plus the time labels and the file cards.
///
/// The fix is Flutter's own mechanism, not a hand-rolled ignore: the non-body
/// subtrees are wrapped in `SelectionContainer.disabled`, which unregisters them
/// from the region's registrar. So they are not selectable, they never appear in
/// the copied text, and — because a disabled container inserts **no render
/// object** — no geometry moves.
///
/// What each case proves:
/// * **A** — the case the user reported: A's text → B's text. The copy holds the
///   two **bodies** and **nothing else**: no 重新发送/取消/已完成/复制/失败, and
///   (the strong form) no character that is not in one of the two bodies — which
///   also rules out the time label, the date separator and the file sizes;
/// * **B** — a drag that runs **down through the bubble's own button row** still
///   copies only the body (a drag *inside* one bubble is not exempt);
/// * **C** — a **file** bubble is not selectable at all: dragging across it picks
///   up no file name and no size.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/format.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// Two bodies built **only** from characters that no piece of chrome uses, so
/// case A's "not one foreign character" assertion is a real constraint and not
/// something the bodies happen to satisfy. (The forbidden vocabulary is
/// 重新发送 / 取消 / 已完成 / 复制 / 失败 / 今天 / 20:00 / 对方离线，排队等待上传 —
/// none of these characters appear below.)
const String _bodyA = '这是一段文字内容写在左边';
const String _bodyB = '另一段文字内容写在右边';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Text that must never reach the clipboard from a message row.
const List<String> _chromeWords = <String>[
  '重新发送',
  '取消',
  '已完成',
  '复制',
  '失败',
];

/// One message to seed.
///
/// A tiny local descriptor rather than a `ChatMessage`: attachments are the
/// repository's (`addMessage(files: …)`), not the model's, so a file message can
/// only be seeded through the repository call.
class _Msg {
  /// A text message.
  const _Msg.text(
    this.body, {
    this.outgoing = false,
    this.status = MessageStatus.done,
  })  : fileName = null,
        fileSize = 0;

  /// A file message — all chrome, no body.
  const _Msg.file(this.fileName, this.fileSize)
      : body = null,
        outgoing = true,
        status = MessageStatus.done;

  /// The body, or `null` for a file message.
  final String? body;
  final bool outgoing;
  final MessageStatus status;
  final String? fileName;
  final int fileSize;
}

/// Captures every `Clipboard.setData` payload while the test runs.
List<String> _captureClipboard() {
  final List<String> copied = <String>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform,
      (MethodCall call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
    }
    return null;
  });
  addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// `Ctrl+C` through the real shortcut stack — the same read-out of "what is
/// selected" that `desktop_mouse_selection_test.dart` established.
Future<void> _controlC(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// Drags with the **left** mouse button from [from] to [to] in three steps.
Future<void> _mouseDrag(WidgetTester tester, Offset from, Offset to) async {
  final TestGesture gesture =
      await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump();
  for (final double t in <double>[0.34, 0.67, 1.0]) {
    await gesture.moveTo(Offset.lerp(from, to, t)!);
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Mounts the **real desktop path** — `ShellPage` with `CC01` open — at
/// 1400×1000 with `isMobile: false`.
Future<void> _pumpDesktop(WidgetTester tester, FakeBackend backend) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  backend.platform.setMobile(false);
  await pumpShell(tester, backend: backend, settle: true, initialPeer: _peer());
}

/// A fresh backend whose conversation holds [specs], oldest first.
FakeBackend _seeded(List<_Msg> specs) {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c-sel',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  for (int i = 0; i < specs.length; i++) {
    final _Msg spec = specs[i];
    final bool isFile = spec.fileName != null;
    backend.repo.addMessage(
      id: 'm-$i',
      conversationId: 'c-sel',
      direction:
          spec.outgoing ? MessageDirection.outgoing : MessageDirection.incoming,
      status: spec.status,
      kind: isFile ? MessageKind.file : MessageKind.text,
      textBody: spec.body,
      files: isFile
          ? <FileAttachment>[
              FileAttachment(
                id: 'f-$i',
                messageId: 'm-$i',
                fileName: spec.fileName!,
                size: spec.fileSize,
                sha256: 'AA',
                localPath: r'C://recv//' '${spec.fileName!}',
              ),
            ]
          : const <FileAttachment>[],
      // 10 minutes apart on purpose: `conversation_thread` prints a `HH:mm`
      // label between two messages more than 5 minutes apart, so this spacing
      // puts one **inside** every cross-bubble drag below — which is how the
      // "…and no timestamp either" half gets tested instead of assumed.
      createdAt: fixedEpoch.add(Duration(minutes: i * 10)),
      updatedAt: fixedEpoch.add(Duration(minutes: i * 10)),
    );
  }
  return backend;
}

/// Every character of [copied] must come from one of [sources] — the strong form
/// of "the selection contains the bodies and nothing else".
void _expectNothingButBodies(String copied, List<String> sources) {
  final String foreign = copied
      .split('')
      .where((String c) =>
          !sources.any((String source) => source.contains(c)))
      .join();
  expect(foreign, isEmpty,
      reason: 'the selection picked up characters that belong to no message '
          'body: "$foreign" (whole copy: "$copied")');
}

void main() {
  testWidgets(
      'A: desktop — dragging from one bubble into the next copies the two BODIES '
      'and none of the buttons, chips or times around them',
      (WidgetTester tester) async {
    // An **outgoing failed** first message on purpose: it draws 重新发送 inside the
    // card and 失败 + 复制 under it, i.e. every kind of chrome the user saw in his
    // copy. The second message is a plain delivered one (已完成 + 复制).
    final FakeBackend backend = _seeded(const <_Msg>[
      _Msg.text(_bodyA, outgoing: true, status: MessageStatus.failed),
      _Msg.text(_bodyB),
    ]);
    addTearDown(backend.dispose);
    final List<String> copied = _captureClipboard();
    await _pumpDesktop(tester, backend);

    // Sanity: the chrome really is on screen, otherwise this test proves nothing.
    expect(find.text('重新发送'), findsOneWidget);
    expect(find.text('复制'), findsWidgets);

    final Rect a = tester.getRect(find.text(_bodyA));
    final Rect b = tester.getRect(find.text(_bodyB));
    // The timestamp between the two bubbles — the thing a naive cross-bubble drag
    // would paste as `20:10` in the middle of the text.
    final Finder between = find.text(timeText(fixedEpoch.add(const Duration(minutes: 10))));
    final Rect betweenRect = tester.getRect(between);
    expect(betweenRect.top, greaterThan(a.bottom));
    expect(betweenRect.bottom, lessThan(b.top));

    await _mouseDrag(
      tester,
      Offset(a.left + a.width * 0.2, a.center.dy),
      Offset(b.left + b.width * 0.6, b.center.dy),
    );
    await _controlC(tester);

    expect(copied, hasLength(1), reason: 'Ctrl+C must copy the selection');
    final String selection = copied.single;
    expect(selection, isNotEmpty);

    // 1. It really did span both messages…
    expect(selection, contains('左边'),
        reason: 'the drag starts inside the first body — got "$selection"');
    expect(selection, contains('另一段'),
        reason: 'and it must reach into the second one — got "$selection"');
    // 2. …and carried none of the chrome the user complained about.
    for (final String word in _chromeWords) {
      expect(selection, isNot(contains(word)),
          reason: '"$word" is a button/chip label, never part of a message');
    }
    // 3. The strong form: not one character from outside the two bodies — this is
    //    what also catches the time label (20:00), the day separator (今天) and
    //    any status word, without having to enumerate them.
    _expectNothingButBodies(selection, <String>[_bodyA, _bodyB]);
  });

  testWidgets(
      'B: desktop — a drag that runs DOWN through the bubble\'s button row still '
      'copies only the body', (WidgetTester tester) async {
    final FakeBackend backend = _seeded(const <_Msg>[
      _Msg.text(_bodyA, outgoing: true, status: MessageStatus.failed),
    ]);
    addTearDown(backend.dispose);
    final List<String> copied = _captureClipboard();
    await _pumpDesktop(tester, backend);

    final Rect a = tester.getRect(find.text(_bodyA));
    final Rect resend = tester.getRect(find.text('重新发送'));
    final Rect copy = tester.getRect(find.text('复制'));
    // From the top of the body, straight down past 重新发送 to the 复制 button.
    await _mouseDrag(
      tester,
      Offset(a.left + a.width * 0.02, a.top + 2),
      Offset(copy.center.dx, copy.center.dy + 2),
    );
    await _controlC(tester);

    expect(copied, hasLength(1));
    final String selection = copied.single;
    expect(selection, isNotEmpty, reason: 'the body still selected');
    expect(selection, contains(_bodyA.substring(0, 4)));
    for (final String word in _chromeWords) {
      expect(selection, isNot(contains(word)),
          reason: 'the drag passed over "$word" on its way down, but a label is '
              'not text to copy');
    }
    _expectNothingButBodies(selection, <String>[_bodyA]);
    // The two rects are really on the drag's path — otherwise the case is vacuous.
    expect(resend.top, greaterThan(a.bottom));
    expect(copy.top, greaterThan(resend.top));
  });

  testWidgets(
      'C: desktop — a FILE bubble is not selectable at all: a drag that starts on '
      'its card copies no file name and no size', (WidgetTester tester) async {
    final FakeBackend backend = _seeded(const <_Msg>[
      _Msg.file('notes.txt', 12),
      _Msg.text(_bodyA),
    ]);
    addTearDown(backend.dispose);
    final List<String> copied = _captureClipboard();
    await _pumpDesktop(tester, backend);

    final Finder fileName = find.text('notes.txt');
    expect(fileName, findsOneWidget, reason: 'the card must be on screen');

    final Rect card = tester.getRect(fileName);
    final Rect body = tester.getRect(find.text(_bodyA));
    // **Starts on the file card**, ends inside the text bubble below. This is the
    // direction that used to hurt: a range anchored on a file name pasted the
    // name (and the size) into the message text.
    await _mouseDrag(
      tester,
      Offset(card.center.dx, card.center.dy),
      Offset(body.left + body.width * 0.6, body.center.dy),
    );
    await _controlC(tester);

    // Nothing selectable on a card ⇒ either no selection at all or a body-only
    // one; what may never happen is the name showing up.
    if (copied.isNotEmpty) {
      expect(copied, hasLength(1));
      expect(copied.single, isNot(contains('notes')));
      expect(copied.single, isNot(contains('notes.txt')),
          reason: 'a file name is a label on a card, not selectable text');
      _expectNothingButBodies(copied.single, <String>[_bodyA]);
    }
  });
}
