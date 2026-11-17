/// Exceptions raised deliberately by the lanlink session data layer.
///
/// Every type here is a [StoreException] so a caller can catch the whole family
/// with one `on StoreException`. Nothing in this file touches SQLite or the
/// models, which keeps the error types usable from anywhere in the package.
library;

/// Base class for every error this package raises on purpose.
class StoreException implements Exception {
  /// Creates a store exception carrying a human readable [message].
  StoreException(this.message);

  /// Human readable description of what went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a status change is not one of the legal transitions.
///
/// [from] and [to] are the `MessageStatus.wire` strings, so this type does not
/// depend on the model layer.
class InvalidStatusTransition extends StoreException {
  /// Creates the exception for the illegal edge `from -> to`.
  InvalidStatusTransition(this.from, this.to)
      : super('illegal message status transition: $from -> $to');

  /// The status the row was in (`MessageStatus.wire`).
  final String from;

  /// The status the caller tried to move it to (`MessageStatus.wire`).
  final String to;
}

/// Thrown when a row that must exist cannot be found.
class RowNotFound extends StoreException {
  /// Creates the exception for the missing row [id].
  RowNotFound(this.id) : super('row not found: $id');

  /// Identifier of the missing row.
  final String id;
}

/// Thrown when the on-disk schema cannot be brought up to `kSchemaVersion`.
///
/// Raised when the stored `user_version` is newer than this build understands,
/// or when a migration statement fails (the step is rolled back first).
class MigrationException extends StoreException {
  /// Creates a migration failure with the given [message].
  MigrationException(super.message);
}

/// Thrown when a closed database / session store is used.
class StoreClosedException extends StoreException {
  /// Creates the exception for a use-after-close.
  StoreClosedException() : super('the store has been closed');
}
