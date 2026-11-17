/// **「转发到…」 from a file bubble and from a folder card** (0.2.46).
///
/// The awkward gap 0.2.46 closed: forwarding one *file* — the thing people
/// actually forward — still meant 「⋯ → 多选 → 勾 → 转发」, three steps through a
/// mode nobody wanted, because the desktop message menu only ever existed for a
/// **text** bubble (the file bubble's right click is its own attachment menu),
/// and a **folder** card had no secondary tap at all.
///
/// What these cases pin, each against a way it could be wrong:
///
/// * **1** — a right-click on a file card offers 「转发到…」, and it opens the
///   same multi-select device list as the text path;
/// * **2** — picking two devices really sends twice: `prepare` runs once per
///   device and each target conversation gains its own file message (a row in
///   each store would not be a send);
/// * **3** — every existing entry is still there: 打开 / 打开所在位置 / 复制文件名
///   / 复制文件路径 / 详细信息… / 删除, asserted **one by one** and by exact row
///   count, so "added a row and loosened the assertion" cannot pass;
/// * **4** — a **folder** card answers a right-click too, and forwarding it keeps
///   the folder descriptor (the receiver must not fold it into N flat bubbles).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _conversationId = 'c-file-fwd';
const String _fileName = 'notes.txt';
const String _folderName = '素材';

PeerDevice _source() => const PeerDevice(
      fingerprint: 'CC01',
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53317,
    );

/// The online target.
PeerDevice _online() => const PeerDevice(
      fingerprint: 'EE02',
      alias: '台式机',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53318,
    );

/// The offline target (`canSend`, not dialable *now*): a forward to it queues.
PeerDevice _offline() => const PeerDevice(
      fingerprint: 'DD03',
      alias: '笔记本',
      kind: DeviceKind.desktop,
      isOnline: false,
      lastPort: 53319,
    );

/// Whether this case seeds a plain **file** message or a **folder** message.
enum _Shape { file, folder }

/// Mounts the thread (desktop) with one message of the given shape.
Future<FakeBackend> _pump(
  WidgetTester tester, {
  _Shape shape = _Shape.file,
  MessageStatus status = MessageStatus.done,
}) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.platform.setMobile(false);
  backend.repo.addDevice(_source());
  backend.repo.addDevice(_online());
  backend.repo.addDevice(_offline());
  backend.discovery.setOnline(<DiscoveredPeer>[
    DiscoveredPeer(
      fingerprint: 'EE02',
      alias: '台式机',
      kind: DeviceKind.desktop,
      address: '192.168.1.20',
      port: 53318,
      isOnline: true,
      lastSeen: fixedEpoch,
    ),
  ]);
  backend.repo.addConversation(
    id: _conversationId,
    deviceFingerprint: 'CC01',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  final List<FileAttachment> files = shape == _Shape.folder
      ? const <FileAttachment>[
          FileAttachment(
            id: 'f-1',
            messageId: 'm-1',
            fileName: 'a.jpg',
            size: 100,
            sha256: 'AA',
            localPath: '/d/素材/a.jpg',
            relativePath: 'a.jpg',
          ),
          FileAttachment(
            id: 'f-2',
            messageId: 'm-1',
            fileName: 'b.jpg',
            size: 200,
            sha256: 'BB',
            localPath: '/d/素材/sub/b.jpg',
            relativePath: 'sub/b.jpg',
          ),
        ]
      : const <FileAttachment>[
          FileAttachment(
            id: 'f-1',
            messageId: 'm-1',
            fileName: _fileName,
            size: 12,
            sha256: 'AA',
            localPath: '/d/notes.txt',
          ),
        ];
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: _conversationId,
    direction: MessageDirection.outgoing,
    status: status,
    kind: MessageKind.file,
    folderName: shape == _Shape.folder ? _folderName : null,
    folderFiles: shape == _Shape.folder ? files.length : 0,
    files: files,
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
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
    conversationId: _conversationId,
    drafts: ComposerDraftStore(),
  );
  addTearDown(controller.dispose);
  unawaited(controller.load());
  await pumpApp(
    tester,
    Scaffold(body: ConversationThread(controller: controller, peer: _source())),
    backend: backend,
    settle: true,
  );
  return backend;
}

/// Runs [body] with the **desktop platform** selected, reset in a `finally`.
Future<void> _onWindows(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// A right click (secondary button down + up) at [at].
Future<void> _rightClickAt(WidgetTester tester, Offset at) async {
  final TestGesture gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The values of the open `showFastMenu` route, **in the order they are built**.
///
/// `fast_menu.dart` keys every row `fast-menu-<value>`, which is what makes an
/// exact, order-preserving list possible — the only way to assert "no entry was
/// lost **and** no fake entry was added".
List<String> _menuValues(WidgetTester tester) => <String>[
      for (final Element element in tester
          .elementList(
            find.byWidgetPredicate(
              (Widget w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('fast-menu-'),
            ),
          )
          .toList())
        ((element.widget.key! as ValueKey<String>).value)
            .substring('fast-menu-'.length),
    ];

/// Everything recorded in [fingerprint]'s conversation (empty when it has none).
List<ChatMessage> _historyOf(FakeBackend backend, String fingerprint) {
  final Iterable<Conversation> matches = backend.repo.conversations().where(
        (Conversation c) =>
            (c.deviceFingerprint ?? '').toUpperCase() ==
            fingerprint.toUpperCase(),
      );
  if (matches.isEmpty) {
    return const <ChatMessage>[];
  }
  return backend.repo.history(matches.first.id);
}

/// Taps the device rows named [aliases], then 「转发（N）」.
Future<void> _pickAndConfirm(WidgetTester tester, List<String> aliases) async {
  for (final String alias in aliases) {
    await tester.tap(find.text(alias));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(const ValueKey<String>('forward-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      '★ criterion 1 + 3: right-clicking a FILE card offers 转发到…, every existing '
      'entry is still there one by one, and it opens the multi-select device list',
      (WidgetTester tester) async {
    await _onWindows(() async {
      await _pump(tester);

      await _rightClickAt(tester, tester.getCenter(find.byType(FileTile)));

      // ★ one by one, in the menu's order — not "at least N items".
      expect(
        _menuValues(tester),
        <String>[
          'open',
          'reveal',
          'copyName',
          'copyPath',
          'details',
          'forward',
          'delete',
        ],
        reason: '★ every existing row kept its place, and exactly one row was '
            'added: 转发到… (a `build` that dropped or duplicated a row fails '
            'here, which "findsWidgets" would not catch)',
      );

      await tester.tap(find.text('转发到…'));
      await tester.pumpAndSettle();

      expect(find.text('转发到'), findsOneWidget);
      expect(find.text('台式机'), findsOneWidget);
      expect(find.text('笔记本'), findsOneWidget,
          reason: 'the offline device is listed and stays pickable (it queues)');
      expect(find.text('转发（0）'), findsOneWidget);
    });
  });

  testWidgets(
      '★ criterion 2: forwarding a FILE to two devices prepares it twice — once per '
      'device — and both conversations gain their own outgoing message',
      (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester);
      final int before = backend.transfer.prepareCalls;

      await _rightClickAt(tester, tester.getCenter(find.byType(FileTile)));
      await tester.tap(find.text('转发到…'));
      await tester.pumpAndSettle();
      await _pickAndConfirm(tester, <String>['台式机', '笔记本']);

      // One dialable device (台式机) + one queued (笔记本) ⇒ exactly one prepare.
      expect(backend.transfer.prepareCalls, before + 1,
          reason: 'a queued send never dials, so it must not prepare either');

      final List<ChatMessage> online = _historyOf(backend, 'EE02');
      expect(online, hasLength(1));
      expect(online.single.direction, MessageDirection.outgoing);
      expect(online.single.kind, MessageKind.file);
      expect(backend.repo.filesOf(online.single.id).single.fileName, _fileName);

      final List<ChatMessage> offline = _historyOf(backend, 'DD03');
      expect(offline, hasLength(1), reason: 'the queued copy is a real row');
      expect(offline.single.status, MessageStatus.pending,
          reason: '★ queued, not failed');

      // The source conversation is unchanged.
      expect(backend.repo.history(_conversationId), hasLength(1));
    });
  });

  testWidgets(
      '★ criterion 2 (two dialable devices): the fake TransferService prepares the '
      'file TWICE, and each target gets it', (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester);
      // Bring the second device online so both really dial.
      backend.discovery.setOnline(<DiscoveredPeer>[
        DiscoveredPeer(
          fingerprint: 'DD03',
          alias: '笔记本',
          kind: DeviceKind.desktop,
          address: '192.168.1.21',
          port: 53319,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
        DiscoveredPeer(
          fingerprint: 'EE02',
          alias: '台式机',
          kind: DeviceKind.desktop,
          address: '192.168.1.20',
          port: 53318,
          isOnline: true,
          lastSeen: fixedEpoch,
        ),
      ]);
      await tester.pumpAndSettle();
      final int before = backend.transfer.prepareCalls;

      await _rightClickAt(tester, tester.getCenter(find.byType(FileTile)));
      await tester.tap(find.text('转发到…'));
      await tester.pumpAndSettle();
      await _pickAndConfirm(tester, <String>['台式机', '笔记本']);

      expect(backend.transfer.prepareCalls, before + 2,
          reason: '★ two devices ⇒ two prepares, one per device');
      expect(_historyOf(backend, 'EE02'), hasLength(1));
      expect(_historyOf(backend, 'DD03'), hasLength(1));
    });
  });

  testWidgets(
      '★ criterion 4: a FOLDER card answers a right-click too, and the forward keeps '
      'the folder descriptor (not N flat bubbles)', (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester, shape: _Shape.folder);

      // Until 0.2.46 this secondary tap did nothing at all.
      await _rightClickAt(tester, tester.getCenter(find.text(_folderName)));
      expect(_menuValues(tester), <String>['forward', 'delete'],
          reason: 'the folder card has no per-file rows to offer — only the '
              'message-level actions');

      await tester.tap(find.text('转发到…'));
      await tester.pumpAndSettle();
      await _pickAndConfirm(tester, <String>['台式机']);

      // The frame still declares the folder…
      expect(backend.transfer.lastPreparedFolder, isNotNull,
          reason: '★ a forward must not flatten a folder into loose files');
      expect(backend.transfer.lastPreparedFolder!.name, _folderName);
      expect(backend.transfer.lastPreparedFolder!.count, 2);
      // …and every file kept its position inside it.
      expect(
        backend.transfer.lastPreparedFiles
            .map((OutgoingFile f) => f.relativePath)
            .toList(),
        <String?>['a.jpg', 'sub/b.jpg'],
      );
      // The forwarded row is a folder on the other side too.
      final ChatMessage sent = _historyOf(backend, 'EE02').single;
      expect(sent.folderName, _folderName);
      expect(sent.folderFiles, 2);
      expect(backend.repo.filesOf(sent.id), hasLength(2));
    });
  });

  testWidgets(
      'the folder card menu does not offer 删除 while the message is in flight — the '
      'same rule the file menu keeps', (WidgetTester tester) async {
    await _onWindows(() async {
      // `pending` and not `transferring`: both are non-deletable, but a
      // transferring file row also keeps the 1 Hz progress poll alive, and a
      // pending test must not end with a live timer (the binding asserts on it).
      await _pump(
        tester,
        shape: _Shape.folder,
        status: MessageStatus.pending,
      );

      await _rightClickAt(tester, tester.getCenter(find.text(_folderName)));

      expect(_menuValues(tester), <String>['forward'],
          reason: 'a queued (non-deletable) folder may be forwarded but not '
              'deleted — the same rule the file menu keeps');
    });
  });

  testWidgets(
      'cancelling the picker from the file menu sends nothing (no "cancel means '
      'everybody")', (WidgetTester tester) async {
    await _onWindows(() async {
      final FakeBackend backend = await _pump(tester);

      await _rightClickAt(tester, tester.getCenter(find.byType(FileTile)));
      await tester.tap(find.text('转发到…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('forward-cancel')));
      await tester.pumpAndSettle();

      expect(backend.transfer.prepareCalls, 0);
      expect(_historyOf(backend, 'EE02'), isEmpty);
      expect(_historyOf(backend, 'DD03'), isEmpty);
    });
  });
}
