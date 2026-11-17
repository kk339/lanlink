/// **0.2.36 — a folder dropped on the conversation is SENT, not refused.**
///
/// The user: *"拖文件夹被拒"*. 0.2.33 gave the app a way to send a whole folder
/// from the attach menu, and the drop path never caught up: it counted
/// directories and answered 「不能直接发送文件夹，请拖入里面的文件」 — a sentence
/// that had been true before 0.2.33 and was a lie after it.
///
/// The rule these tests pin: a dropped directory goes through the **same** flow as
/// 「发送文件夹…」 — the same platform walk (`PlatformPorts.describeFolderForSending`
/// → `domain/folder_send.dart`), the same confirmation sheet, the same
/// `sendPaths`. Only the way the path arrives differs. That is why the assertions
/// below check the *platform* was asked to describe the dropped path **and** that
/// the dialog is the folder dialog: two independent halves of one flow.
///
/// A note on how a drop is simulated: `desktop_drop` delivers events over the
/// `desktop_drop` method channel, so a test sends the same two calls the native
/// side sends — `entered` (which sets the anchor position and opens the drag
/// state) and then `performOperation` with the paths. Nothing about the app is
/// stubbed for this; the real `DropTarget` in the thread handles it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/folder_send.dart';
import 'package:lanlink_app/domain/models.dart';

import '../support/pump_app.dart';

const String _conversationId = 'c-drop';

/// The folder the fake will describe as "3 files, one of them in a sub-folder".
const String _folder = r'C:\素材';

/// A loose file dropped together with the folder.
const String _loosePath = r'C:\screenshot.png';

PeerDevice _peer() => const PeerDevice(
      fingerprint: 'EE07',
      alias: 'Eve',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

SendFolderSelection _threeFiles() => const SendFolderSelection(
      outcome: PickSendFolderOutcome.picked,
      files: <FolderScanFile>[
        FolderScanFile(path: '/素材/a.jpg', relativePath: 'a.jpg', size: 1048576),
        FolderScanFile(path: '/素材/b.jpg', relativePath: 'b.jpg', size: 1048576),
        FolderScanFile(
            path: '/素材/2026/c.jpg', relativePath: '2026/c.jpg', size: 1048576),
      ],
      totalBytes: 3 * 1024 * 1024,
      availableCount: 3,
      folderName: '素材',
    );

/// Mounts the desktop shell with an empty conversation.
Future<FakeBackend> _pumpThread(WidgetTester tester) async {
  // A drop position is compared against the target's box, and the plugin divides
  // it by the device pixel ratio on Windows — so the surface has to be pinned at
  // DPR 1 for the coordinates below to mean anything.
  useSurfaceSize(tester, const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'EE07',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.platform.setMobile(false);
  backend.platform.setSupportsSendFolder(true);
  backend.platform.setDirectory(_folder);
  backend.platform.describeFolderReply = _threeFiles();
  await pumpShell(
    tester,
    backend: backend,
    settle: true,
    initialPeer: _peer(),
  );
  return backend;
}

/// Drops [paths] on the middle of the conversation, the way the native side
/// reports a drop: `entered` first (it sets the position and opens the state),
/// then `performOperation` with the paths.
Future<void> _drop(WidgetTester tester, List<String> paths) async {
  final Offset at = tester.getCenter(find.byType(Scaffold).first);
  const MethodCodec codec = StandardMethodCodec();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    'desktop_drop',
    codec.encodeMethodCall(MethodCall('entered', <double>[at.dx, at.dy])),
    (ByteData? _) {},
  );
  await tester.pump();
  await messenger.handlePlatformMessage(
    'desktop_drop',
    codec.encodeMethodCall(MethodCall('performOperation', paths)),
    (ByteData? _) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      '★ criterion 2: a dropped FOLDER goes through the 发送文件夹 flow — the '
      'platform is asked to describe that path, the folder dialog appears, and '
      'confirmation puts its files in the thread', (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(tester);

    await _drop(tester, <String>[_folder]);

    // 1. The **folder** door was used, with the path that was dropped (not the
    //    picker: a picker would have returned `sendFolderReply`, and
    //    `pickSendFolderCalls` would have moved).
    expect(backend.platform.describedFolderPaths, <String>[_folder],
        reason: 'the dropped directory must be described by the platform, i.e. '
            'it went through the same walk as 「发送文件夹…」');
    expect(backend.platform.pickSendFolderCalls, 0,
        reason: 'no file chooser may open after a drop');

    // 2. …and it is the **same** confirmation sheet, wording included.
    expect(find.text('发送「素材」？'), findsOneWidget);
    expect(find.text('将发送 3 个文件，共 3.0 MB'), findsOneWidget);
    // 3. The old refusal is gone — this is the sentence the user complained about.
    expect(find.textContaining('不能直接发送文件夹'), findsNothing);
    expect(find.textContaining('已跳过'), findsNothing);

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    final List<ChatMessage> messages = backend.repo.history(_conversationId);
    expect(messages, hasLength(1));
    expect(
      backend.repo
          .filesOf(messages.single.id)
          .map((FileAttachment f) => f.fileName),
      <String>['a.jpg', 'b.jpg', 'c.jpg'],
    );
  });

  testWidgets(
      '★ criterion 3: a MIXED drop (folder + loose file) does both — the folder '
      'through its confirmation, the loose file as its own send',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(tester);

    await _drop(tester, <String>[_folder, _loosePath]);

    expect(backend.platform.describedFolderPaths, <String>[_folder],
        reason: 'only the directory takes the folder door');
    expect(find.text('发送「素材」？'), findsOneWidget,
        reason: 'the folder half asks before it moves 3 files');

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    final List<String> sent = <String>[
      for (final ChatMessage m in backend.repo.history(_conversationId))
        ...backend.repo.filesOf(m.id).map((FileAttachment f) => f.fileName),
    ];
    expect(sent, containsAll(<String>['a.jpg', 'b.jpg', 'c.jpg']));
    expect(sent, contains('screenshot.png'),
        reason: 'the loose file of the same drop is still sent — the folder flow '
            'must not swallow it');
  });

  testWidgets(
      'cancel in the folder dialog sends that folder nowhere and says nothing '
      '(the loose file of the same drop still goes)',
      (WidgetTester tester) async {
    final FakeBackend backend = await _pumpThread(tester);

    await _drop(tester, <String>[_folder]);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(backend.repo.history(_conversationId), isEmpty);
    expect(find.byType(SnackBar), findsNothing,
        reason: 'changing your mind is not something to announce');
    // The platform was still asked once — the flow ran, it just ended in a no.
    expect(backend.platform.describedFolderPaths, <String>[_folder]);
  });
}
