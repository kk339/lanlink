/// 0.2.27 — the **desktop / compact** way into 设备资料 (the 图片 / 视频 / 文件
/// media wall).
///
/// The user's report: *"电脑端的会话里，能做成手机那样的文件分类吗，手机分了图片
/// 视频文件来着，电脑这只有一个文件"*. The wall already existed
/// (`DeviceProfilePage`), but its only door was the phone bar's
/// (`phone_shell.dart`), so on a desktop the capability was **unreachable** and
/// the `文件` tab read as the end of the story.
///
/// These tests pin the four things that could go wrong with adding the second
/// door:
///
///  1. the entry exists on a desktop conversation header, opens the **same** page
///     with the three filters;
///  2. it is **not** there when no conversation is selected (the ⋮'s own
///     condition — a button with nothing to open must not be painted);
///  3. the three filters show the **seeded** contents, counted — not just "the
///     labels are drawn" — and those counts are the phone's counts, because both
///     doors lead to one implementation;
///  4. a phone still has exactly **one** 媒体与文件, and a long peer name still
///     reads in the desktop header instead of being squeezed out.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/data/fake/scenarios.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/ui/panes/device_profile.dart';
import 'package:lanlink_app/ui/shell/detail_pane.dart';
import 'package:lanlink_app/ui/widgets/file_thumbnail.dart';

import '../support/pump_app.dart';

/// The desktop surface the brief names: 1400×1000 resolves to `ShellLayout.wide`
/// (rail 168 + seam 8 + list 320 + seam 8 ⇒ an 896-wide right pane).
const Size _desktop = Size(1400, 1000);

/// A dialable peer for `initialPeer` — without one no conversation opens, and
/// the header (where the entry lives) is never built.
PeerDevice _peer(String fingerprint,
        {required String alias, bool online = false}) =>
    PeerDevice(
      fingerprint: fingerprint,
      alias: alias,
      kind: DeviceKind.desktop,
      isOnline: online,
      lastPort: 53317,
    );

/// The wall's **card count** for the filter currently selected.
///
/// Scoped to [DeviceProfilePage] on purpose: the conversation thread below the
/// pushed route is still in the tree and has thumbnails of its own, so an
/// unscoped `find.byType(FileThumbnail)` would count the thread's cards too.
int _wallCards(WidgetTester tester) => tester
    .widgetList<FileThumbnail>(
      find.descendant(
        of: find.byType(DeviceProfilePage),
        matching: find.byType(FileThumbnail),
      ),
    )
    .length;

/// Taps one of the three wall filters (`图片` / `视频` / `文件`).
Future<void> _tapFilter(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byType(DeviceProfilePage),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ── 1. the entry, and what it opens ──────────────────────────────────────

  testWidgets(
      '1400×1000 desktop: the conversation header carries 媒体与文件, and it opens '
      'the three-filter wall', (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    // RED before 0.2.27: a desktop conversation had no way into the wall at all.
    final Finder entry = find.byTooltip('媒体与文件');
    expect(entry, findsOneWidget,
        reason: 'the desktop conversation needs the same door the phone has');

    // The claim the user made — "电脑这只有一个文件" — is about the `消息 / 文件`
    // tab bar. It is still there; the point is that it is no longer the *only*
    // view of this device's files.
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(DeviceProfilePage), findsOneWidget);
    // The page's title is the header's own name — one peer, one resolution rule.
    expect(
      find.descendant(
          of: find.byType(AppBar), matching: find.text('Alice Laptop')),
      findsOneWidget,
    );
    // Exactly the three filters, reused from the phone page (no 文字).
    for (final String label in <String>['图片', '视频', '文件']) {
      expect(
        find.descendant(
            of: find.byType(DeviceProfilePage), matching: find.text(label)),
        findsOneWidget,
        reason: '$label filter missing on the desktop wall',
      );
    }
    expect(find.text('文字'), findsNothing);
  });

  testWidgets('no conversation selected ⇒ no 媒体与文件 (the ⋮\'s own condition)',
      (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    // No `initialPeer`: the right pane is the placeholder, exactly as when the
    // user has just launched the app or archived the open conversation.
    await pumpShell(tester, backend: backend, settle: true);

    expect(find.byTooltip('媒体与文件'), findsNothing,
        reason: 'nothing is selected, so there is no peer to show a wall for');
    // …and neither is the ⋮, which is the company the entry keeps.
    //
    // **Scoped to the detail pane (0.2.56).** The middle pane's module header now
    // carries a ⋮ of its own (重新扫描 / 手动填写 IP 连接), with the same tooltip —
    // an unscoped `byTooltip('更多')` would match the wrong one and this assertion
    // would flip to "there are two" for a reason that has nothing to do with the
    // entry it is guarding.
    expect(_detailMenu(), findsNothing);
  });

  // ── 2. the three filters, by their seeded contents ───────────────────────

  testWidgets(
      'the three filters carry the seeded files — 1 图片 / 1 视频 / 1 文件 — not '
      'just three labels', (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    // E20's bound conversation: photo.png (image), clip.mp4 (video),
    // notes.pdf (neither ⇒ 文件). One of each, so a filter that lost its
    // predicate would be caught by the count.
    final FakeBackend backend = Scenarios.e20ConversationFiles();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('E2000020', alias: 'Eve Laptop', online: true),
    );
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();

    // The wall opens on 图片.
    expect(_wallCards(tester), 1, reason: 'photo.png belongs to 图片');

    await _tapFilter(tester, '视频');
    expect(_wallCards(tester), 1, reason: 'clip.mp4 belongs to 视频');

    await _tapFilter(tester, '文件');
    expect(_wallCards(tester), 1,
        reason: 'notes.pdf is neither image nor video ⇒ 文件');

    // Back to 图片: the switch is not one-way.
    await _tapFilter(tester, '图片');
    expect(_wallCards(tester), 1);
  });

  testWidgets(
      'a filter with nothing in it says so — E16 has an image and a clip but no '
      'document', (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();

    expect(_wallCards(tester), 1, reason: 'photo.png');

    await _tapFilter(tester, '视频');
    expect(_wallCards(tester), 1, reason: 'clip.mp4');

    await _tapFilter(tester, '文件');
    expect(_wallCards(tester), 0, reason: 'E16 carries no document');
    expect(find.text('这里还没有文件'), findsOneWidget);
  });

  // ── 3. the phone is untouched ────────────────────────────────────────────

  testWidgets(
      '600×1200 phone: still exactly ONE 媒体与文件 — the desktop entry must not '
      'add a second', (WidgetTester tester) async {
    useSurfaceSize(tester, const Size(600, 1200));
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    // The narrow shell draws no header row (`DetailPane.showBack`), so the bar's
    // entry is the only one. `findsOneWidget` here is the regression guard for
    // "two identical buttons appeared".
    expect(find.byTooltip('媒体与文件'), findsOneWidget);

    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsOneWidget);
    // Same page, same counts as the desktop: one implementation, two doors.
    expect(_wallCards(tester), 1);
    await _tapFilter(tester, '视频');
    expect(_wallCards(tester), 1);
    await _tapFilter(tester, '文件');
    expect(_wallCards(tester), 0);
    expect(find.text('这里还没有文件'), findsOneWidget);
  });

  // ── 4. a long peer name must not be squeezed out ─────────────────────────

  testWidgets(
      '40-character peer name on 1400: the header neither overflows nor hides the '
      'name behind the two buttons', (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    // Exactly 40 characters, all CJK — the widest plausible alias at one em each.
    final String longAlias = '超长对端设备名称' * 5;
    expect(longAlias.length, 40);

    final FakeBackend backend = FakeBackend(
      devices: <PeerDevice>[
        PeerDevice(
          fingerprint: 'LONG0001',
          alias: longAlias,
          kind: DeviceKind.desktop,
          lastPort: 53317,
        ),
      ],
    );
    addTearDown(backend.dispose);
    final Conversation conversation = backend.repo.addConversation(
      id: 'c-long',
      deviceFingerprint: 'LONG0001',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    backend.repo.addMessage(
      id: 'm-long',
      conversationId: conversation.id,
      direction: MessageDirection.incoming,
      status: MessageStatus.done,
      createdAt: fixedEpoch,
      files: <FileAttachment>[
        FileAttachment(
          id: 'f-long',
          messageId: 'm-long',
          fileName: 'photo.png',
          size: 2048,
          sha256: 'AA',
          mime: 'image/png',
          localPath: '/received/photo.png',
        ),
      ],
    );

    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('LONG0001', alias: longAlias),
    );

    // No `RenderFlex overflowed` / clipped-text exception anywhere.
    expect(tester.takeException(), isNull);

    // Scoped to the **right pane**: the middle pane's device row shows the same
    // alias, and the assertion below is about the *header*'s column.
    final Finder name = find.descendant(
      of: find.byType(DetailPane),
      matching: find.text(longAlias),
    );
    expect(name, findsOneWidget);

    // `didExceedMaxLines == false` is the strongest reading of "名字仍可读": the
    // whole 40 characters are laid out, not ellipsised away.
    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(name);
    final Size nameSize = tester.getSize(name);
    // Reported in the test log so the numbers are on record (see the round's
    // report): the name column, and the two 48dp tap targets right of it.
    debugPrint('[0.2.27] 40-char alias @1400×1000: name box '
        '${nameSize.width.toStringAsFixed(1)}×'
        '${nameSize.height.toStringAsFixed(1)}, '
        'ellipsised=${paragraph.didExceedMaxLines}');
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: '40 chars fit the 896-wide right pane; the entry must not eat '
            'the name');
    expect(nameSize.width, greaterThan(300),
        reason: 'the name keeps a real column, not a sliver');

    // The entry sits immediately left of the ⋮ and measures **exactly what the
    // ⋮ does**: M3's `IconButton` box is 40×40 painted inside the framework's
    // 48dp padded tap target, which is why the pair reads as one cluster and why
    // the header's height does not change. (Asserting "≥48" here would be
    // asserting against M3, not against this change — the existing ⋮ is 40 too.)
    final Size entrySize = tester.getSize(find.byTooltip('媒体与文件'));
    final Size menuSize = tester.getSize(_detailMenu());
    debugPrint('[0.2.27] 媒体与文件 ${entrySize.width}×${entrySize.height}, '
        '更多 ${menuSize.width}×${menuSize.height}');
    expect(entrySize, menuSize,
        reason: 'the new entry must not be a differently-sized button than the ⋮');
    expect(entrySize.width, greaterThanOrEqualTo(40));
    expect(
      tester.getCenter(find.byTooltip('媒体与文件')).dx,
      lessThan(tester.getCenter(_detailMenu()).dx),
      reason: 'the entry is to the LEFT of the ⋮, as on the phone bar',
    );
    // Both are right-aligned: the ⋮ owns the pane's trailing edge.
    expect(tester.getCenter(_detailMenu()).dx,
        greaterThan(tester.getCenter(name).dx));

    // And the long name does not stop the entry from working.
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsOneWidget);
  });

  // ── 5. both ways back ────────────────────────────────────────────────────

  testWidgets('the ← button and Esc both return to the conversation',
      (WidgetTester tester) async {
    useSurfaceSize(tester, _desktop);
    final FakeBackend backend = Scenarios.e16SelectionSync();
    addTearDown(backend.dispose);
    await pumpShell(
      tester,
      backend: backend,
      settle: true,
      initialPeer: _peer('AAAA1111', alias: 'Alice Laptop', online: true),
    );

    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsOneWidget);
    // A pushed route ⇒ the AppBar draws its own ← (the desktop's mouse route back).
    expect(find.byType(BackButton), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsNothing);
    expect(find.byTooltip('媒体与文件'), findsOneWidget,
        reason: 'we are back on the conversation, entry and all');

    // …and again, this time with the keyboard: Esc is the desktop's "←".
    await tester.tap(find.byTooltip('媒体与文件'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceProfilePage), findsNothing,
        reason: 'Esc pops the page (no system back button on a desktop)');
    expect(find.byTooltip('媒体与文件'), findsOneWidget);
  });
}

/// The **detail** pane's ⋮, scoped.
///
/// Since 0.2.56 the middle pane's module header has a ⋮ too, and it carries the
/// same 「更多」 tooltip (the two shells have always used that word for their
/// overflow). Scoping is what keeps these assertions about the right pane's
/// button — an unscoped finder would match both and fail on the count.
Finder _detailMenu() => find.descendant(
      of: find.byType(DetailPane),
      matching: find.byTooltip('更多'),
    );
