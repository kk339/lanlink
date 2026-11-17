/// **One** judgement of "is this attachment still on disk?" — and the tap that
/// no longer dies silently (0.2.48).
///
/// Two defects, one cause: three surfaces each had their own idea of whether a
/// file existed, and the two that did not check acted on the answer anyway.
///
/// * the **timeline** only probed `outgoing` messages in `failed` / `canceled`
///   (through `canResend`), so a `done` message whose source was gone drew a
///   healthy, clickable row;
/// * the **文件 tab** never probed at all — every row stayed tappable forever;
/// * 「打开」 in both places called `platform.openFile` blind: no `exists`
///   pre-check and no `catch`. On Android the bridge answers
///   `result.error("open_missing")` (which the Dart adapter does not swallow) and
///   on Windows `explorer <missing>` simply does nothing — so the tap produced
///   **no visible effect on either platform**.
///
/// This is not an edge case: on Android a picked or shared file is a **cache
/// copy** that is deleted once the send succeeds, while the attachment row keeps
/// pointing at it. Every successfully sent file is in this state.
///
/// The state below is therefore the ordinary one, not a contrived one: a
/// `done` outgoing file message whose `localPath` no longer exists.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/conversation_files.dart';
import 'package:lanlink_app/ui/panes/device_profile.dart';
import 'package:lanlink_app/ui/shell/shell_module.dart';
import 'package:lanlink_app/ui/theme.dart';
import 'package:lanlink_app/ui/widgets/file_tile.dart';

import '../support/fakes.dart';
import '../support/pump_app.dart';

const String _conv = 'c-src';
const String _fingerprint = 'EE11';
const String _gonePath = '/cache/picked-copy.bin';
const String _goneName = 'picked-copy.bin';

/// What the timeline says about an outgoing message whose source is gone (A2-18).
const String _kTimelineLabel = '源文件不可用';

/// What the two list surfaces say about the same file (FileTile's own label).
const String _kListLabel = '文件已不在原位置';

/// What a tap says when the file is not there.
const String _kTapNotice = '文件已不在原位置，无法打开';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: '小甲',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// A conversation with one **`done`, outgoing** file message.
///
/// [gone] `true` puts the source off disk — the state every successful Android
/// send leaves behind, because the cache copy is discarded after the upload.
Future<FakeBackend> _seed(WidgetTester tester, {bool gone = true}) async {
  useSurfaceSize(tester, const Size(1400, 1000));
  final FakeBackend backend = FakeBackend();
  addTearDown(backend.dispose);
  backend.repo.addDevice(_peer());
  backend.repo.addConversation(
    id: _conv,
    deviceFingerprint: _fingerprint,
    createdAt: fixedEpoch,
    lastMessageAt: fixedEpoch,
  );
  backend.repo.addMessage(
    id: 'm-1',
    conversationId: _conv,
    direction: MessageDirection.outgoing,
    status: MessageStatus.done,
    kind: MessageKind.file,
    files: const <FileAttachment>[
      FileAttachment(
        id: 'f-1',
        messageId: 'm-1',
        fileName: _goneName,
        size: 2048,
        sha256: 'AA',
        localPath: _gonePath,
      ),
    ],
    createdAt: fixedEpoch,
    updatedAt: fixedEpoch,
  );
  if (gone) {
    backend.platform.setExists(_gonePath, false);
  }
  return backend;
}

/// Opens the right pane's `文件` tab.
Future<void> _openFilesTab(WidgetTester tester) async {
  await tester.tap(find.text(RightTab.files.label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      '★ criterion 1 (timeline): a message whose source is gone is marked, and '
      'tapping its row SAYS SO instead of doing nothing',
      (WidgetTester tester) async {
    final FakeBackend backend = await _seed(tester);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer(),
    );

    // The row is already honest by the time it is drawn: the probe runs for
    // `done` messages too (it used to look only at failed/canceled ones).
    expect(find.text(_kTimelineLabel), findsWidgets,
        reason: 'a `done` message whose file is gone must be marked');

    await tester.tap(find.text(_goneName));
    await tester.pumpAndSettle();

    expect(find.text(_kTapNotice), findsOneWidget,
        reason: 'the tap must answer — silence is the reported defect');
    expect(backend.platform.opened, isEmpty,
        reason: 'and it must not call the platform with a missing path');

    // Let the notice retire before the tree goes away.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
      '★ criterion 1 (文件 tab): same judgement, same answer — dimmed row, and a '
      'tap still explains itself',
      (WidgetTester tester) async {
    final FakeBackend backend = await _seed(tester);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer(),
    );
    await _openFilesTab(tester);

    final Finder row = find.descendant(
      of: find.byType(ConversationFiles),
      matching: find.widgetWithText(FileTile, _goneName),
    );
    expect(row, findsOneWidget);
    expect(find.text(_kListLabel), findsWidgets,
        reason: 'this page used to probe nothing and draw a normal row');

    // Tap the name, i.e. a point the row's own subtree really owns — the wrapper
    // this release adds around an unavailable `FileTile` is what receives it.
    await tester.tap(find.text(_goneName));
    await tester.pumpAndSettle();

    expect(find.text(_kTapNotice), findsOneWidget);
    expect(backend.platform.opened, isEmpty);

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
      '★ criterion 1 (control): a file that IS there behaves exactly as before — '
      'it opens, and nothing is marked',
      (WidgetTester tester) async {
    final FakeBackend backend = await _seed(tester, gone: false);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer(),
    );

    expect(find.text(_kTimelineLabel), findsNothing);
    expect(find.text(_kListLabel), findsNothing);

    await tester.tap(find.text(_goneName));
    await tester.pumpAndSettle();

    expect(backend.platform.opened, <String>[_gonePath],
        reason: 'a present file opens through the same port call as before');
    expect(find.text(_kTapNotice), findsNothing);
  });

  testWidgets(
      '★ criterion 2: the same file is judged the same way by 消息 / 文件 tab / '
      '设备资料 / 最近文件 — four surfaces, one rule',
      (WidgetTester tester) async {
    final FakeBackend backend = await _seed(tester);

    // 1. 消息 (the default right tab).
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer(),
    );
    expect(find.text(_kTimelineLabel), findsWidgets, reason: '消息 tab');
    // 2. 文件 tab, in the same mounted shell.
    await _openFilesTab(tester);
    expect(find.text(_kListLabel), findsWidgets, reason: '文件 tab');

    // 3. 设备资料 (the pushed page's media wall) — the **fourth** surface, and the
    //    last one that kept its own `exists` probe before 0.2.48. Its broken state
    //    is a glyph (not a label): the card is drawn from `dangerBroken`.
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();
    final Finder profile = find.byType(DeviceProfilePage);
    expect(profile, findsOneWidget);
    // The wall's default filter is 图片; this attachment is a `.bin`.
    await tester.tap(find.descendant(of: profile, matching: find.text('文件')));
    await tester.pumpAndSettle();
    final Iterable<Icon> broken = tester
        .widgetList<Icon>(
            find.descendant(of: profile, matching: find.byType(Icon)))
        .where((Icon icon) => icon.color == dangerBroken);
    expect(broken, isNotEmpty,
        reason: '设备资料 must reach the same verdict as the other three');

    // 4. 最近文件 is a different module, so `ShellPage` has to be mounted again
    //    (it ignores a later `initialModule`). Unmount first, as its doc says.
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialModule: ShellModule.recentFiles,
    );
    expect(find.text(_kListLabel), findsWidgets, reason: '最近文件');
  });

  testWidgets(
      '★ criterion 2 (control): the wall\'s 损毁 state follows the disk — a file '
      'that is there is NOT drawn broken',
      (WidgetTester tester) async {
    // Without this half, "the wall says broken" could equally be a page that
    // always says broken — the assertion would be green for the wrong reason.
    final FakeBackend backend = await _seed(tester, gone: false);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer(),
    );
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();

    final Finder profile = find.byType(DeviceProfilePage);
    await tester.tap(find.descendant(of: profile, matching: find.text('文件')));
    await tester.pumpAndSettle();

    final Iterable<Icon> broken = tester
        .widgetList<Icon>(
            find.descendant(of: profile, matching: find.byType(Icon)))
        .where((Icon icon) => icon.color == dangerBroken);
    expect(broken, isEmpty,
        reason: 'a present source must render its card, not the 损毁 glyph');
  });
}
