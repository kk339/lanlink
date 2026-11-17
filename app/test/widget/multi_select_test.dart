/// Multi-select, batch delete and **forward** (0.2.41).
///
/// The user's scope, verbatim: the bar has **two** entries (`删除` / `转发`), no
/// system share; the entry is the conversation's ⋯ → 多选 (and, on a desktop, the
/// bubble's right-click menu, which has no ⋯ of its own).
///
/// What these cases pin, each against a way it could be wrong:
/// * **1** — two picked rows really leave the store (a *fresh* controller reading
///   the same repository sees nothing: a delete that only removed the bubbles
///   would come back on the next load);
/// * **2/8** — 全选 / 取消, and leaving the mode puts the timeline back exactly as
///   it was (no ring left behind);
/// * **3** — in this mode a tap **only** picks: a file bubble must not open its
///   file and must not raise its attachment menu;
/// * **4/5** — forwarding is a **real send**: the target device's conversation
///   gains a message, the text arrives verbatim, and the fake `TransferService`
///   actually `prepare`d the files (writing a row is not sending);
/// * **6** — a source file that is gone fails **loudly** and sends nothing (no
///   empty message in the target conversation);
/// * **7** — a `transferring` bubble has no ring at all.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _conv = 'c-ms';
const String _otherConv = 'c-other';
const String _first = '先发一条文字';
const String _second = '再发一条文字';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

PeerDevice _other() => const PeerDevice(
      fingerprint: 'EE02',
      alias: '阿伟',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53318,
    );

/// Mounts the **phone** shell with the conversation open: two text messages and
/// one file message, plus a second device (阿伟) that can be a forward target.
Future<FakeBackend> _pump(WidgetTester tester,
    {int fileSize = 12,
    String filePath = '/d/notes.txt',
    bool online = true,
    /// Seed a **folder** message (2 files, one in a sub-directory) as the oldest
    /// row, so it is at the top of the timeline and always built by the list.
    bool withFolder = false}) async {
  useSurfaceSize(tester, const Size(600, 1200));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setMobile(true);
  backend.repo.addDevice(_peer());
  backend.repo.addDevice(_other());
  // ★ `mergeDeviceCards` takes "online" from **discovery**, not from the stored
  // row: a device with a port but no discovery entry is `canSend` yet **not
  // dialable**, so a forward to it would be *queued* (correctly!) and would never
  // reach `TransferService.prepare`. The cases that assert a real send therefore
  // bring 阿伟 online the way the network would.
  if (online) {
    backend.discovery.setOnline(<DiscoveredPeer>[
      DiscoveredPeer(
        fingerprint: 'EE02',
        alias: '阿伟',
        kind: DeviceKind.desktop,
        address: '192.168.1.20',
        port: 53318,
        isOnline: true,
        lastSeen: fixedEpoch,
      ),
    ]);
  }
  backend.repo.addConversation(
    id: _conv,
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addConversation(
    id: _otherConv,
    deviceFingerprint: 'EE02',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  if (withFolder) {
    backend.repo.addMessage(
      id: 'm-folder',
      conversationId: _conv,
      direction: MessageDirection.outgoing,
      status: MessageStatus.done,
      kind: MessageKind.file,
      folderName: '素材',
      folderFiles: 2,
      files: const <FileAttachment>[
        FileAttachment(
          id: 'ff-1',
          messageId: 'm-folder',
          fileName: 'a.jpg',
          size: 100,
          sha256: 'AA',
          localPath: '/d/x/素材/a.jpg',
          relativePath: 'a.jpg',
        ),
        FileAttachment(
          id: 'ff-2',
          messageId: 'm-folder',
          fileName: 'b.jpg',
          size: 200,
          sha256: 'BB',
          localPath: '/d/x/素材/sub/b.jpg',
          relativePath: 'sub/b.jpg',
        ),
      ],
      createdAt: fixedEpoch.subtract(const Duration(minutes: 5)),
      updatedAt: fixedEpoch.subtract(const Duration(minutes: 5)),
    );
  }
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: _conv,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: MessageKind.text,
    textBody: _first,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-2',
    conversationId: _conv,
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    kind: MessageKind.text,
    textBody: _second,
    createdAt: fixedEpoch.add(const Duration(minutes: 1)),
    updatedAt: fixedEpoch.add(const Duration(minutes: 1)),
  );
  backend.repo.addMessage(
    id: 'm-3',
    conversationId: _conv,
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    kind: MessageKind.file,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f-3',
        messageId: 'm-3',
        fileName: 'notes.txt',
        size: fileSize,
        sha256: 'AA',
        localPath: filePath,
      ),
    ],
    createdAt: fixedEpoch.add(const Duration(minutes: 2)),
    updatedAt: fixedEpoch.add(const Duration(minutes: 2)),
  );
  await pumpShell(
    tester,
    backend: backend,
    settle: true,
    initialPeer: _peer(),
  );
  return backend;
}

/// ⋯ → 多选.
Future<void> _enterSelection(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('多选').last);
  await tester.pumpAndSettle();
}

/// Picks [aliases] in the (multi-select since 0.2.46) device picker and confirms.
///
/// The picker stopped sending on the first tap when it grew checkboxes: a tap now
/// toggles a row and 「转发（N）」 is what runs the fan-out. This helper is the
/// one place that knows the difference, so every case below keeps asserting the
/// thing it was written for instead of the dialog's mechanics.
Future<void> _pickTargets(WidgetTester tester, List<String> aliases) async {
  for (final String alias in aliases) {
    await tester.tap(find.text(alias));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey<String>('forward-confirm')));
  await tester.pumpAndSettle();
}

Finder _ring(String messageId) => find.byKey(ValueKey<String>('select-ring-$messageId'));

void main() {
  testWidgets(
      '★ criterion 1: ⋯ → 多选 → pick two → 删除 → both rows are gone, and a FRESH '
      'controller over the same store does not bring them back',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(tester);

    await _enterSelection(tester);
    expect(find.text('已选 0 条'), findsOneWidget);

    await tester.tap(find.text(_first));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_second));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('selection-delete')));
    await tester.pumpAndSettle();

    // 1. The timeline no longer shows them…
    expect(find.text(_first), findsNothing);
    expect(find.text(_second), findsNothing);
    // 2. …and the store really lost them. A fresh controller (the "reopen the
    //    conversation / restart the app" stand-in) reads the same repository.
    final List<ChatMessage> left = backend.repo.history(_conv);
    expect(left.map((ChatMessage m) => m.textBody).toList(), <String?>[null],
        reason: 'only the file message is left');
    // 3. …and multi-select left with them.
    expect(find.text('已选 0 条'), findsNothing);
  });

  testWidgets('★ criterion 2 + 8: 全选 picks everything, 取消 leaves the mode and '
      'the rings disappear', (WidgetTester tester) async {
    await _pump(tester);

    await _enterSelection(tester);
    expect(_ring('m-1'), findsOneWidget);
    expect(_ring('m-3'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('selection-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('已选 0 条'), findsNothing);
    expect(find.byType(IconButton), findsWidgets);
    expect(find.byKey(const ValueKey<String>('select-ring-m-1')), findsNothing,
        reason: 'the rings are part of the mode and must not outlive it');
    // The composer is back, i.e. the bottom strip is the normal one again.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets(
      '★ criterion 3: in the mode a tap ONLY picks — the file bubble neither opens '
      'its file nor raises its attachment menu',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(tester);
    await _enterSelection(tester);

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(backend.platform.opened, isEmpty,
        reason: 'the file must not open while picking messages');
    expect(find.text('复制文件名'), findsNothing,
        reason: 'the attachment menu must not appear either');
    expect(find.text('已选 1 条'), findsOneWidget,
        reason: 'the tap went to the selection instead');
  });

  testWidgets(
      '★ criterion 4: forwarding a text message sends the SAME text to the other '
      'device, and leaves the source conversation alone',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(tester);
    await _enterSelection(tester);

    await tester.tap(find.text(_first));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('selection-forward')));
    await tester.pumpAndSettle();

    // The picker lists devices, offline ones marked as queued.
    expect(find.text('转发到'), findsOneWidget);
    await _pickTargets(tester, <String>['阿伟']);

    final List<ChatMessage> sent = backend.repo.history(_otherConv);
    expect(sent, hasLength(1), reason: 'the target device got one new message');
    expect(sent.single.kind, MessageKind.text);
    expect(sent.single.textBody, _first, reason: 'verbatim, not truncated');
    expect(sent.single.direction, MessageDirection.outgoing);

    // The source conversation is untouched (still three messages).
    expect(backend.repo.history(_conv), hasLength(3));
  });

  testWidgets(
      '★ criterion 5: forwarding a file really sends it — the fake TransferService '
      'prepared the batch (a row in the store would not be a send)',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(tester);
    final int before = backend.transfer.preparedSessions.length;

    await _enterSelection(tester);
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('selection-forward')));
    await tester.pumpAndSettle();
    await _pickTargets(tester, <String>['阿伟']);

    expect(backend.transfer.preparedSessions.length, before + 1,
        reason: 'one prepare for the forwarded file — the bytes go out again');
    expect(
      backend.transfer.lastPreparedFiles.map((OutgoingFile f) => f.fileName),
      <String>['notes.txt'],
    );
    final List<ChatMessage> sent = backend.repo.history(_otherConv);
    expect(sent, hasLength(1));
    expect(sent.single.kind, MessageKind.file);
    expect(backend.repo.filesOf(sent.single.id).single.fileName, 'notes.txt');
  });

  testWidgets(
      '★ criterion 6: a source file that is gone fails LOUDLY and sends nothing — no '
      'empty message in the target conversation',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(tester, filePath: '/d/gone.txt');
    backend.platform.setExists('/d/gone.txt', false);
    final int before = backend.transfer.preparedSessions.length;

    await _enterSelection(tester);
    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('selection-forward')));
    await tester.pumpAndSettle();
    await _pickTargets(tester, <String>['阿伟']);

    // The notice names the reason…
    expect(find.textContaining('源文件已不在本地'), findsOneWidget);
    // …nothing was prepared, and the target conversation has no new row at all.
    expect(backend.transfer.preparedSessions.length, before);
    expect(backend.repo.history(_otherConv), isEmpty,
        reason: 'a failed forward must not leave an empty message behind');
  });

  testWidgets(
      '★ criterion 7: a transferring bubble has NO ring — an affordance that cannot '
      'work is not drawn', (WidgetTester tester) async {
    final FakeBackend backend = await _pump(tester);
    backend.repo.addMessage(
      id: 'm-live',
      conversationId: _conv,
      direction: MessageDirection.outgoing,
      status: MessageStatus.transferring,
      kind: MessageKind.text,
      textBody: '正在发送的那条',
      createdAt: fixedEpoch.add(const Duration(minutes: 3)),
      updatedAt: fixedEpoch.add(const Duration(minutes: 3)),
    );
    await tester.pumpAndSettle();

    await _enterSelection(tester);

    expect(_ring('m-live'), findsNothing);
    expect(_ring('m-1'), findsOneWidget,
        reason: 'a finished message still has its ring');
    // And 全选 must not pick the in-flight one either.
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsOneWidget,
        reason: '3 of the 4 messages are selectable; the transferring one is not');
  });

  testWidgets(
      '★ forwarding a FOLDER keeps the folder descriptor — the gap `resend()` has: it '
      're-sends the rows but declares no folder, so the receiver would fold the batch '
      'into one FLAT message',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pump(tester, withFolder: true);

    await _enterSelection(tester);
    expect(find.text('素材'), findsOneWidget,
        reason: 'the folder card is the oldest row, i.e. at the top');
    await tester.tap(find.text('素材'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('selection-forward')));
    await tester.pumpAndSettle();
    await _pickTargets(tester, <String>['阿伟']);

    // The frame carried the folder…
    expect(backend.transfer.lastPreparedFolder, isNotNull,
        reason: 'without this the receiver builds a flat message');
    expect(backend.transfer.lastPreparedFolder!.name, '素材');
    expect(backend.transfer.lastPreparedFolder!.count, 2);
    // …and every file carried its position inside it.
    expect(
      backend.transfer.lastPreparedFiles
          .map((OutgoingFile f) => f.relativePath)
          .toList(),
      <String?>['a.jpg', 'sub/b.jpg'],
    );
    // The forwarded message in the target conversation is a folder, not a pile.
    final List<ChatMessage> sent = backend.repo.history(_otherConv);
    expect(sent, hasLength(1));
    expect(sent.single.folderName, '素材');
    expect(sent.single.folderFiles, 2);
  });

  testWidgets(
      '★ the DESKTOP way in: right-click a bubble → 「多选」 → the mode starts (a '
      'desktop has no ⋯ on the bubble, so this menu is its entry)',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      useSurfaceSize(tester, const Size(1400, 1000));
      final FakeBackend backend = FakeBackend();
      addTearDown(backend.dispose);
      backend.platform.setMobile(false);
      backend.repo.addDevice(_peer());
      backend.repo.addConversation(
        id: _conv,
        deviceFingerprint: 'CC01',
        createdAt: fixedEpoch,
        lastMessageAt: fixedEpoch,
      );
      backend.repo.addMessage(
        id: 'm-1',
        conversationId: _conv,
        direction: MessageDirection.incoming,
        status: MessageStatus.done,
        kind: MessageKind.text,
        textBody: _first,
        createdAt: fixedEpoch,
        updatedAt: fixedEpoch,
      );
      await pumpShell(
        tester,
        backend: backend,
        settle: true,
        initialPeer: _peer(),
      );

      final Rect box = tester.getRect(find.text(_first));
      final TestGesture gesture = await tester.startGesture(
        box.center,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('多选'), findsOneWidget,
          reason: 'the message menu offers it (0.2.38 menu + 0.2.41 entry)');
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();

      // The mode is on: the bar is up and the ring exists.
      expect(find.text('已选 0 条'), findsOneWidget);
      expect(_ring('m-1'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
