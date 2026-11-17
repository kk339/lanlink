import 'package:lanlink_store/lanlink_store.dart';
import 'package:test/test.dart';

const MessageStatus pending = MessageStatus.pending;
const MessageStatus awaitingConfirm = MessageStatus.awaitingConfirm;
const MessageStatus transferring = MessageStatus.transferring;
const MessageStatus done = MessageStatus.done;
const MessageStatus failed = MessageStatus.failed;
const MessageStatus canceled = MessageStatus.canceled;
const MessageStatus rejected = MessageStatus.rejected;

/// The fourteen legal transitions of spec §5.5 (twelve + the two text edges
/// `pending → done` / `pending → rejected`, docs/13 §7.3).
const List<(MessageStatus, MessageStatus)> legal =
    <(MessageStatus, MessageStatus)>[
  (pending, awaitingConfirm),
  (pending, done),
  (pending, rejected),
  (pending, canceled),
  (pending, failed),
  (awaitingConfirm, transferring),
  (awaitingConfirm, rejected),
  (awaitingConfirm, failed),
  (awaitingConfirm, canceled),
  (transferring, done),
  (transferring, failed),
  (transferring, canceled),
  (failed, pending),
  (failed, canceled),
];

const List<MessageStatus> terminal = <MessageStatus>[done, canceled, rejected];

void main() {
  test('the fourteen legal edges are accepted', () {
    expect(legal.length, 14);
    for (final edge in legal) {
      expect(canTransition(edge.$1, edge.$2), isTrue, reason: '$edge');
      expect(() => assertTransition(edge.$1, edge.$2), returnsNormally,
          reason: '$edge');
    }
  });

  test('illegal edges are rejected', () {
    const List<(MessageStatus, MessageStatus)> illegal =
        <(MessageStatus, MessageStatus)>[
      (pending, transferring),
      (awaitingConfirm, pending),
      (awaitingConfirm, done),
      (transferring, pending),
      (transferring, awaitingConfirm),
      (transferring, rejected),
      (done, pending),
      (done, failed),
      (canceled, pending),
      (rejected, pending),
    ];
    for (final edge in illegal) {
      expect(canTransition(edge.$1, edge.$2), isFalse, reason: '$edge');
      expect(
        () => assertTransition(edge.$1, edge.$2),
        throwsA(isA<InvalidStatusTransition>()),
        reason: '$edge',
      );
    }
  });

  test('from == to is always illegal', () {
    for (final status in MessageStatus.values) {
      expect(canTransition(status, status), isFalse, reason: status.wire);
      expect(
        () => assertTransition(status, status),
        throwsA(isA<InvalidStatusTransition>()),
      );
    }
  });

  test('terminal statuses have no outgoing edges', () {
    for (final status in MessageStatus.values) {
      expect(
        isTerminal(status),
        terminal.contains(status),
        reason: 'isTerminal(${status.wire})',
      );
      if (terminal.contains(status)) {
        for (final target in MessageStatus.values) {
          expect(
            canTransition(status, target),
            isFalse,
            reason: '${status.wire} -> ${target.wire}',
          );
        }
      }
    }
  });

  test('only failed may return to pending', () {
    expect(retryableFrom, <MessageStatus>{failed});
    expect(canTransition(failed, pending), isTrue);
    for (final status in MessageStatus.values) {
      if (status == failed) {
        continue;
      }
      expect(
        canTransition(status, pending),
        isFalse,
        reason: '${status.wire} -> pending',
      );
    }
  });

  test('InvalidStatusTransition carries the wire values', () {
    try {
      // `pending -> done` is now legal (docs/13 §7.3); use an edge that stays
      // illegal to exercise the error.
      assertTransition(pending, transferring);
      fail('expected InvalidStatusTransition');
    } on InvalidStatusTransition catch (error) {
      expect(error.from, 'pending');
      expect(error.to, 'transferring');
    }
  });
}
