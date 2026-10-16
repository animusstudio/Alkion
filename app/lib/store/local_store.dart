import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sqlite_async/native.dart';
import 'package:sqlite_async/sqlite_async.dart';

import '../domain/evidence.dart';
import '../domain/local_action.dart';
import '../identity/alkion_profile.dart';
import '../identity/directory_durability.dart';
import 'schema.dart';

final class StoreException implements Exception {
  const StoreException(this.category);
  final String category;
  @override
  String toString() => 'Alkion store: $category';
}

final class StoreToken {
  const StoreToken(this.profileId, this.generation);
  final String profileId;
  final int generation;
}

enum StoreAdmission { open, recovering, closed }

enum RecoveryPhase {
  admissionClosed,
  watchesCancelled,
  poolClosed,
  validated,
  ready,
  failed,
}

enum LocalStateKind {
  draft,
  finishedRecovery,
  timer,
  semanticSetting,
  goalInitialization,
  orderResolution,
  catalogSelection,
  onboarding,
}

/// Selected pinned T1 factory; no PowerSync and no custom transaction manager.
final class _StoreOpenFactory extends NativeSqliteOpenFactory {
  _StoreOpenFactory(String path)
    : super(
        path: path,
        sqliteOptions: const SqliteOptions(
          journalMode: SqliteJournalMode.wal,
          synchronous: SqliteSynchronous.full,
          maxReaders: 2,
        ),
      );
  @override
  List<String> pragmaStatements(SqliteOpenOptions options) => [
    ...super.pragmaStatements(options),
    'PRAGMA foreign_keys = ON',
    if (options.primaryConnection) 'PRAGMA wal_autocheckpoint = 1000',
  ];
}

abstract interface class LocalDatabase {
  String get profileId;
  StoreToken get token;
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction tx) mutate, {
    StoreToken? expected,
  });
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters,
  ]);
  Future<Map<String, dynamic>> get(String sql, [List<Object?> parameters]);
  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters,
  ]);
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters,
  });
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead tx) callback, {
    StoreToken? expected,
  });
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction tx) callback, {
    StoreToken? expected,
  });
}

/// All owned operations are serialized around pool recovery. SQL contexts are
/// callback-scoped; queued owners cannot lease the failed pool. One file contains
/// one profile; each table additionally has a FK to its sole profile metadata.
final class LocalStore implements LocalDatabase {
  LocalStore._(
    this.profile,
    this.path,
    this._owner,
    this._database,
    this.token,
    this.schema,
  );
  final AlkionProfile profile;
  final String path;
  final SchemaRegistry schema;
  final ProfileOwnership _owner;
  SqliteDatabase _database;
  @override
  final StoreToken token;
  @override
  String get profileId => token.profileId;
  StoreAdmission _admission = StoreAdmission.open;
  StoreAdmission get admission => _admission;
  Future<void> _tail = Future.value();
  final _watches = <_Watch>{};
  int _poolEpoch = 0;
  bool _ownershipReleased = false;
  int get poolEpoch => _poolEpoch;
  LocalAction? _uncertainAction;
  LocalActionResult? reconciledOutcome;
  LocalAction? get pendingRecoveryAction => _uncertainAction;
  final _recoveryEvents = StreamController<RecoveryPhase>.broadcast(sync: true);
  Stream<RecoveryPhase> get recoveryEvents => _recoveryEvents.stream;
  static final _ownedPaths = <String>{};

  static Future<LocalStore> open({
    required AlkionProfile profile,
    required String expectedProfileId,
    SchemaRegistry? schema,
  }) async {
    final registry = schema ?? SchemaRegistry();
    final path = await profile.databasePath(
      expectedProfileId: expectedProfileId,
    );
    if (!_ownedPaths.add(path)) {
      throw const StoreException('profile_in_use');
    }
    ProfileOwnership? owner;
    SqliteDatabase? database;
    try {
      await Directory(File(path).parent.path).create(recursive: true);
      final lockPath = await profile.ownerLockPath(
        expectedProfileId: expectedProfileId,
      );
      try {
        owner = ProfileOwnership.acquire(lockPath);
      } on FileSystemException {
        throw const StoreException('profile_in_use');
      }
      // No connection configuration writes until existing committed WAL metadata
      // and integrity have been checked on a real READONLY connection.
      await profile.databasePath(expectedProfileId: expectedProfileId);
      final exists = await File(path).exists();
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final type = FileSystemEntity.typeSync(
          '$path$suffix',
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file) {
          throw const StoreException('unsafe_store_artifact');
        }
      }
      if (!exists &&
          (File('$path-wal').existsSync() ||
              File('$path-shm').existsSync() ||
              File('$path-journal').existsSync())) {
        throw const StoreException('orphan_store_bytes_preserved');
      }
      if (File('$path-journal').existsSync()) {
        throw const StoreException('unsupported_journal_preserved');
      }
      if (exists) {
        _preflight(path, profile, registry);
      }
      database = SqliteDatabase.withFactory(_StoreOpenFactory(path));
      await database.initialize();
      final previousVersion = exists
          ? (await database.get('PRAGMA user_version')).values.single as int
          : 0;
      if (previousVersion < registry.latestVersion) {
        await database.writeTransaction((tx) async {
          for (final migration in registry.migrations.where(
            (m) => m.version > previousVersion,
          )) {
            for (final statement in migration.statements) {
              await tx.execute(statement);
            }
            if (migration.version == 1) {
              await tx.execute(
                "INSERT INTO profile_state VALUES(1,?,?,1,'writable',?)",
                [
                  profile.profileId,
                  profile.installationId,
                  OperationInstant.now().text,
                ],
              );
              await tx.execute('PRAGMA application_id = $alkionApplicationId');
            }
            final actual = await tx.getAll(
              "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL",
            );
            if (schemaSqlDigest(actual.map((r) => r['sql'] as String)) !=
                migration.expectedSchemaDigest) {
              throw const StoreException('migration_shape_mismatch');
            }
            await tx.execute('INSERT INTO schema_migrations VALUES(?,?,?)', [
              migration.version,
              migration.digest,
              OperationInstant.now().text,
            ]);
            await tx.execute('PRAGMA user_version = ${migration.version}');
          }
        });
        flushDirectory(File(path).parent.path);
        flushDirectory(Directory(File(path).parent.path).parent.path);
      }
      final row = await database.get(
        'SELECT * FROM profile_state WHERE singleton=1',
      );
      if (row['write_state'] != 'writable') {
        throw const StoreException('profile_fenced');
      }
      return LocalStore._(
        profile,
        path,
        owner,
        database,
        StoreToken(profile.profileId, row['generation'] as int),
        registry,
      );
    } catch (_) {
      await database?.close();
      owner?.close();
      _ownedPaths.remove(path);
      rethrow;
    }
  }

  static void _preflight(
    String path,
    AlkionProfile profile,
    SchemaRegistry registry,
  ) {
    sqlite.Database? reader;
    Directory? inspection;
    final sources = <String, Map<String, Object?>>{};
    var captured = false;
    try {
      if (File(path).lengthSync() < 100) {
        throw const StoreException('corrupt_schema_preserved');
      }
      // Under the held flock, all cooperating owners are absent/drained. Check
      // complete input bytes before/after the bounded inspection copy. This
      // avoids even READONLY SQLite creating original WAL/SHM sidecars.
      var total = 0;
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('$path$suffix');
        if (file.existsSync()) {
          if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
            throw const StoreException('unsafe_store_artifact');
          }
          final length = file.lengthSync();
          total += length;
          sources[suffix] = {'length': length};
        }
      }
      if (total > 512 * 1024 * 1024) {
        throw const StoreException('inspection_resource_limit_preserved');
      }
      for (final suffix in sources.keys) {
        sources[suffix]!['digest'] = sha256
            .convert(File('$path$suffix').readAsBytesSync())
            .toString();
      }
      captured = true;
      _validateWal(File('$path-wal'));
      inspection = Directory.systemTemp.createTempSync(
        'alkion-schema-inspection-',
      );
      final copied = '${inspection.path}/alkion.sqlite';
      for (final suffix in sources.keys.where((suffix) => suffix != '-shm')) {
        File('$path$suffix').copySync('$copied$suffix');
      }
      _verifyCaptured(path, sources);
      reader = sqlite.sqlite3.open(copied, mode: sqlite.OpenMode.readOnly);
      final version = reader.select('PRAGMA user_version').single.values.single;
      final application = reader
          .select('PRAGMA application_id')
          .single
          .values
          .single;
      if (version is! int || version > registry.latestVersion) {
        throw const StoreException('newer_schema_preserved');
      }
      if (version < 1 || application != alkionApplicationId) {
        throw const StoreException('unknown_schema_preserved');
      }
      if (reader.select('PRAGMA integrity_check').single.values.single !=
              'ok' ||
          reader.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const StoreException('corrupt_schema_preserved');
      }
      final metadata = reader.select(
        'SELECT * FROM profile_state WHERE singleton=1',
      );
      if (metadata.length != 1 ||
          metadata.single['profile_id'] != profile.profileId ||
          metadata.single['installation_id'] != profile.installationId) {
        throw const StoreException('foreign_profile');
      }
      final history = reader.select(
        'SELECT * FROM schema_migrations ORDER BY version',
      );
      if (history.length != version) {
        throw const StoreException('unknown_schema_preserved');
      }
      for (var i = 0; i < history.length; i++) {
        if (history[i]['version'] != i + 1 ||
            history[i]['digest'] != registry.at(i + 1).digest) {
          throw const StoreException('unknown_schema_preserved');
        }
      }
      final actualSql = reader.select(
        "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL",
      );
      if (schemaSqlDigest(actualSql.map((r) => r['sql'] as String)) !=
          registry.at(version).expectedSchemaDigest) {
        throw const StoreException('unknown_schema_preserved');
      }
    } on StoreException {
      rethrow;
    } catch (_) {
      throw const StoreException('corrupt_schema_preserved');
    } finally {
      try {
        reader?.close();
        if (captured) {
          _verifyCaptured(path, sources);
        }
      } finally {
        inspection?.deleteSync(recursive: true);
      }
    }
  }

  static void _verifyCaptured(
    String path,
    Map<String, Map<String, Object?>> sources,
  ) {
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$path$suffix'), original = sources[suffix];
      if (file.existsSync() != (original != null) ||
          (original != null &&
              (file.lengthSync() != original['length'] ||
                  sha256.convert(file.readAsBytesSync()).toString() !=
                      original['digest']))) {
        throw const StoreException('inspection_source_changed');
      }
    }
  }

  static void _validateWal(File file) {
    if (!file.existsSync() || file.lengthSync() == 0) {
      return;
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length < 32) {
      throw const StoreException('corrupt_wal_preserved');
    }
    final data = ByteData.sublistView(bytes);
    final magic = data.getUint32(0, Endian.big),
        page = data.getUint32(8, Endian.big);
    if (!const {0x377f0682, 0x377f0683}.contains(magic) ||
        data.getUint32(4, Endian.big) != 3007000 ||
        page < 512 ||
        page > 65536 ||
        (page & (page - 1)) != 0 ||
        (bytes.length - 32) % (page + 24) != 0) {
      throw const StoreException('corrupt_wal_preserved');
    }
    final endian = magic == 0x377f0682 ? Endian.little : Endian.big;
    var first = 0, second = 0;
    void checksum(int offset, int length) {
      for (var i = offset; i < offset + length; i += 8) {
        first = (first + data.getUint32(i, endian) + second) & 0xffffffff;
        second = (second + data.getUint32(i + 4, endian) + first) & 0xffffffff;
      }
    }

    checksum(0, 24);
    if (first != data.getUint32(24, Endian.big) ||
        second != data.getUint32(28, Endian.big)) {
      throw const StoreException('corrupt_wal_preserved');
    }
    for (var offset = 32; offset < bytes.length; offset += page + 24) {
      if (data.getUint32(offset + 8, Endian.big) !=
              data.getUint32(16, Endian.big) ||
          data.getUint32(offset + 12, Endian.big) !=
              data.getUint32(20, Endian.big)) {
        // SQLite resets the salts when reusing a checkpointed WAL, and need not
        // truncate its older physical tail. That tail is outside this cycle.
        // A rolled-back cycle may have no commit; native copied-WAL inspection
        // then observes the checkpointed main. Current-salt damage still fails.
        return;
      }
      if (data.getUint32(offset, Endian.big) == 0) {
        throw const StoreException('corrupt_wal_preserved');
      }
      checksum(offset, 8);
      checksum(offset + 24, page);
      if (first != data.getUint32(offset + 16, Endian.big) ||
          second != data.getUint32(offset + 20, Endian.big)) {
        throw const StoreException('corrupt_wal_preserved');
      }
    }
  }

  void _checkExpected(StoreToken expected) {
    if (expected.profileId != profileId) {
      throw const StoreException('foreign_profile');
    }
    if (expected.generation != token.generation) {
      throw const StoreException('stale_generation');
    }
    if (admission != StoreAdmission.open) {
      throw const StoreException('recovery_required');
    }
  }

  Future<void> _checkMetadata(SqliteReadContext tx, StoreToken expected) async {
    final row = await tx.get(
      'SELECT profile_id,generation,write_state FROM profile_state WHERE singleton=1',
    );
    if (row['profile_id'] != expected.profileId) {
      throw const StoreException('foreign_profile');
    }
    if (row['generation'] != expected.generation ||
        row['write_state'] != 'writable') {
      throw const StoreException('stale_generation');
    }
  }

  Future<T> _serialize<T>(Future<T> Function() run) {
    final completion = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completion.complete(await run());
      } catch (error, stack) {
        completion.completeError(error, stack);
      }
    });
    return completion.future;
  }

  @override
  Future<T> readTransaction<T>(
    Future<T> Function(LocalRead tx) callback, {
    StoreToken? expected,
  }) {
    final scope = expected ?? token;
    if (scope.profileId != profileId) {
      return Future.error(const StoreException('foreign_profile'));
    }
    return _serialize(() async {
      _checkExpected(scope);
      return _database.readTransaction((tx) async {
        await _checkMetadata(tx, scope);
        final context = LocalRead._(tx, scope);
        try {
          return await callback(context);
        } finally {
          context._active = false;
        }
      });
    });
  }

  @override
  Future<T> writeTransaction<T>(
    Future<T> Function(LocalTransaction tx) callback, {
    StoreToken? expected,
  }) => _write(callback, expected: expected);

  Future<T> _write<T>(
    Future<T> Function(LocalTransaction tx) callback, {
    StoreToken? expected,
    LocalAction? action,
  }) {
    final scope = expected ?? token;
    if (scope.profileId != profileId) {
      return Future.error(const StoreException('foreign_profile'));
    }
    return _serialize(() async {
      _checkExpected(scope);
      var statementsCompleted = false;
      try {
        return await _database.writeTransaction((tx) async {
          await _checkMetadata(tx, scope);
          final context = LocalTransaction._(tx, scope, action);
          late T result;
          try {
            result = await callback(context);
          } finally {
            context._active = false;
          }
          statementsCompleted = true;
          return result;
        });
      } catch (error) {
        // A callback-complete error is a real COMMIT error, regardless of a
        // later successful checkpoint/GC. SQLite statement failures also take
        // the conservative preserved close/reopen route.
        if (statementsCompleted || error is sqlite.SqliteException) {
          _admission = StoreAdmission.recovering;
          _uncertainAction = action;
          _recoveryEvents.add(RecoveryPhase.admissionClosed);
          await _recoverPool();
        }
        rethrow;
      }
    });
  }

  Future<void> _recoverPool() async {
    _poolEpoch++;
    try {
      for (final watch in _watches.toList()) {
        await watch.stop();
      }
      _recoveryEvents.add(RecoveryPhase.watchesCancelled);
      await _database.close();
      _recoveryEvents.add(RecoveryPhase.poolClosed);
      await profile.databasePath(expectedProfileId: profileId);
      _preflight(path, profile, schema);
      _database = SqliteDatabase.withFactory(_StoreOpenFactory(path));
      await _database.initialize();
      await _checkMetadata(_database, token);
      if ((await _database.get('PRAGMA integrity_check')).values.single !=
              'ok' ||
          (await _database.getAll('PRAGMA foreign_key_check')).isNotEmpty) {
        throw const StoreException('recovery_integrity_failed');
      }
      final action = _uncertainAction;
      reconciledOutcome = null;
      if (action != null) {
        final row = await _database.getOptional(
          'SELECT input_bytes,result_bytes FROM operations WHERE profile_id=? AND family=? AND operation_id=?',
          [profileId, action.family.name, action.operationId],
        );
        if (row != null) {
          if (!_sameBytes(row['input_bytes'], action.bytes)) {
            throw const StoreException('recovery_operation_mismatch');
          }
          reconciledOutcome = LocalActionResult(
            Uint8List.fromList((row['result_bytes'] as List).cast<int>()),
            replayed: true,
          );
        }
      }
      // Recreate each active subscription against the new pool before admission.
      _recoveryEvents.add(RecoveryPhase.validated);
      for (final watch in _watches.toList()) {
        watch.start();
      }
      _uncertainAction = null;
      _admission = StoreAdmission.open;
      _recoveryEvents.add(RecoveryPhase.ready);
    } catch (_) {
      _admission = StoreAdmission.closed;
      _recoveryEvents.add(RecoveryPhase.failed);
      rethrow;
    }
  }

  /// Explicit recovery retry preserves uncertain command bytes. Never creates
  /// a new command, clears the store or opens a dirty failed pool to owners.
  Future<void> recover() => _serialize(() async {
    if (_ownershipReleased) {
      throw const StoreException('store_closed');
    }
    if (admission == StoreAdmission.open) {
      return;
    }
    _admission = StoreAdmission.recovering;
    await _recoverPool();
  });

  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction tx) mutate, {
    StoreToken? expected,
  }) {
    if (action.target.profileId != profileId) {
      return Future.error(const StoreException('foreign_profile'));
    }
    return _write(
      (tx) async {
        final previous = await tx.getOptional(
          'SELECT input_bytes,result_bytes FROM operations WHERE profile_id=? AND family=? AND operation_id=?',
          [profileId, action.family.name, action.operationId],
        );
        if (previous != null) {
          if (!_sameBytes(previous['input_bytes'], action.bytes)) {
            throw const StoreException('operation_id_reuse');
          }
          return LocalActionResult(
            Uint8List.fromList((previous['result_bytes'] as List).cast<int>()),
            replayed: true,
          );
        }
        final revision = await tx.latestRevision(action.target);
        final latest = await tx.getOptional(
          'SELECT deleted FROM record_revisions WHERE profile_id=? AND kind=? AND record_id=? AND revision=?',
          [profileId, action.target.kind.name, action.target.id, revision],
        );
        if (latest?['deleted'] == 1 &&
            !action.action.name.endsWith('Restore')) {
          throw const StoreException('deleted_target');
        }
        if (revision != action.baseLocalRevision) {
          throw const StoreException('revision_conflict');
        }
        final result = localBytes(await mutate(tx));
        await tx
            .execute('INSERT INTO operations VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', [
              profileId,
              action.family.name,
              action.operationId,
              action.target.kind.name,
              action.target.id,
              action.action.name,
              action.semanticVersion,
              action.baseLocalRevision,
              action.eligibility.name,
              action.bytes,
              action.hash,
              result,
            ]);
        for (final dep in action.dependencies) {
          await tx.execute(
            'INSERT INTO operation_dependencies VALUES(?,?,?,?)',
            [
              profileId,
              action.family.name,
              action.operationId,
              dep.operationId,
            ],
          );
        }
        return LocalActionResult(result);
      },
      expected: expected,
      action: action,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) => readTransaction((tx) => tx.getAll(sql, parameters));
  @override
  Future<Map<String, dynamic>> get(
    String sql, [
    List<Object?> parameters = const [],
  ]) => readTransaction((tx) => tx.get(sql, parameters));
  @override
  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) => readTransaction((tx) => tx.getOptional(sql, parameters));
  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => Stream.multi((controller) {
    final registration = _Watch(
      this,
      sql,
      List.unmodifiable(parameters),
      controller,
    );
    _watches.add(registration);
    if (admission == StoreAdmission.open) {
      registration.start();
    } else {
      controller.addError(const StoreException('recovery_required'));
    }
    controller.onCancel = () async {
      _watches.remove(registration);
      await registration.stop();
    };
  }, isBroadcast: true);

  /// Replaces only future downloaded replica rows/checkpoints, never local work.
  Future<void> replaceReplica(
    String dataset,
    List<Map<String, Object?>> rows,
    Uint8List checkpoint,
    Uint8List coverage,
  ) => writeTransaction((tx) async {
    if (!const {
      'definitions',
      'plans',
      'workouts',
      'bodyweight',
      'targets',
    }.contains(dataset)) {
      throw const StoreException('unsupported_dataset');
    }
    await tx.execute(
      'DELETE FROM replica_rows WHERE profile_id=? AND dataset=?',
      [profileId, dataset],
    );
    for (final row in rows) {
      await tx.execute('INSERT INTO replica_rows VALUES(?,?,?,?,?)', [
        profileId,
        dataset,
        row['remote_id'],
        row['server_revision'],
        row['body_bytes'],
      ]);
    }
    await tx.execute(
      'INSERT INTO replica_checkpoints VALUES(?,?,?,?) ON CONFLICT(profile_id,dataset) DO UPDATE SET checkpoint_bytes=excluded.checkpoint_bytes,coverage_bytes=excluded.coverage_bytes',
      [profileId, dataset, checkpoint, coverage],
    );
  });

  /// T6 uses this after owned writer drain. Old handles remain fenced even if
  /// a different validated database is subsequently selected at this path.
  Future<void> fenceForReplacement() => writeTransaction((tx) async {
    await tx.execute(
      "UPDATE profile_state SET generation=generation+1,write_state='fenced' WHERE singleton=1",
    );
  });

  /// Supported coherent SQLite backup primitive, not a published backup claim.
  Future<void> backupTo(String destination) => _serialize(() async {
    _checkExpected(token);
    if (await File(destination).exists()) {
      throw const StoreException('backup_destination_exists');
    }
    await _database.readLock((reader) async {
      await _checkMetadata(reader, token);
      return _nativeBackup(reader, destination);
    });
  });
  Future<Map<String, Object?>> inventory() => readTransaction(
    (tx) async => {
      for (final table in preservedTables)
        table: [
          for (final row in await tx.getAll(
            'SELECT * FROM $table ORDER BY rowid',
          ))
            row,
        ],
    },
  );

  /// Owed durable input must be flushed before calling close. This barrier is
  /// after admission closes/watch drain and cannot write through this store.
  Future<void> close({Future<void> Function()? afterWatchDrain}) => _serialize(
    () async {
      if (_ownershipReleased) {
        return;
      } // Only after actual successful pool close.
      _admission = StoreAdmission.closed;
      _poolEpoch++;
      for (final watch in _watches.toList()) {
        await watch.stop();
      }
      await afterWatchDrain?.call();
      // Failure keeps the ownership lock and closed admission. Another adapter
      // must never enter while the old pool could still own work.
      await _database.close();
      _owner.close();
      _ownedPaths.remove(path);
      _ownershipReleased = true;
    },
  );
}

/// Keep the isolate closure outside the store's lexical context: only the
/// destination string may be captured, never a store Future/pool/owner.
Future<void> _nativeBackup(SqliteReadContext reader, String destination) =>
    reader.computeWithDatabase((source) async {
      final output = sqlite.sqlite3.open(destination);
      try {
        output.execute('PRAGMA synchronous=FULL');
        await (source as sqlite.Database)
            .backup(output, nPage: -1)
            .drain<void>();
      } finally {
        output.close();
      }
    });

final class _Watch {
  _Watch(this.store, this.sql, this.parameters, this.controller);
  final LocalStore store;
  final String sql;
  final List<Object?> parameters;
  final MultiStreamController<List<Map<String, dynamic>>> controller;
  StreamSubscription<dynamic>? subscription;
  void start() {
    final epoch = store.poolEpoch;
    subscription = store._database
        .watch(sql, parameters: parameters, throttle: null)
        .listen((rows) {
          store
              ._serialize(() async {
                if (epoch != store.poolEpoch ||
                    !store._watches.contains(this)) {
                  return;
                }
                store._checkExpected(store.token);
                await store._checkMetadata(store._database, store.token);
                if (epoch == store.poolEpoch) {
                  controller.add([
                    for (final row in rows) Map<String, dynamic>.from(row),
                  ]);
                }
              })
              .catchError((Object error) {
                controller.addError(error);
              });
        }, onError: controller.addError);
  }

  Future<void> stop() async {
    final old = subscription;
    subscription = null;
    await old?.cancel();
  }
}

class LocalRead {
  LocalRead._(this._context, this.token);
  final SqliteReadContext _context;
  bool _active = true;
  final StoreToken token;
  String get profileId => token.profileId;
  void _checkActive() {
    if (!_active) {
      throw const StoreException('expired_transaction_context');
    }
  }

  void requireRef(LocalRef ref, {RecordKind? kind}) {
    _checkActive();
    if (ref.profileId != profileId) {
      throw const StoreException('foreign_profile');
    }
    if (kind != null && ref.kind != kind) {
      throw const StoreException('foreign_kind');
    }
  }

  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _checkActive();
    return [
      for (final row in await _context.getAll(sql, parameters))
        Map<String, dynamic>.from(row),
    ];
  }

  Future<Map<String, dynamic>> get(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _checkActive();
    return Map<String, dynamic>.from(await _context.get(sql, parameters));
  }

  Future<Map<String, dynamic>?> getOptional(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _checkActive();
    final row = await _context.getOptional(sql, parameters);
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<int> latestRevision(LocalRef ref) async {
    requireRef(ref);
    final row = await get(
      'SELECT COALESCE(MAX(revision),0) AS revision FROM record_revisions WHERE profile_id=? AND kind=? AND record_id=?',
      [profileId, ref.kind.name, ref.id],
    );
    return row['revision'] as int;
  }

  Future<Map<String, dynamic>?> record(LocalRef ref) {
    requireRef(ref);
    return getOptional(
      'SELECT * FROM ${domainTables[RecordKind.values.indexOf(ref.kind)]} WHERE profile_id=? AND id=?',
      [profileId, ref.id],
    );
  }

  Future<Map<String, dynamic>?> localState(
    LocalStateKind kind,
    String key,
  ) => getOptional(
    'SELECT * FROM local_state WHERE profile_id=? AND state_kind=? AND state_key=?',
    [profileId, kind.name, key],
  );
}

final class LocalTransaction extends LocalRead {
  LocalTransaction._(super._context, super.token, this.action) : super._();
  SqliteWriteContext get _writer => _context as SqliteWriteContext;
  final LocalAction? action;
  Future<void> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    _checkActive();
    await _writer.execute(sql, parameters);
  }

  Future<int> writeRevision(
    LocalRef ref,
    Uint8List payload, {
    bool deleted = false,
    String layer = 'authored',
    String? sourceRevisionId,
  }) async {
    requireRef(ref);
    if (action != null && ref.kind.family != action!.family) {
      throw const StoreException('foreign_family');
    }
    if (layer == 'authored' && action == null) {
      throw const StoreException('domain_action_required');
    }
    final revision = await latestRevision(ref) + 1;
    await execute(
      'INSERT INTO record_revisions VALUES(?,?,?,?,?,?,?,?,?,?,?)',
      [
        profileId,
        ref.kind.name,
        ref.id,
        revision,
        deleted ? 1 : 0,
        layer,
        payload,
        action?.family.name,
        action?.operationId,
        sourceRevisionId,
        OperationInstant.now().text,
      ],
    );
    return revision;
  }

  Future<void> putRecord(
    LocalRef ref,
    int revision,
    Map<String, Object?> values, {
    bool deleted = false,
    String? sourceRevisionId,
  }) async {
    requireRef(ref);
    final table = domainTables[RecordKind.values.indexOf(ref.kind)];
    final columns = (await getAll(
      'PRAGMA table_info($table)',
    )).map((r) => r['name']).toSet();
    if (values.keys.any(
      (key) =>
          !columns.contains(key) ||
          const {
            'profile_id',
            'id',
            'kind',
            'revision',
            'deleted',
            'source_revision_id',
          }.contains(key),
    )) {
      throw const StoreException('invalid_projection_field');
    }
    final data = <String, Object?>{
      'profile_id': profileId,
      'id': ref.id,
      'kind': ref.kind.name,
      'revision': revision,
      'deleted': deleted ? 1 : 0,
      'source_revision_id': sourceRevisionId,
      ...values,
    };
    final names = data.keys.toList();
    await execute(
      'INSERT INTO $table(${names.join(',')}) VALUES(${List.filled(names.length, '?').join(',')}) ON CONFLICT(profile_id,id) DO UPDATE SET ${names.where((n) => n != 'profile_id' && n != 'id').map((n) => '$n=excluded.$n').join(',')}',
      data.values.toList(),
    );
  }

  Future<int> putLocalState(
    LocalStateKind kind,
    String key,
    Uint8List bytes, {
    required int expectedRevision,
    String status = 'active',
  }) async {
    final previous = await localState(kind, key);
    if ((previous?['revision'] ?? 0) != expectedRevision ||
        (previous != null && previous['generation'] != token.generation)) {
      throw const StoreException('stale_local_state');
    }
    final revision = expectedRevision + 1;
    await execute(
      'INSERT INTO local_state VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(profile_id,state_kind,state_key) DO UPDATE SET generation=excluded.generation,revision=excluded.revision,payload_bytes=excluded.payload_bytes,status=excluded.status,updated_at=excluded.updated_at',
      [
        profileId,
        kind.name,
        key,
        token.generation,
        revision,
        bytes,
        status,
        OperationInstant.now().text,
      ],
    );
    return revision;
  }

  Future<void> addReview({
    required String id,
    required String category,
    required Uint8List evidence,
  }) => execute('INSERT INTO reviews VALUES(?,?,?,?,?,?,?)', [
    profileId,
    id,
    action?.family.name,
    action?.operationId,
    category,
    evidence,
    OperationInstant.now().text,
  ]);
  Future<void> putArtifact({
    required String id,
    required Uint8List bytes,
    required String digest,
    required String parserVersion,
    required String format,
    required String disposition,
    Uint8List? observationTime,
  }) async {
    if (sha256.convert(bytes).toString() != digest) {
      throw const StoreException('artifact_digest_mismatch');
    }
    final existing = await getOptional(
      'SELECT * FROM source_artifacts WHERE profile_id=? AND artifact_id=?',
      [profileId, id],
    );
    if (existing != null) {
      if (!_sameBytes(existing['raw_bytes'], bytes) ||
          existing['parser_version'] != parserVersion ||
          existing['format'] != format ||
          existing['disposition'] != disposition) {
        throw const StoreException('artifact_id_reuse');
      }
      return;
    }
    await execute('INSERT INTO source_artifacts VALUES(?,?,?,?,?,?,?,?,?)', [
      profileId,
      id,
      digest,
      bytes,
      parserVersion,
      format,
      disposition,
      observationTime,
      OperationInstant.now().text,
    ]);
  }

  Future<void> mapOrigin(SourceOrigin origin, LocalRef ref) async {
    requireRef(ref);
    if (origin.profileId != profileId) {
      throw const StoreException('foreign_profile');
    }
    if (SourceOrigin.sourceKinds.toList().indexOf(origin.sourceKind) !=
        RecordKind.values.indexOf(ref.kind)) {
      throw const StoreException('foreign_kind');
    }
    final row = await getOptional(
      'SELECT local_kind,local_id FROM origin_mappings WHERE profile_id=? AND namespace=? AND source_kind=? AND external_id=?',
      [profileId, origin.namespace, origin.sourceKind, origin.externalId],
    );
    if (row != null) {
      if (row['local_kind'] != ref.kind.name || row['local_id'] != ref.id) {
        throw const StoreException('origin_mapping_changed');
      }
      return;
    }
    await execute('INSERT INTO origin_mappings VALUES(?,?,?,?,?,?)', [
      profileId,
      origin.namespace,
      origin.sourceKind,
      origin.externalId,
      ref.kind.name,
      ref.id,
    ]);
  }
}

bool _sameBytes(Object? actual, List<int> expected) =>
    actual is List &&
    actual.length == expected.length &&
    List.generate(
      expected.length,
      (i) => actual[i] == expected[i],
    ).every((same) => same);
String inventoryDigest(Map<String, Object?> inventory) =>
    sha256.convert(utf8.encode(jsonEncode(inventory))).toString();
