/// The message status machine (spec §5.5). Pure functions, no state.
///
/// The legal edge set comes straight from the transition table; everything not
/// listed is illegal. `from == to` is intentionally illegal so a no-op cannot
/// silently mask a logic error — a caller that needs idempotency should check
/// the current status first.
library;

import '../errors/store_errors.dart';
import '../models/message_record.dart';

/// The fourteen legal transitions.
const Set<(MessageStatus, MessageStatus)> _legalTransitions =
    <(MessageStatus, MessageStatus)>{
  (MessageStatus.pending, MessageStatus.awaitingConfirm),
  // A native text message has no confirm/transfer stage — it is one frame and
  // one round-trip, so it may go straight from `pending` to `done` (accepted),
  // or to `rejected` when the peer refuses it (docs/13 §7.3). A refusal is not
  // a failure, so it keeps its own state. A file message still walks the full
  // chain.
  (MessageStatus.pending, MessageStatus.done),
  (MessageStatus.pending, MessageStatus.rejected),
  (MessageStatus.pending, MessageStatus.canceled),
  (MessageStatus.pending, MessageStatus.failed),
  (MessageStatus.awaitingConfirm, MessageStatus.transferring),
  (MessageStatus.awaitingConfirm, MessageStatus.rejected),
  (MessageStatus.awaitingConfirm, MessageStatus.failed),
  (MessageStatus.awaitingConfirm, MessageStatus.canceled),
  (MessageStatus.transferring, MessageStatus.done),
  (MessageStatus.transferring, MessageStatus.failed),
  (MessageStatus.transferring, MessageStatus.canceled),
  (MessageStatus.failed, MessageStatus.pending),
  (MessageStatus.failed, MessageStatus.canceled),
};

/// Terminal statuses: no outgoing edges.
const Set<MessageStatus> _terminalStatuses = <MessageStatus>{
  MessageStatus.done,
  MessageStatus.canceled,
  MessageStatus.rejected,
};

/// The only status a retry scheduler is allowed to move back to `pending`.
const Set<MessageStatus> _retryableFrom = <MessageStatus>{
  MessageStatus.failed,
};

/// Whether `from -> to` is a legal transition (`from == to` is illegal).
bool canTransition(MessageStatus from, MessageStatus to) =>
    _legalTransitions.contains((from, to));

/// Throws [InvalidStatusTransition] unless [canTransition] holds.
void assertTransition(MessageStatus from, MessageStatus to) {
  if (!canTransition(from, to)) {
    throw InvalidStatusTransition(from.wire, to.wire);
  }
}

/// Whether [status] is terminal (no outgoing edges).
bool isTerminal(MessageStatus status) => _terminalStatuses.contains(status);

/// The set of statuses a retry scheduler may re-queue (`{failed}`).
Set<MessageStatus> get retryableFrom => _retryableFrom;

/// All terminal statuses.
Set<MessageStatus> get terminalStatuses => _terminalStatuses;

/// Every legal transition, exposed for tests and diagnostics.
Set<(MessageStatus, MessageStatus)> get legalTransitions => _legalTransitions;
