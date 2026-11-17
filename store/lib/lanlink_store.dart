/// lanlink_store - the M3 session data layer.
///
/// A **pure Dart** package: it depends on `lanlink_core` (for the device model
/// and the fingerprint / hash helpers) but never on Flutter, and never on
/// `lanlink_cli`. The dependency direction is one-way: `store -> core`.
///
/// Importing this barrel gives access to the whole milestone: the schema +
/// migrations, the connection wrapper, the row models, the id generators, the
/// idempotent message-id algorithm, the status machine, the five table DAOs and
/// the `SessionStore` facade with its event stream.
library;

export 'src/dao/conversations_dao.dart';
export 'src/dao/devices_dao.dart';
export 'src/dao/files_dao.dart';
export 'src/dao/messages_dao.dart';
export 'src/dao/transfers_dao.dart';
export 'src/db/lanlink_database.dart';
export 'src/db/sqlite_bootstrap.dart';
export 'src/db/time_codec.dart';
export 'src/errors/store_errors.dart';
export 'src/ids/ids.dart';
export 'src/ids/message_id.dart';
export 'src/models/conversation_record.dart';
export 'src/models/device_record.dart';
export 'src/models/message_file_record.dart';
export 'src/models/message_record.dart';
export 'src/models/transfer_record.dart';
export 'src/schema/migrations.dart';
export 'src/schema/schema.dart';
export 'src/status/message_status_machine.dart';
export 'src/store/session_store.dart';
export 'src/store/store_events.dart';
