/// Widget tests for the 0.2.23 "已收到，但没能导出" note.
///
/// **The defect these pin down.** When Android refused to export a received file
/// into `Download/lanlink`, `ReceivedFilePublisher` recorded the reason and moved
/// on: the row was still written at `done` and the bubble still read 已完成. So
/// the user was told the file had arrived in 下载 while it was actually inside
/// the app's private directory — the exact "保存在哪在撒谎" shape this release
/// removes.
///
/// Both directions are asserted, because a note that shows on **every** receive is
/// as wrong as one that never shows: the second test is the reverse check.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';

import '../support/pump_app.dart';

/// The sentence the bubble must carry when the export failed.
const String kPublishNote = '已收到，但没能导出到「下载」';

PeerDevice _peer(String fingerprint, {required String alias}) => PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// Seeds one conversation with one **received** file whose transfer row carries
/// [publishError] (`null` = a normal, exported receive).
///
/// The `transfers.error` column is where `SessionStore.recordIncomingFile` stores
/// `IncomingFileSpec.publishError`, so seeding it here is the same seam the
/// orchestrator writes through — not a shortcut around the feature.
FakeBackend seedReceivedFile({String? publishError}) {
  final FakeBackend backend = FakeBackend();
  backend.repo.addConversation(
    id: 'c-note',
    deviceFingerprint: 'AA11',
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-note',
    conversationId: 'c-note',
    direction: MessageDirection.incoming,
    status: MessageStatus.done,
    createdAt: fixedEpoch,
    files: <FileAttachment>[
      FileAttachment(
        id: 'f-note',
        messageId: 'm-note',
        fileName: 'clip.mp4',
        size: 10,
        sha256: 'AABB',
        localPath: '/data/user/0/io.github.kk339.lanlink/files/'
            'lanlink/received/clip.mp4',
      ),
    ],
  );
  backend.repo.addTransfer(
    TransferProgress(
      fileId: 'f-note',
      bytesDone: 10,
      bytesTotal: 10,
      error: publishError,
    ),
  );
  return backend;
}

void main() {
  testWidgets('a failed export shows the note under the received bubble',
      (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = seedReceivedFile(publishError: '空间不足');
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AA11', alias: 'Alice'),
    );

    expect(find.textContaining(kPublishNote), findsOneWidget);
    // The three facts the sentence must carry: received, not in 下载, still
    // reachable from inside the app.
    expect(find.textContaining('文件在应用内部'), findsOneWidget);
    expect(find.textContaining('分享'), findsOneWidget);
  });

  testWidgets('a normal receive shows no note at all', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(1200, 900));
    final FakeBackend backend = seedReceivedFile();
    addTearDown(backend.dispose);

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AA11', alias: 'Alice'),
    );

    expect(find.textContaining(kPublishNote), findsNothing);
    // The bubble is there — the absence above must be "no note", not "no bubble".
    expect(find.textContaining('clip.mp4'), findsWidgets);
  });
}
