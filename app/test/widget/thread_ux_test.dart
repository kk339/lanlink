/// Widget tests for the thread's everyday-use fixes: auto-scroll (M5c §1), a
/// visible history-read failure (§4), ≥44px bubble actions (§5) and a growing
/// composer (§6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

PeerDevice _peer(String fingerprint,
        {required String alias, bool online = false}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: 53317,
    );

void main() {
  testWidgets(
      '2: opening a thread lands at the bottom WITHOUT animating (a user-visible '
      'requirement: "每次打开都会迅速下滑" was the complaint)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 500));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-instant',
      deviceFingerprint: 'EE02',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    for (int i = 0; i < 40; i++) {
      backend.repo.addMessage(
        id: 'n-$i',
        conversationId: 'c-instant',
        direction: MessageDirection.incoming,
        status: MessageStatus.done,
        kind: MessageKind.text,
        textBody: '消息 $i',
        createdAt: fixedEpoch.add(Duration(minutes: i)),
        updatedAt: fixedEpoch.add(Duration(minutes: i)),
      );
    }

    // ★ `settle: false` on purpose, and no `pumpAndSettle` below: settling runs
    // the animation to completion, which would hide exactly what the user
    // reported. Advance only enough frames for the fill plus its post-frame
    // positioning, then read what is actually on screen at that moment.
    await pumpShell(
      tester,
      backend: backend,
      settle: false,
      initialPeer: _peer('EE02', alias: 'Eve'),
    );
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    // Asserted as an *existence* first: a row that has not been scrolled to is
    // not built at all in a lazy list, so "is the newest row there yet?" is the
    // honest, falsifiable form of "did we land at the bottom without animating?".
    expect(
      find.text('消息 39'),
      findsOneWidget,
      reason: 'the newest message must already be built (= in view) this early',
    );
    final Rect pane = tester.getRect(find.byType(ConversationThread));
    final Rect newest = tester.getRect(find.text('消息 39'));
    expect(
      newest.bottom,
      lessThanOrEqualTo(pane.bottom + 0.5),
      reason:
          'the newest message must already be in view — the user watched it '
          'slide down on every single open',
    );
  });

  testWidgets(
      '4: a failed history read is VISIBLE (not the empty state) and retry reloads',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-fail',
      deviceFingerprint: 'EE01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.failHistoryWith(StateError('disk on fire'));

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EE01', alias: 'Eve'),
    );

    // The three states must look different: a failure is NOT the empty state.
    expect(find.textContaining('读取会话记录失败'), findsOneWidget);
    expect(find.textContaining('disk on fire'), findsOneWidget);
    expect(find.text('还没有传输记录'), findsNothing);

    // Retry re-runs the read — once the failure clears, the (empty) thread shows.
    backend.repo.failHistoryWith(null);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('读取会话记录失败'), findsNothing);
    expect(find.text('还没有传输记录'), findsOneWidget);
  });

  testWidgets(
      '1: opening a thread taller than the viewport lands at the NEWEST message',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 500));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-scroll',
      deviceFingerprint: 'EE01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    for (int i = 0; i < 40; i++) {
      backend.repo.addMessage(
        id: 'm-$i',
        conversationId: 'c-scroll',
        direction: MessageDirection.incoming,
        status: MessageStatus.done,
        kind: MessageKind.text,
        textBody: '消息 $i',
        createdAt: fixedEpoch.add(Duration(minutes: i)),
        updatedAt: fixedEpoch.add(Duration(minutes: i)),
      );
    }

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EE01', alias: 'Eve'),
    );
    await tester.pumpAndSettle();

    // The composer's `EditableText` is also a `Scrollable`, so take the FIRST —
    // the timeline's (the Column puts it above the composer).
    final ScrollableState scrollable = tester.state(
      find
          .descendant(
            of: find.byType(ConversationThread),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      scrollable.position.pixels,
      greaterThan(0),
      reason: 'the timeline should auto-scroll to the newest message',
    );
    // The newest message is on screen; the oldest has scrolled off. (Asserting an
    // exact `maxScrollExtent` is fragile — the lazy slider's extent estimate
    // drifts as more children lay out.)
    final Rect pane = tester.getRect(find.byType(ConversationThread));
    final Rect newest = tester.getRect(find.text('消息 39'));
    expect(newest.top, greaterThanOrEqualTo(pane.top));
    expect(newest.bottom, lessThanOrEqualTo(pane.bottom));
  });

  testWidgets('5: the bubble action buttons are at least 44px tall',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-act',
      deviceFingerprint: 'EE01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-act',
      conversationId: 'c-act',
      direction: MessageDirection.outgoing,
      status: MessageStatus.pending, // cancelable → shows 取消
      createdAt: fixedEpoch,
      updatedAt: fixedEpoch,
      files: <FileAttachment>[
        FileAttachment(
          id: 'f-act',
          messageId: 'm-act',
          fileName: 'queued.bin',
          size: 4,
          sha256: 'AA',
          localPath: null,
        ),
      ],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EE01', alias: 'Eve', online: false),
    );

    final Size cancel = tester.getSize(find.widgetWithText(TextButton, '取消'));
    expect(cancel.height, greaterThanOrEqualTo(44));
  });

  testWidgets('6: the composer grows from 1 up to 4 lines',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-in',
      deviceFingerprint: 'EE01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EE01', alias: 'Eve', online: true),
    );

    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 1);
    expect(field.maxLines, 4);
  });
}
