/// Shared test fixtures: an in-memory database, the fixed clock and
/// deterministic id helpers.
///
/// Following spec §9.6, every test opens its own in-memory database in `setUp`
/// and closes it in `tearDown` — nothing is written to disk and no state leaks
/// between tests.
library;

import 'package:lanlink_store/lanlink_store.dart';

/// The fixed clock used by every test (spec §5.10). UTC, like the schema.
final DateTime t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

/// Returns [t0] shifted forward by [seconds] (UTC).
DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

/// Opens a fresh in-memory database with the v1 schema applied.
LanlinkDatabase openTestDatabase() => LanlinkDatabase.openInMemory();
