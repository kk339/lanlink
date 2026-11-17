/// **0.2.36 — a notice no longer lands on the composer, and it stops shouting.**
///
/// The user: *"提示条挡输入框、太久"*. Every notice in the app was a bare
/// `showSnackBar` — the Material default, **fixed to the bottom edge for four
/// seconds** — and in a conversation the bottom edge is the box you type into.
/// So the answer to "did that work?" arrived on top of the thing you were using,
/// and stayed there.
///
/// The rule now (`ui/notices.dart`): **floating**, **2 s**, a bottom margin that
/// clears the composer, and the newest notice replaces the queue instead of
/// waiting behind it.
///
/// **Where `kComposerNoticeInset = 76` comes from — measured, not guessed.** In
/// this test the composer's own geometry is read out of the tree: the send button
/// and the field are measured, the composer's top edge is derived from them, and
/// the constant is checked against that number *and* against the stronger,
/// user-visible property: the notice's rectangle must not overlap the composer's
/// at all. If someone changes the composer's height (a bigger field, a second
/// row), case A fails and the number gets re-derived instead of silently rotting.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/notices.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _body = '这是一段文字';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Mounts the desktop conversation with one text message (so the bubble's
/// 「复制」 button — an easy notice to raise — is on screen).
Future<FakeBackend> _pumpThread(WidgetTester tester) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: 'c-notice',
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-0',
    conversationId: 'c-notice',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: MessageKind.text,
    textBody: _body,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: 'c-notice',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: MessageKind.file,
    createdAt: fixedEpoch.add(const Duration(minutes: 1)),
    updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
    files: const <FileAttachment>[
      FileAttachment(
        id: 'f-1',
        messageId: 'm-1',
        fileName: 'notes.txt',
        size: 12,
        sha256: 'AA',
        localPath: r'C://recv//notes.txt',
      ),
    ],
  );
  final ConversationController controller = ConversationController(
    repo: backend.repo,
    orchestrator: TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    ),
    platform: backend.platform,
    ids: backend.ids,
    clock: backend.clock,
    conversationId: 'c-notice',
    drafts: ComposerDraftStore(),
  );
  addTearDown(controller.dispose);
  backend.platform.setMobile(false);
  _mockClipboard();
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(
      body: ConversationThread(controller: controller, peer: _peer()),
    ),
    backend: backend,
    settle: true,
  );
  return backend;
}

/// A no-op clipboard handler: the 「已复制」 notice is raised **after** the write,
/// so without one the platform channel would throw and no notice would appear.
void _mockClipboard() {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform,
      (MethodCall call) async => null);
  addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

/// Taps the bubble's 「复制」 button, which raises the 「已复制」 notice.
Future<void> _raiseNotice(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('bubble-copy-text')));
  await tester.pump(); // let the SnackBar enter its animation
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
      'A: the notice is floating, lasts 2 s, and its rectangle clears the '
      'composer — the margin is derived from the composer, not guessed',
      (WidgetTester tester) async {
    await _pumpThread(tester);

    // ── the composer's geometry, read out of the tree ───────────────────────
    final Rect field = tester.getRect(find.byType(TextField));
    final Rect send = tester.getRect(find.byTooltip('发送'));
    // The composer is `Padding(vertical: 8)` around a row of controls, so its top
    // edge is 8 dp above the tallest control.
    final double composerTop = send.top - 8;
    final double composerHeight = 1000 - composerTop;

    expect(composerHeight, 60.0,
        reason: 'the number the margin is derived from (8 + 44 + 8) — if the '
            'composer ever changes height, this test is where it surfaces');

    await _raiseNotice(tester);

    // ── the notice itself ──────────────────────────────────────────────────
    final SnackBar bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.behavior, SnackBarBehavior.floating,
        reason: 'a fixed snackbar sits ON the bottom edge; only the floating '
            'behaviour can be given a margin');
    expect(bar.duration, const Duration(seconds: 2),
        reason: 'four seconds was the "too long" half of the report');
    expect(bar.margin, isA<EdgeInsets>(),
        reason: 'the margin is what keeps it off the composer');
    expect((bar.margin! as EdgeInsets).bottom, kComposerNoticeInset);
    expect(kComposerNoticeInset, 76.0,
        reason: 'composer 60 + 1 dp divider + 15 dp gap');

    // ── and the property the user actually cares about ─────────────────────
    // The `SnackBar` widget's own box is the full width of the Scaffold (it is
    // positioned inside it); the **surface the user sees** is the Material it
    // builds, and that is the rectangle the composer can be measured against.
    final Rect notice = tester.getRect(
      find
          .descendant(
              of: find.byType(SnackBar), matching: find.byType(Material))
          .first,
    );
    expect(notice.bottom, 1000 - kComposerNoticeInset,
        reason: 'the margin must be doing the work: the surface bottom sits '
            'exactly `margin.bottom` above the window bottom');
    expect(notice.bottom, lessThanOrEqualTo(composerTop),
        reason: 'the notice must sit **above** the composer, not on it');
    expect(notice.bottom, lessThanOrEqualTo(field.top));
    expect(notice.bottom, lessThanOrEqualTo(send.top));
    expect(notice.top, greaterThan(0),
        reason: 'and it must still be on screen, not pushed off the top');
  });

  testWidgets(
      'B: a second notice does not queue behind the first — the newest replaces '
      'it, so the screen stops saying something that is no longer true',
      (WidgetTester tester) async {
    await _pumpThread(tester);

    // 1. 「已复制」 from the text bubble's button.
    await _raiseNotice(tester);
    expect(find.text('已复制'), findsOneWidget);

    // 2. A **different** notice, raised while the first is still counting down:
    //    right-click the file bubble → 复制文件名.
    await tester.tap(find.byType(FileTile), warnIfMissed: false);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(FileTile)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制文件名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The old notice is gone and the new one is the only snackbar: with a queue
    // the first would still be on screen and the second would be waiting
    // invisibly — the user sees a stale sentence and then a second one later.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('已复制文件名'), findsOneWidget,
        reason: 'the newest notice must be the one on screen');
    expect(find.text('已复制'), findsNothing,
        reason: 'the stale notice must be cleared, not queued behind');
  });
}
