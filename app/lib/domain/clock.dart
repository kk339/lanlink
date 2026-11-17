/// Time injection for the app (spec §3.2 / §8.3).
///
/// Controllers and UI **never** call `DateTime.now()`; they take a [Clock].
/// Only the native adapters read the clock and feed the resulting `DateTime` to
/// `SessionStore` (whose write methods take an explicit `now`).
///
/// Pure Dart (no platform import) so it compiles on Web.
library;

/// A source of the current UTC instant.
abstract interface class Clock {
  /// The current instant, in UTC.
  DateTime nowUtc();
}

/// The production [Clock]: the system clock.
class SystemClock implements Clock {
  /// Creates a system clock.
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// A deterministic [Clock] for tests: starts at a fixed instant and only moves
/// when [advance] is called.
class FixedClock implements Clock {
  /// Creates a clock pinned to [now] (callers pass a UTC instant).
  FixedClock(this._now);

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  /// Moves the clock forward by [duration].
  void advance(Duration duration) => _now = _now.add(duration);
}
