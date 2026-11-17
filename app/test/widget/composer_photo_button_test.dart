/// 0.2.53 — the composer's 「照片」 button on a phone.
///
/// The ask: the phone composer opens the **system gallery** (the picker with the
/// album drop-down), not a folder tree, and what comes back is sent through
/// exactly the same road as 「文件」. The desktop composer must not gain the
/// button at all.
///
/// What is pinned here, one test per criterion:
///  1. a phone builds the button, and a tap reaches `PlatformPorts.pickMedia`
///     (`pickMediaCalls`, not "a message appeared" — a button wired to `pickFiles`
///     would send the same message and be silently wrong);
///  2. **no phone ⇒ no button** (`findsNothing`). This is the assertion that has
///     to be here: the cheapest way to break the release is for someone to "tidy
///     up" the condition later;
///  3. five picks ⇒ **one** message with **five** attachments (not five messages);
///  4. cancel (an empty list — what the bridge answers when the user backs out) ⇒
///     no message, no error, and nothing left saying 正在准备;
///  5. the attachment names come from the returns paths' base names (a probe: the
///     real photo picker may normalise the display name, and the app side has to
///     be right before that difference can be judged on a device).
///
/// The thread is mounted **directly** (the same way `retry_all_test.dart` does),
/// so nothing about the shell's layout decides whether the button exists — the
/// platform port does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/media_file_name.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

const String _fingerprint = 'PH53';
const String _conversationId = 'c-photo';

PeerDevice _peer() => const PeerDevice(
      fingerprint: _fingerprint,
      alias: 'Pia',
      kind: DeviceKind.desktop,
      isOnline: true,
      lastPort: 53317,
    );

/// The photo button, found by its **semantic** label.
///
/// By label rather than by icon on purpose: the label is what a long press and a
/// screen reader announce, and it is the part the task names (「照片」). The icon
/// is a styling choice (`Icons.photo_library_outlined`) and may follow the theme
/// later without the promise moving.
final Finder _photoButton = find.byTooltip('照片');

void main() {
  late FakeBackend backend;
  late TransferOrchestrator orchestrator;
  late ConversationController controller;

  setUp(() {
    backend = FakeBackend();
    backend.repo.addConversation(
      id: _conversationId,
      deviceFingerprint: _fingerprint,
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    orchestrator = TransferOrchestrator(
      repo: backend.repo,
      transfer: backend.transfer,
    );
    controller = ConversationController(
      repo: backend.repo,
      orchestrator: orchestrator,
      platform: backend.platform,
      ids: backend.ids,
      clock: backend.clock,
      conversationId: _conversationId,
      dismissals: UnsentDismissalStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    orchestrator.dispose();
    backend.dispose();
  });

  /// Mounts the real thread under the fake scope, at a phone-ish width.
  Future<void> mount(WidgetTester tester) async {
    useSurfaceSize(tester, const Size(420, 900));
    await controller.load();
    await pumpApp(
      tester,
      Scaffold(body: ConversationThread(controller: controller, peer: _peer())),
      backend: backend,
      settle: true,
    );
  }

  testWidgets(
      '★ 1: a phone builds 「照片」, and one tap calls pickMedia (not pickFiles) '
      'and sends what it returned', (WidgetTester tester) async {
    // A phone: the gallery bridge exists.
    backend.platform.setSupportsPickMedia(true);
    backend.platform.setMediaPick(<String>['/cache/picked/IMG_0001.jpg']);
    await mount(tester);

    // 同尺寸、同形状: the new button is the same control as the attachment one,
    // so the composer's rhythm does not change. (Material 3 lays an `IconButton`
    // out at 40×40 with the tap area padded to 48 — the shipped 附件 button's
    // numbers, which is the point: this one adds no new geometry.)
    final Size photoSize = tester.getSize(_photoButton);
    final Size attachSize = tester.getSize(find.byTooltip('发送附件'));
    expect(photoSize, attachSize,
        reason: 'the photo button must be the attach button\'s twin, not a '
            'smaller icon squeezed in beside it');
    // …and it sits next to the file door, not across the composer.
    expect(
      tester.getCenter(_photoButton).dx,
      greaterThan(tester.getCenter(find.byTooltip('发送附件')).dx),
      reason: '「照片」 belongs immediately to the right of the attachment button',
    );

    // The tap area is the padded one, not the 40 dp visual box: a press 4 dp
    // below the icon's bottom edge still opens the picker. This is the 48 dp
    // promise the phone rows are held to, measured the way a thumb finds it.
    await tester.tapAt(tester.getCenter(_photoButton) +
        Offset(0, photoSize.height / 2 + 2));
    await tester.pumpAndSettle();

    expect(backend.platform.pickMediaCalls, 1,
        reason: 'the tap target is the padded 48 dp box, not the 40 dp icon');
  });

  testWidgets('★ 1b: one tap on the icon calls pickMedia once and sends',
      (WidgetTester tester) async {
    backend.platform.setSupportsPickMedia(true);
    backend.platform.setMediaPick(<String>['/cache/picked/IMG_0001.jpg']);
    await mount(tester);

    await tester.tap(_photoButton);
    await tester.pumpAndSettle();

    expect(backend.platform.pickMediaCalls, 1,
        reason: 'the button must open the gallery, i.e. call the port that opens '
            'it — a message alone would not prove which picker ran');
    final List<ChatMessage> messages = backend.repo.history(_conversationId);
    expect(messages, hasLength(1));
  });

  testWidgets(
      '★ 2: no gallery bridge ⇒ NO 「照片」 button (the desktop composer does not '
      'change)', (WidgetTester tester) async {
    // The default fake is the desktop answer, and so is production:
    // `SystemPlatformPorts.supportsPickMedia` is `AndroidFilePicker.isSupported`,
    // which is `Platform.isAndroid`. Leaving it unset here is exactly that claim.
    await mount(tester);

    expect(
      _photoButton,
      findsNothing,
      reason: 'the desktop composer must be byte-for-byte what it was: no '
          '「照片」 button may appear on Windows / macOS / Linux',
    );
  });

  testWidgets(
      '★ 2b: the gate is the port capability, not `isMobile` (a phone-shaped tree '
      'with no bridge still shows nothing)', (WidgetTester tester) async {
    // `isMobile` is Android **or** iOS; the gallery bridge is Android only. This
    // asserts the button follows the capability — the same rule
    // 「在下载里查看」 follows — so a later "simplify" to `isMobile` goes red.
    backend.platform.setMobile(true);
    await mount(tester);

    expect(_photoButton, findsNothing);
  });

  testWidgets(
      '★ 3: five photos ⇒ ONE message carrying FIVE attachments',
      (WidgetTester tester) async {
    const List<String> picked = <String>[
      '/cache/picked/a/IMG_1.jpg',
      '/cache/picked/b/IMG_2.jpg',
      '/cache/picked/c/IMG_3.jpg',
      '/cache/picked/d/IMG_4.jpg',
      '/cache/picked/e/IMG_5.jpg',
    ];
    backend.platform.setSupportsPickMedia(true);
    backend.platform.setMediaPick(picked);
    await mount(tester);

    await tester.tap(_photoButton);
    await tester.pumpAndSettle();

    final List<ChatMessage> messages = backend.repo.history(_conversationId);
    expect(messages, hasLength(1),
        reason: 'a multi-select is one message with N attachments — five '
            'separate messages would be five bubbles to scroll through');
    final List<FileAttachment> files =
        backend.repo.filesOf(messages.single.id);
    expect(files, hasLength(5));
    expect(
      files.map((FileAttachment f) => f.localPath),
      picked,
      reason: 'the same five paths, in the order the picker answered',
    );
  });

  testWidgets(
      '★ 4: cancel (empty answer) ⇒ no message, no error, no leftover 正在准备',
      (WidgetTester tester) async {
    // The bridge answers an empty list when the user backs out — on the native
    // side `onActivityResult` returns `emptyList<String>()` for
    // `RESULT_CANCELED`, `data == null` or an empty selection, and
    // `AndroidFilePicker.pickMedia` maps that to an empty `List<String>`.
    backend.platform.setSupportsPickMedia(true);
    backend.platform.setMediaPick(const <String>[]);
    await mount(tester);

    await tester.tap(_photoButton);
    await tester.pumpAndSettle();

    expect(backend.platform.pickMediaCalls, 1, reason: 'the picker did open');
    expect(backend.repo.history(_conversationId), isEmpty,
        reason: 'cancelling sends nothing');
    expect(
      find.textContaining('正在准备'),
      findsNothing,
      reason: 'the preparing caption must not survive a cancel',
    );
    expect(find.textContaining('失败'), findsNothing,
        reason: 'cancelling is a decision, not an error');
    // The composer is usable again — i.e. `_preparing` was cleared.
    expect(_photoButton, findsOneWidget);
  });

  testWidgets(
      '★ 5: the attachment names are the picked paths\' base names '
      '(the probe for a photo picker that normalises display names)',
      (WidgetTester tester) async {
    backend.platform.setSupportsPickMedia(true);
    backend.platform.setMediaPick(<String>[
      '/cache/picked/9f2/IMG_20260107_121500.jpg',
      '/data/user/0/io.github.kk339.lanlink/cache/picked/1a3/假期 001.png',
    ]);
    await mount(tester);

    await tester.tap(_photoButton);
    await tester.pumpAndSettle();

    final List<ChatMessage> messages = backend.repo.history(_conversationId);
    expect(messages, hasLength(1));
    expect(
      backend.repo.filesOf(messages.single.id).map((FileAttachment f) => f.fileName),
      <String>['IMG_20260107_121500.jpg', '假期 001.png'],
      reason: 'the app keeps the name the platform handed back — the cache '
          'directory the copy lands in must never leak into the bubble',
    );
  });

  testWidgets(
      '★ 7: a batch the system named with numbers arrives with readable names '
      '(one message, two photos taken in the same second)', (WidgetTester tester) async {
    // The user's real report (0.2.53): the picker calls a photo
    // `1000055362.jpg`. The bridge brings the capture time back, the naming rules
    // turn it into a stamp, and the **message** must show the readable name —
    // this is the end of the chain the pure tests start.
    final int stamp = DateTime(2026, 11, 2, 15, 30, 12).millisecondsSinceEpoch;
    backend.platform.setSupportsPickMedia(true);
    backend.platform.setMediaPickDetails(<PickedMedia>[
      PickedMedia(
        path: '/cache/picked/aa/1000055362.jpg',
        displayName: '1000055362.jpg',
        takenAtMillis: stamp,
        mime: 'image/jpeg',
      ),
      PickedMedia(
        path: '/cache/picked/bb/1000055361.jpg',
        displayName: '1000055361.jpg',
        takenAtMillis: stamp,
        mime: 'image/jpeg',
      ),
    ]);
    await mount(tester);

    await tester.tap(_photoButton);
    await tester.pumpAndSettle();

    final List<ChatMessage> messages = backend.repo.history(_conversationId);
    expect(messages, hasLength(1));
    final List<FileAttachment> files =
        backend.repo.filesOf(messages.single.id);
    expect(files, hasLength(2));
    expect(
      files.map((FileAttachment f) => f.fileName),
      <String>['20261102_153012.jpg', '20261102_153012-2.jpg'],
      reason: 'readable names, and the second photo taken in the same second '
          'does not collide with the first',
    );
    expect(
      files.map((FileAttachment f) => f.localPath),
      <String>[
        '/cache/picked/aa/20261102_153012.jpg',
        '/cache/picked/bb/20261102_153012-2.jpg',
      ],
      reason: 'the rename happens in the copy\'s own directory, and the path '
          'the message points at is the renamed one',
    );
  });
}
