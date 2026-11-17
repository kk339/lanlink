/// Widget tests for the **desktop composer's keyboard** (0.2.35) —
/// *"电脑上在输入框打字按 enter 是回车不是发送，感觉最好是 shift+enter 是换行"*.
///
/// The rule this file pins down:
/// * **desktop** — `Enter` **sends**, `Shift+Enter` **breaks the line**;
/// * **phone** — not one thing changes: a soft-keyboard Enter is still a newline
///   and the 发送 button is still the only way to send;
/// * **an open IME composition owns Enter** (`composing.isValid`): a Chinese
///   user's Enter commits the candidate, it must never send;
/// * a blank/whitespace-only body: Enter does **nothing** — not a send, and not
///   an empty line either.
///
/// **A note on what a widget test can and cannot see.** Flutter's framework does
/// not insert the newline itself: on Windows there is no `Enter` shortcut at all
/// (`DefaultTextEditingShortcuts` maps it to `DoNothingAndStopPropagation` on
/// Linux/macOS, and to nothing on Windows), so the newline comes from the
/// **platform text input**. `tester.sendKeyEvent` only exercises the framework
/// half, which is why case B has two steps: the key event (must not send) and
/// then `tester.testTextInput.updateEditingValue` — the same channel the real
/// platform uses — to show the field still takes the newline and grows.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

/// A dialable peer, i.e. one the composer will let us type to.
PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

Future<void> _pump(WidgetTester tester, FakeBackend backend,
    ConversationController controller) async {
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(
      body: ConversationThread(controller: controller, peer: _peer()),
    ),
    backend: backend,
    settle: true,
  );
}

/// The composer's `TextField`.
Finder _field() => find.byType(TextField);

/// One `Enter` **press** through the real key pipeline.
Future<void> _enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

/// `Shift+Enter`.
Future<void> _shiftEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

void main() {
  late FakeBackend backend;
  late ConversationController controller;

  setUp(() {
    backend = FakeBackend();
    backend.repo.addConversation(
      id: 'c-enter',
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-0',
      conversationId: 'c-enter',
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      kind: MessageKind.text,
      textBody: '先有一条',
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: TransferOrchestrator(
        repo: backend.repo,
        transfer: backend.transfer,
      ),
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: 'c-enter',
      drafts: ComposerDraftStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    backend.dispose();
  });

  testWidgets('A: desktop — typing and pressing Enter SENDS (the field empties)',
      (WidgetTester tester) async {
    backend.platform.setMobile(false);
    await _pump(tester, backend, controller);
    expect(find.byType(MessageBubble), findsOneWidget,
        reason: 'sanity: one seeded bubble before the keyboard acts');

    await tester.enterText(_field(), '你好');
    await tester.pump();
    await _enter(tester);

    expect(find.byType(MessageBubble), findsNWidgets(2),
        reason: 'Enter must send on the desktop, which is the whole request — '
            'this assertion fails on 0.2.34');
    expect(find.text('你好'), findsOneWidget,
        reason: 'the sent body must land in a bubble');
    expect(tester.widget<TextField>(_field()).controller!.text, isEmpty,
        reason: 'a sent message clears the composer (unchanged from 0.2.34)');
    // The keyboard wrapper must not have cost the field its focus: the user keeps
    // typing the next message without clicking back into the box.
    final EditableTextState editable =
        tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.widget.focusNode.hasFocus, isTrue,
        reason: 'sending keeps the caret in the composer');
  });

  testWidgets(
      'B: desktop — Shift+Enter is the newline: it does NOT send, and the field '
      'still takes the line break', (WidgetTester tester) async {
    backend.platform.setMobile(false);
    await _pump(tester, backend, controller);

    await tester.enterText(_field(), '第一行');
    await tester.pump();
    final double oneLine = tester.getSize(_field()).height;
    await _shiftEnter(tester);

    // 1. Not a send.
    expect(find.byType(MessageBubble), findsOneWidget,
        reason: 'Shift+Enter must be a newline, never a send');
    expect(tester.widget<TextField>(_field()).controller!.text, '第一行',
        reason: 'the framework half of Shift+Enter must not touch the text '
            'either — it is handed back to the field untouched');

    // 2. …and the newline it handed back still arrives. The framework never
    //    inserts it (there is no Enter shortcut in the desktop tables); the
    //    platform text input does, which is the channel simulated here.
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '第一行\n',
      selection: TextSelection.collapsed(offset: 4),
    ));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_field()).controller!.text, '第一行\n');
    expect(tester.getSize(_field()).height, greaterThan(oneLine),
        reason: 'a second line must actually be laid out — "换行" that does not '
            'change the height is not a line break');
    expect(find.byType(MessageBubble), findsOneWidget);
  });

  testWidgets(
      'C: desktop — while an IME composition is open, Enter does NOT send (it '
      'belongs to the input method)', (WidgetTester tester) async {
    backend.platform.setMobile(false);
    await _pump(tester, backend, controller);

    await tester.enterText(_field(), '测试');
    await tester.pump();
    // What a Chinese IME reports while 组词 is in progress: underlined text.
    tester.widget<TextField>(_field()).controller!.value =
        const TextEditingValue(
      text: '测试',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();

    await _enter(tester);

    expect(find.byType(MessageBubble), findsOneWidget,
        reason: 'Enter while composing must commit the candidate, not send a '
            'half-typed word — this is the one guard a Chinese user depends on');
    expect(tester.widget<TextField>(_field()).controller!.text, '测试',
        reason: 'and the text stays in the field, waiting for the commit');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'D: desktop — Enter on a blank/whitespace-only composer does nothing at '
      'all: no send, no empty line', (WidgetTester tester) async {
    backend.platform.setMobile(false);
    await _pump(tester, backend, controller);

    // Empty…
    await _enter(tester);
    expect(find.byType(MessageBubble), findsOneWidget);
    expect(tester.widget<TextField>(_field()).controller!.text, isEmpty);

    // …and whitespace-only.
    await tester.enterText(_field(), '   ');
    await tester.pump();
    await _enter(tester);
    expect(find.byType(MessageBubble), findsOneWidget,
        reason: 'a whitespace-only body is not sendable (unchanged rule)');
    expect(tester.widget<TextField>(_field()).controller!.text, '   ',
        reason: 'and Enter must not add a newline to it either — the key is '
            'swallowed precisely to avoid leaving an empty line behind');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'E: phone — an Enter from a hardware keyboard is still a NEWLINE, never a '
      'send (nothing about the mobile composer changes)',
      (WidgetTester tester) async {
    backend.platform.setMobile(true);
    await _pump(tester, backend, controller);

    await tester.enterText(_field(), '手机上');
    await tester.pump();
    await _enter(tester);

    expect(find.byType(MessageBubble), findsOneWidget,
        reason: 'on a phone the 发送 button is the only way to send; Enter is a '
            'newline there and 0.2.35 must not change that');
    expect(tester.widget<TextField>(_field()).controller!.text, '手机上');
  });
}
