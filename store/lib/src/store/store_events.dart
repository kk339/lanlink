/// Events published by the `SessionStore` facade as it changes the database
/// (spec §5.4).
///
/// The shape mirrors `PeerRegistry.events`: a sealed base type with small
/// `final` subclasses, delivered on a broadcast stream **in the order the state
/// changed**. Events are emitted only **after** the transaction that produced
/// them has committed, so a listener never sees work that was rolled back, and
/// a de-duplicated replay emits nothing at all.
library;

import '../models/message_record.dart';

/// Base type for session-store change notifications.
sealed class StoreEvent {
  /// Const constructor for subclasses.
  const StoreEvent();
}

/// A genuinely new message row was written.
///
/// Emitted once per new event; a re-delivered event that de-duplicates against
/// an existing row emits nothing (spec §5.4, §5.6).
final class MessageInserted extends StoreEvent {
  /// Creates the event for [message].
  const MessageInserted(this.message);

  /// The message that was inserted.
  final MessageRecord message;
}

/// An attachment was **appended to a message that already existed**.
///
/// The folder path is the only writer that grows a message after it exists:
/// `recordIncomingFolderFile` folds a whole `prepare` session onto one message
/// id (docs/22 §4.2), so file 1 creates the row (`MessageInserted`) and files
/// 2…N are attachments added to a message the UI is **already showing**. Until
/// 0.2.51 that append was silent, and a reader that keys its refresh on "a
/// message arrived" therefore never redrew the growth — the card showed the
/// first file forever (`docs/22` §4.2; the store emitted `MessageInserted` for
/// file 1 and nothing for the rest).
///
/// Not emitted for the file that creates the message: that arrival is already
/// announced by [MessageInserted], and saying it twice would make a 3-file
/// batch cost 3 events for 1 message and 2 appends. Not emitted for a
/// re-delivered file either — `files.id` is the wire `fileId`, so a file the
/// store already holds writes no row, and an event about a write that did not
/// happen would be a lie (a retry would look like new data).
///
/// Only [messageId] travels: the new attachment itself is a **read** away
/// (`filesOf`), and carrying a copy here would give a listener two sources for
/// the same rows.
final class MessageFilesAppended extends StoreEvent {
  /// Creates the event for the message that grew.
  const MessageFilesAppended({required this.messageId});

  /// The message the attachment was appended to.
  final String messageId;
}

/// A message moved between two statuses.
///
/// Emitted by `setStatus`, `markSendSucceeded` and `markSendFailed`, carrying
/// the exact `from -> to` pair so a listener can react without re-reading the
/// database.
final class MessageStatusChanged extends StoreEvent {
  /// Creates the event for `messageId` moving `from -> to`.
  const MessageStatusChanged({
    required this.messageId,
    required this.from,
    required this.to,
  });

  /// The message whose status changed.
  final String messageId;

  /// The status before the change.
  final MessageStatus from;

  /// The status after the change.
  final MessageStatus to;
}
