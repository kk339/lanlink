/// A tiny sealed result type for controller loading/error/data states
/// (spec §3.2).
///
/// Pure Dart; no dependency on Flutter or the platform. Controllers expose an
/// `AsyncValue<T>` so a page can distinguish **loading** from **empty** (A2-2).
library;

/// The three states of an asynchronously loaded value.
sealed class AsyncValue<T> {
  /// Const constructor for subclasses.
  const AsyncValue();

  /// Whether this is a [Loading].
  bool get isLoading => this is Loading<T>;

  /// Whether this is a [Failure].
  bool get hasError => this is Failure<T>;

  /// The value when this is [Data], else `null`.
  T? get valueOrNull => this is Data<T> ? (this as Data<T>).value : null;
}

/// A load in progress.
final class Loading<T> extends AsyncValue<T> {
  /// Creates a loading state.
  const Loading();
}

/// A loaded value.
final class Data<T> extends AsyncValue<T> {
  /// Creates a data state carrying [value].
  const Data(this.value);

  /// The loaded value.
  final T value;
}

/// A failed load.
final class Failure<T> extends AsyncValue<T> {
  /// Creates a failure carrying [error] and an optional [stackTrace].
  const Failure(this.error, [this.stackTrace]);

  /// The error.
  final Object error;

  /// The stack trace, when available.
  final StackTrace? stackTrace;
}
