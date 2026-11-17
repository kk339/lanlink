/// Shared fake-implementation assembly for the M4 app tests (spec §6,
/// `test/support/fakes.dart`).
///
/// Every controller / widget test pulls its in-memory doubles from here, so the
/// set of fakes and the deterministic clock / id factory stay in one place.
///
/// This is a pure re-export barrel. It adds **no** new fake and, in particular,
/// does **not** redeclare `FakeBackend` — it re-exports the single definition
/// from `data/fake/fake_backend.dart` (spec §6: re-export `FakeBackend`, never
/// create a same-named copy).
///
/// Layering (spec §8.1): everything re-exported here is pure Dart, so importing
/// this in a test never drags in `dart:io` / `dart:ffi` / `lanlink_core` /
/// `lanlink_store`.
library;

export 'package:lanlink_app/data/fake/fake_backend.dart';
export 'package:lanlink_app/data/fake/fake_peer_discovery.dart';
export 'package:lanlink_app/data/fake/fake_platform_ports.dart';
export 'package:lanlink_app/data/fake/fake_public_storage.dart';
export 'package:lanlink_app/data/fake/fake_session_repository.dart';
export 'package:lanlink_app/data/fake/fake_transfer_service.dart';

// The deterministic test doubles live in `domain/` (spec §3.2). Re-export them
// so a test gets its clock and id source from the same import as the fakes.
export 'package:lanlink_app/domain/clock.dart' show FixedClock;
export 'package:lanlink_app/domain/id_factory.dart' show FixedIdFactory;
