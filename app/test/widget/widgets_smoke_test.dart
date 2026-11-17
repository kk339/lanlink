/// Smoke tests for the four reskinned shared widgets and the new `ui/format.dart`
/// display helpers (T02).
///
/// They assert the copy/derivation contract, not the pixels: which icon vs
/// thumbnail a row shows, the `[类型]` prefix, the date-separator wording, and
/// that the reskinned bubble and the two new `EmptyState` constructors render
/// without error.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/format.dart';
import 'package:lanlink_app/ui/widgets/accept_toggle.dart';
import 'package:lanlink_app/ui/widgets/empty_state.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';
import 'package:lanlink_app/ui/widgets/message_bubble.dart';
import 'package:lanlink_app/ui/widgets/type_icon.dart';

import '../support/pump_app.dart';

ChatMessage _message({
  MessageDirection direction = MessageDirection.outgoing,
  MessageStatus status = MessageStatus.done,
}) =>
    ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      direction: direction,
      kind: MessageKind.file,
      createdAt: DateTime.utc(2026, 1, 7, 12),
      updatedAt: DateTime.utc(2026, 1, 7, 12),
      status: status,
    );

FileAttachment _file(String name, {String? mime, String? path}) =>
    FileAttachment(
      id: 'f-$name',
      messageId: 'm1',
      fileName: name,
      size: 2048,
      mime: mime,
      sha256: '00',
      localPath: path,
    );

void main() {
  group('ui/format.dart display helpers', () {
    test('fileSummaryPrefix maps only image / video specially', () {
      expect(fileSummaryPrefix('IMG_403.jpg'), '[图片]');
      expect(fileSummaryPrefix('x.png'), '[图片]');
      expect(fileSummaryPrefix('video.mp4'), '[视频]');
      expect(fileSummaryPrefix('song.mp3'), '[文件]');
      expect(fileSummaryPrefix('report.pdf'), '[文件]');
      expect(fileSummaryPrefix('a.zip'), '[文件]');
      expect(fileSummaryPrefix('x', mime: 'image/png'), '[图片]');
      expect(fileSummaryPrefix('2 files'), '[文件]');
    });

    test('directionText gives 收到 / 发出', () {
      expect(directionText(MessageDirection.incoming), '收到');
      expect(directionText(MessageDirection.outgoing), '发出');
    });

    test('shortFingerprint normalises to upper-case hex, first 8', () {
      expect(shortFingerprint('ab:cd:ef:12:34:56:78:90'), 'ABCDEF12');
      expect(shortFingerprint('short'), 'SHORT');
    });

    test('dateSeparatorText: 今天 / 昨天 / yyyy/MM/dd', () {
      final DateTime now = DateTime(2026, 1, 7, 10);
      expect(dateSeparatorText(now, DateTime(2026, 1, 7, 9)), '今天');
      expect(dateSeparatorText(now, DateTime(2026, 1, 6, 23)), '昨天');
      expect(dateSeparatorText(now, DateTime(2025, 12, 14)), '2025/12/14');
    });
  });

  testWidgets('MessageBubble renders a non-image file row + its status',
      (WidgetTester tester) async {
    await pumpApp(
      tester,
      MessageBubble(
        message: _message(),
        files: <FileAttachment>[_file('report.pdf', path: '/src/report.pdf')],
      ),
      settle: true,
    );
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('MessageBubble: an image attachment uses a thumbnail slot',
      (WidgetTester tester) async {
    await pumpApp(
      tester,
      MessageBubble(
        message: _message(),
        files: <FileAttachment>[
          _file('photo.png', mime: 'image/png', path: '/src/photo.png'),
        ],
      ),
      settle: true,
    );
    // No bytes preset → the thumbnail falls back to the icon, no exception.
    expect(find.byType(FileThumbnail), findsOneWidget);
    expect(find.byType(TypeIcon), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('FileTile: an image with a path gets a thumbnail slot',
      (WidgetTester tester) async {
    await pumpApp(
      tester,
      const FileTile(fileName: 'photo.png', size: 2048, path: '/src/photo.png'),
      settle: true,
    );
    expect(find.byType(FileThumbnail), findsOneWidget);
  });

  testWidgets('FileTile: a non-image keeps the type icon',
      (WidgetTester tester) async {
    await pumpApp(
      tester,
      const FileTile(fileName: 'report.pdf', size: 2048),
      settle: true,
    );
    expect(find.byType(FileThumbnail), findsNothing);
    expect(find.byType(TypeIcon), findsOneWidget);
  });

  testWidgets('EmptyState: the two new named constructors render their copy',
      (WidgetTester tester) async {
    await pumpApp(tester, const EmptyState.rightPlaceholder(), settle: true);
    expect(find.text('左侧选一台设备开始'), findsOneWidget);

    await pumpApp(tester, const EmptyState.conversationFiles(), settle: true);
    expect(find.text('本会话还没有文件'), findsOneWidget);
  });

  testWidgets('AcceptToggle renders the labelled switch',
      (WidgetTester tester) async {
    // `SwitchListTile` reaches an `InkWell` (it has an `onTap`), which asserts a
    // `Material` ancestor; pumped bare under `MaterialApp.home` there is none, so
    // mount it the way the app does — inside a `Scaffold` (which provides the
    // `Material`). This is a harness concern, not a component defect.
    await pumpApp(
      tester,
      Scaffold(
        body: AcceptToggle(accepting: false, onChanged: (bool value) {}),
      ),
      settle: true,
    );
    expect(find.text('接收模式'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
  });
}
