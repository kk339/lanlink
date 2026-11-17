/// Widget test for the 0.2.14 "点了没反应" fix: while a picked file is being
/// hashed the thread must show a **preparing** hint immediately, and the hint
/// must disappear once the message row (the bubble) exists.
///
/// Why this cannot be a pure controller test: the whole point is *when* the
/// first repaint happens relative to the tap, which only a widget test can see.
/// The hash is held open with a `Completer` (see
/// `FakePlatformPorts.holdNextHash`), otherwise the fake finishes it inside one
/// microtask and the window is unobservable.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/transfer_service.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';

import '../support/pump_app.dart';

PeerDevice _peer(String fingerprint, {required String alias}) => PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

void main() {
  testWidgets(
      'the preparing hint shows on the next frame, before any bubble, and goes '
      'away when the bubble lands', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-prep',
      deviceFingerprint: 'EE07',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.platform.setExists('/src/big.bin', true);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EE07', alias: 'Eve'),
    );

    // Nothing to show yet.
    expect(find.textContaining('正在准备'), findsNothing);

    // Park the hash so the window stays open for the assertions below.
    final Completer<void> gate = Completer<void>();
    backend.platform.holdNextHash(gate);

    final ConversationThread thread =
        tester.widget<ConversationThread>(find.byType(ConversationThread));
    final Future<SendOutcome?> pending = thread.controller.sendPaths(
      peer: _peer('EE07', alias: 'Eve'),
      paths: <String>['/src/big.bin'],
    );

    // ONE frame — the tap must already have produced feedback.
    await tester.pump();

    expect(
      find.textContaining('正在准备'),
      findsOneWidget,
      reason: 'the hint must appear on the frame right after the tap, not after '
          'the hash (that is the whole complaint: "点了没反应")',
    );
    expect(find.textContaining('big.bin'), findsOneWidget,
        reason: 'the single-file label names the file');
    expect(
      find.byType(MessageBubble),
      findsNothing,
      reason: 'no message row can exist yet — the hash feeds the message id',
    );

    // Let the hash finish: the hint must go away and the bubble must arrive.
    await tester.runAsync(() async {
      gate.complete();
      await pending;
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('正在准备'), findsNothing);
    expect(find.byType(MessageBubble), findsOneWidget);
  });

  testWidgets('several files are counted instead of named', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 800));
    final FakeBackend backend = FakeBackend();
    addTearDown(backend.dispose);
    backend.repo.addConversation(
      id: 'c-prep2',
      deviceFingerprint: 'EE08',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    for (final String path in <String>['/src/a.bin', '/src/b.bin']) {
      backend.platform.setExists(path, true);
    }

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('EE08', alias: 'Eve'),
    );

    final Completer<void> gate = Completer<void>();
    backend.platform.holdNextHash(gate);

    final ConversationThread thread =
        tester.widget<ConversationThread>(find.byType(ConversationThread));
    final Future<SendOutcome?> pending = thread.controller.sendPaths(
      peer: _peer('EE08', alias: 'Eve'),
      paths: <String>['/src/a.bin', '/src/b.bin'],
    );
    await tester.pump();

    expect(find.text('正在准备 2 个文件'), findsOneWidget);
    expect(find.textContaining('a.bin'), findsNothing,
        reason: 'with more than one file the label counts, it does not name');

    await tester.runAsync(() async {
      gate.complete();
      await pending;
      // The second hash is not held, so both files finish now.
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('正在准备'), findsNothing);
  });
}
