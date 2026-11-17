/// Conversion between [DateTime] and the epoch-millisecond integers stored in
/// SQLite (spec §5.10).
///
/// The schema stores **UTC epoch milliseconds** in every timestamp column
/// (`created_at`, `updated_at`, `last_seen_at`, ...). These helpers are the one
/// place that translation happens, so no caller has to remember the units or
/// the timezone convention. Times are always treated as UTC: a local
/// [DateTime] is converted with [DateTime.toUtc] before its epoch value is
/// taken, and every value read back is tagged `isUtc: true`.
library;

/// Encodes [time] as UTC epoch milliseconds.
///
/// A local [DateTime] is converted to UTC first, so two [DateTime]s that name
/// the same instant always encode to the same integer regardless of their
/// original timezone flag.
int toEpochMillis(DateTime time) => time.toUtc().millisecondsSinceEpoch;

/// Decodes [millis] (UTC epoch milliseconds) back into a UTC [DateTime].
DateTime fromEpochMillis(int millis) =>
    DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);

/// Nullable counterpart of [fromEpochMillis] for a raw row value.
///
/// Takes an [Object] because it is fed straight from a SQLite `Row`: a `NULL`
/// column arrives as `null` and yields `null`; anything else must be an `int`
/// (the schema declares every timestamp column `INTEGER`) and is decoded with
/// [fromEpochMillis].
DateTime? fromEpochMillisOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  return fromEpochMillis(value as int);
}

/// Nullable counterpart of [toEpochMillis]; `null` maps to a `NULL` column.
int? toEpochMillisOrNull(DateTime? time) =>
    time == null ? null : toEpochMillis(time);
