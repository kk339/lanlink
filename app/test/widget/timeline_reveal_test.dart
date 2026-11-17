/// **「转到消息」 — long-press a file on the media wall, go back to the
/// conversation, and that message is *there*** (0.2.59).
///
/// The gesture starts outside this widget (`ConversationController.requestReveal`,
/// asked for by the 文件 / 设备墙 surfaces) and ends inside it, so what has to be
/// pinned here is the whole path — request → the thread that may not exist yet →
/// the row → the viewport — under three conditions the user actually hits:
///
/// * **a long history.** 200 messages at a fixed viewport, with the target near
///   the top (5), in the middle (120) and near the bottom (196). A plain
///   `jumpTo(maxScrollExtent * i / n)` cannot do the middle one: the rows here are
///   not all the same height (a day separator and `HH:mm` labels are children
///   too), and the row does not even *exist* until it has been scrolled near —
///   `Scrollable.ensureVisible` is a no-op on a row the lazy list has not built.
/// * **messages keep arriving.** After the scroll the thread must stay put; the
///   next arrival must **not** drag the viewport to the bottom, or the whole
///   gesture is undone a second later by the peer saying hello.
/// * **the request can outlive the widget** (the 消息 / 文件 tab switch destroys
///   the thread), which is why the request lives on the controller.
///
/// Every judgement below is geometric on purpose: "no exception" would pass for a
/// reveal that never moved anything.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanlink_app/controllers/conversation_controller.dart';
import 'package:lanlink_app/controllers/transfer_orchestrator.dart';
import 'package:lanlink_app/data/fake/fake_backend.dart';
import 'package:lanlink_app/domain/draft_store.dart';
import 'package:lanlink_app/domain/models.dart';
import 'package:lanlink_app/domain/unsent_dismissal_store.dart';
import 'package:lanlink_app/ui/panes/conversation_thread.dart';

import '../support/pump_app.dart';

const String _conversationId = 'c-reveal';

/// How many messages the fixture conversation holds.
const int _kHistory = 200;

const PeerDevice _peer = PeerDevice(
  fingerprint: 'CC01',
  alias: 'Eve',
  kind: DeviceKind.desktop,
  isOnline: true,
  lastPort: 53317,
);

/// Where the fixture history starts: a few hours **before** the fake clock's
/// `now`, so that a message arriving during a test (`recordIncomingText`, which
/// stamps `now`) sorts *after* all 200 seeded ones — i.e. it really arrives at the
/// end of the timeline, which is the only place an arrival can push the viewport.
final DateTime _start = fixedEpoch.subtract(const Duration(minutes: 400));

String _body(int n) => '第 $n 条';

String _id(int n) => 'm-$n';

/// The timeline's row for message [n]: the `KeyedSubtree` that carries the row's
/// `GlobalKey`, found **through the message's own text**.
///
/// A `GlobalKey` cannot be named from outside the library, so the assertion "the
/// row is really built" is read from the other side: the message's text can only
/// be found in the tree if the lazy `ListView` inflated that row, and the nearest
/// `KeyedSubtree` carrying a `GlobalKey` above it is the one the reveal loop looks
/// up. A row that is scrolled far away has neither.
Finder _rowFinder(int n) => find
    .ancestor(
      of: find.text(_body(n)),
      matching: find.byWidgetPredicate(
        (Widget widget) => widget is KeyedSubtree && widget.key is GlobalKey,
      ),
    )
    .first;

/// The timeline's viewport box (the `ListView` itself).
Rect _viewport(WidgetTester tester) => tester.getRect(find.byType(ListView));

/// The thread's own scroll position.
///
/// Scoped through the `ListView` because a `TextField` — the composer — is also a
/// `Scrollable`, and "the first `Scrollable` in the tree" would be the wrong one.
ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

/// Asserts that message [n]'s row is **built** and its centre sits in the middle
/// of the viewport (the band 20 % … 80 % down it).
void _expectRevealed(WidgetTester tester, int n) {
  expect(
    find.text(_body(n)),
    findsOneWidget,
    reason: '第 $n 条 的行没有被构建 —— 定位没有走到它附近',
  );
  final KeyedSubtree row = tester.widget<KeyedSubtree>(_rowFinder(n));
  final Key? key = row.key;
  expect(key, isA<GlobalKey>(), reason: 'the row lost its reveal key');
  final BuildContext? context = (key! as GlobalKey).currentContext;
  expect(
    context,
    isNotNull,
    reason: '第 $n 条 的行在树上却没有 element —— 这一行没被真正布局出来',
  );
  final RenderObject? object = context!.findRenderObject();
  expect(object, isA<RenderBox>(), reason: '第 $n 条 的行没有可量的盒子');
  final RenderBox box = object! as RenderBox;
  expect(box.hasSize, isTrue);

  final Rect viewport = _viewport(tester);
  final double centre = box.localToGlobal(Offset.zero).dy + box.size.height / 2;
  final double top = viewport.top + viewport.height * 0.2;
  final double bottom = viewport.top + viewport.height * 0.8;
  expect(
    centre,
    inInclusiveRange(top, bottom),
    reason: '第 $n 条 必须滚到**中间**，不是「碰了一下」: '
        'centre=$centre, allowed [$top, $bottom], viewport=$viewport, '
        'pixels=${_position(tester).pixels}',
  );
}

/// Asserts that message [n]'s row is **not built** — it is out of the viewport and
/// out of the lazy list's cache.
///
/// This is what makes [_expectRevealed] a real judgement rather than a tautology:
/// before the reveal the same finder must find nothing.
void _expectNotBuilt(WidgetTester tester, int n) {
  expect(
    find.text(_body(n)),
    findsNothing,
    reason: '第 $n 条 本该在视野外 —— 否则这次定位证明不了任何东西',
  );
}

void main() {
  late FakeBackend backend;
  late ConversationController controller;
  bool disposed = false;

  /// Releases the controller and the backend **inside** the test body too: a
  /// failed expectation would otherwise leave the 1 Hz progress ticker (and the
  /// repository's event stream) alive, which `flutter_test` reports as a pending
  /// timer on top of the real failure.
  void disposeAll() {
    if (disposed) {
      return;
    }
    disposed = true;
    controller.dispose();
    backend.dispose();
  }

  setUp(() {
    disposed = false;
    backend = FakeBackend();
    backend.repo.addConversation(
      id: _conversationId,
      deviceFingerprint: 'CC01',
      createdAt: fixedEpoch,
      lastMessageAt: fixedEpoch,
    );
    // 200 messages, one minute apart — **all on one day**, so the timeline is one
    // date separator plus 200 bubbles, and the only uneven children are the small
    // `HH:mm` labels, which is exactly the mixture that defeats a pure ratio.
    for (int n = 1; n <= _kHistory; n++) {
      backend.repo.addMessage(
        id: _id(n),
        conversationId: _conversationId,
        direction: MessageDirection.incoming,
        status: MessageStatus.done,
        kind: MessageKind.text,
        textBody: _body(n),
        createdAt: _start.add(Duration(minutes: n - 1)),
        updatedAt: _start.add(Duration(minutes: n - 1)),
      );
    }
    controller = ConversationController(
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
      dismissals: UnsentDismissalStore(),
    );
  });

  tearDown(disposeAll);

  /// Mounts the real thread over the seeded conversation.
  ///
  /// The history is read **before** mounting: a thread still in `Loading` paints
  /// an indeterminate spinner and `pumpAndSettle` would never settle.
  Future<void> pumpThread(WidgetTester tester) async {
    controller.load();
    await pumpApp(
      tester,
      Scaffold(body: ConversationThread(controller: controller, peer: _peer)),
      backend: backend,
      settle: true,
    );
  }

  /// The peer says something — through the **repository's own arrival path**,
  /// which is what emits `MessageAdded` and therefore what makes the controller
  /// grow the list. (`FakeSessionRepository.addMessage` only seeds rows: it
  /// announces nothing, so an arrival written with it would never reach the UI.)
  void arrive(int n) {
    backend.repo.recordIncomingText(
      sender: _peer,
      text: _body(n),
      nonce: 'arrival-$n',
    );
  }

  testWidgets(
      'A: 第 5 条（靠顶部）能滚到 —— 行的 GlobalKey 有 currentContext，'
      '且行中心落在视口中间 60% 内', (WidgetTester tester) async {
    await pumpThread(tester);

    // The control: before the request the row does not exist at all.
    _expectNotBuilt(tester, 5);
    _expectNotBuilt(tester, 120);

    controller.requestReveal(_id(5));
    await tester.pumpAndSettle();

    _expectRevealed(tester, 5);
    // …and it is really *this* message, not a row that happens to be centred.
    expect(find.text(_body(5)), findsOneWidget);
  });

  testWidgets(
      'B: 第 120 条（中间）能滚到 —— 靠比例估算走不到这么远，必须靠邻居校正',
      (WidgetTester tester) async {
    await pumpThread(tester);
    _expectNotBuilt(tester, 120);

    controller.requestReveal(_id(120));
    await tester.pumpAndSettle();

    _expectRevealed(tester, 120);
    expect(find.text(_body(120)), findsOneWidget);
    // The ends of the list are now out of the window: the viewport really moved
    // to the middle of the conversation rather than staying at the bottom.
    expect(find.text(_body(_kHistory)), findsNothing);
  });

  testWidgets(
      'C: 第 196 条（靠底部）能滚到 —— 只有 4 条在它后面，'
      '纯比例估算会停在末尾而不是它身上', (WidgetTester tester) async {
    await pumpThread(tester);
    // No "is it built?" control here: the thread opens **at the newest message**,
    // so 196 is on screen from the start. The control that the finder is
    // meaningful is 第 5 条 — far above the opening position.
    _expectNotBuilt(tester, 5);

    controller.requestReveal(_id(196));
    await tester.pumpAndSettle();

    _expectRevealed(tester, 196);
    expect(find.text(_body(196)), findsOneWidget);
  });

  testWidgets(
      'D: 定位进行期间来的新消息不会把视口拽到底部（定位被中途打断才是真缺陷）',
      (WidgetTester tester) async {
    await pumpThread(tester);

    controller.requestReveal(_id(120));
    await tester.pump(); // rebuild + first estimate
    await tester.pump(); // the jump has built the row → ensureVisible starts
    await tester.pump(const Duration(milliseconds: 30)); // 30 of 200 ms in

    // The peer says something **while the reveal is still animating**.
    arrive(_kHistory + 1);
    await tester.pump();
    await tester.pumpAndSettle();

    // Still on 120, still centred: the arrival did not steal the viewport.
    _expectRevealed(tester, 120);
    expect(
      _position(tester).pixels,
      lessThan(_position(tester).maxScrollExtent - 1),
      reason: 'a message arriving mid-reveal must not snap the list to the end',
    );
  });

  testWidgets(
      'E: 定位结束后「有新消息就滚到底」恢复原样（抑制只在一次定位期间有效）',
      (WidgetTester tester) async {
    await pumpThread(tester);

    controller.requestReveal(_id(120));
    await tester.pumpAndSettle();
    _expectRevealed(tester, 120);

    // One arrival **after** the reveal finished.
    arrive(_kHistory + 1);
    await tester.pumpAndSettle();

    final ScrollPosition position = _position(tester);
    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5),
      reason: 'the ordinary follow-the-newest behaviour must be back',
    );
    expect(find.text(_body(_kHistory + 1)), findsOneWidget);
  });

  testWidgets(
      'F: 请求一个不存在的 id —— 不崩、不死循环、明确说「没有找到这条消息」',
      (WidgetTester tester) async {
    await pumpThread(tester);
    final double before = _position(tester).pixels;

    controller.requestReveal('m-does-not-exist');
    await tester.pumpAndSettle();

    // Said out loud instead of silently doing nothing…
    expect(find.text('没有找到这条消息'), findsOneWidget);
    // …and it is the only thing that happened: no exception, and the viewport was
    // not left somewhere random by a loop that kept guessing.
    expect(tester.takeException(), isNull);
    expect(
      _position(tester).pixels,
      moreOrLessEquals(before, epsilon: 0.5),
      reason: 'an id we cannot locate must not scroll anywhere',
    );
    // The request was consumed exactly once, so a rebuild cannot replay it.
    expect(controller.pendingRevealId, isNull);
    expect(controller.takeRevealRequest(), isNull);

    // Drain the notice's 2 s timer.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
      'G: 请求能跨 tab 存活 —— 请求先到、线程后被创建（模拟从「文件」切回「消息」）',
      (WidgetTester tester) async {
    // Nothing is mounted yet: this is the 文件 tab moment.
    controller.load();
    controller.requestReveal(_id(120));
    expect(controller.pendingRevealId, _id(120));

    // …and only now does the thread exist.
    await pumpApp(
      tester,
      Scaffold(body: ConversationThread(controller: controller, peer: _peer)),
      backend: backend,
      settle: true,
    );

    _expectRevealed(tester, 120);
    // The first fill's instant jump-to-bottom was skipped for this reveal: the
    // newest message is *not* on screen.
    expect(find.text(_body(_kHistory)), findsNothing);
    expect(controller.pendingRevealId, isNull,
        reason: 'a mounted thread must consume the request');
  });

  testWidgets(
      'H: 第二个请求会接管第一个 —— 每一次「转到消息」都真的会滚（不是只生效一次）',
      (WidgetTester tester) async {
    await pumpThread(tester);

    controller.requestReveal(_id(5));
    await tester.pumpAndSettle();
    _expectRevealed(tester, 5);
    final double after = _position(tester).pixels;

    controller.requestReveal(_id(30));
    await tester.pumpAndSettle();
    _expectRevealed(tester, 30);
    expect(_position(tester).pixels, greaterThan(after));
  });
}
