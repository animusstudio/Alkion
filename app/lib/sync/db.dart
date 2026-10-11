import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';

import '../auth/auth_store.dart';
import '../capture/capture_profile.dart';
import '../capture/capture_transport.dart';
import '../capture/native_sync_quiescence.dart'
    show nativeSyncConnectionWillChange;
import '../capture/source_write_gate.dart';
import 'connector.dart';
import 'schema.dart';

/// The single app-wide PowerSyncDatabase. PowerSync requires exactly one
/// instance per database file.
PowerSyncDatabase? _db;

PowerSyncDatabase get db {
  final d = _db;
  if (d == null) {
    throw StateError('PowerSync not opened; call openDatabase() first');
  }
  return d;
}

/// Test-only seam: install a database instance (or null to reset between
/// tests). Production code always goes through [openDatabase].
@visibleForTesting
set dbForTests(PowerSyncDatabase? d) => _db = d;

/// Where the app keeps its local PowerSync database.
Future<String> appDatabasePath() async {
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, 'workout-tracker.db');
}

/// Opens (or returns) the local PowerSync database. As of PowerSync v2 the
/// `powersync` package loads its SQLite extension via build hooks, so no
/// separate libs package or native path wiring is needed on Linux desktop.
Future<PowerSyncDatabase> openDatabase() async {
  if (_db != null) return _db!;
  final path = await appDatabasePath();
  final database = PowerSyncDatabase(schema: schema, path: path);
  await database.initialize();
  _db = database;
  return database;
}

/// Opens the database at [path] for capture, before normal startup: its
/// layout and core are first inspected read-only and must match [profile]
/// exactly; only then is it initialized, by that profile's procedure alone.
/// Never creates a missing database, connects, clears or runs app backfills.
///
/// The result becomes the app-wide [db], so a later [openDatabase] returns
/// this same instance. Throws [UnsupportedCaptureProfile] (leaving the source
/// untouched) for anything not exactly qualified, or if a database is
/// already open.
Future<PowerSyncDatabase> openCaptureDatabase({
  required String path,
  required QualifiedOpenProfile profile,
}) async {
  if (_db != null) {
    throw const UnsupportedCaptureProfile('database_already_open');
  }
  final database = await openQualifiedSource(path: path, profile: profile);
  _db = database;
  return database;
}

/// Changes the sync connection of [database] (default [db]) as one admitted
/// operation named [operation] ([parent] when it is part of a larger one).
///
/// Refused (`admission_closed`, before anything changes) while a data
/// capture has transport or source admission closed. Once admitted, it is
/// an admitted transport operation a capture's drain awaits
/// ([TransportAdmission.runConnectionChange]). The change is reported to
/// the native sync quiescence evidence ([nativeSyncConnectionWillChange])
/// before [change] runs and again once it returned or failed, so no capture
/// evidence observed before or while it ran stays current. Once it
/// succeeded, the app's sync policy is recorded: [connects] true for a
/// connect, false for a disconnect or clear (see
/// [TransportAdmission.syncRequested]).
Future<void> changeSyncConnection(
  String operation,
  Future<void> Function(PowerSyncDatabase database) change, {
  required bool connects,
  SourceTicket? parent,
  PowerSyncDatabase? database,
}) async {
  final admission = TransportAdmission.instance;
  admission.ensureOpen(operation);
  final target = database ?? db;
  await admission.runConnectionChange(
    operation,
    () => runSourceWrite(operation, (_) async {
      admission.ensureOpen(operation);
      nativeSyncConnectionWillChange(target);
      try {
        await change(target);
      } finally {
        // The SDK serializes connects and disconnects on its own mutex: what
        // this call started may follow an observation made while it ran.
        nativeSyncConnectionWillChange(target);
      }
      admission.recordConnectionChange(connected: connects);
    }, parent: parent),
  );
}

/// Connect the open database to the sync service using [auth]'s credentials:
/// boot resume, login/registration attach, signing in again, and restoring
/// a capture's prior policy all connect through here.
Future<void> connectSync(AuthStore auth) => changeSyncConnection(
    'sync.connect', (d) => d.connect(connector: WorkoutConnector(auth)),
    connects: true);

/// Stop syncing without clearing anything (signing in again stops the old
/// loop first).
Future<void> disconnectSync() =>
    changeSyncConnection('sync.disconnect', (d) => d.disconnect(),
        connects: false);

/// Stop syncing and wipe ALL local data (used on logout).
Future<void> disconnectAndClear({SourceTicket? parent}) =>
    changeSyncConnection('sync.disconnect_and_clear',
        (d) => d.disconnectAndClear(),
        connects: false,
        parent: parent);

/// How many local changes are still waiting to upload. They exist only on
/// this device until they sync, so anything that wipes local data loses them.
/// A database without the upload queue counts as none pending.
Future<int> pendingUploadCount([PowerSyncDatabase? database]) async {
  try {
    final row = await (database ?? db)
        .getOptional('SELECT COUNT(*) AS n FROM ps_crud');
    return (row?['n'] as int?) ?? 0;
  } catch (_) {
    return 0;
  }
}
