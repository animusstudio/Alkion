import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sqlite_async/native.dart';
import 'package:sqlite_async/sqlite_async.dart';

/// Qualification only: no domain/schema/outbox adapter or app startup.
final class QualificationOpenFactory extends NativeSqliteOpenFactory {
  QualificationOpenFactory(String path)
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
    if (options.primaryConnection) 'PRAGMA wal_autocheckpoint = 0',
  ];
}

SqliteDatabase openQualificationDatabase(String path) =>
    SqliteDatabase.withFactory(QualificationOpenFactory(path));

void require(bool condition, String detail) {
  if (!condition) throw StateError(detail);
}

Future<void> createProbeSchema(SqliteDatabase db) =>
    db.writeTransaction((tx) async {
      await tx.execute('''CREATE TABLE parents (
    id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision >= 1),
    payload BLOB NOT NULL
  )''');
      await tx.execute('''CREATE TABLE children (
    id TEXT PRIMARY KEY,
    parent_id TEXT NOT NULL REFERENCES parents(id)
      DEFERRABLE INITIALLY DEFERRED,
    exact_value TEXT NOT NULL
  )''');
      await tx.execute('PRAGMA user_version = 1');
    });

Future<Map<String, Object?>> state(SqliteReadContext db) async => {
  'parents': [
    for (final row in await db.getAll('SELECT * FROM parents ORDER BY id'))
      Map<String, Object?>.from(row),
  ],
  'children': [
    for (final row in await db.getAll('SELECT * FROM children ORDER BY id'))
      Map<String, Object?>.from(row),
  ],
  'schema_version': (await db.get('PRAGMA user_version')).values.single,
};

String digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Recreates the driver's auto-discovered watch for each subscription. The
/// default driver's single-subscription stream itself must not be reused.
Stream<List<Map<String, Object?>>> probeWatch(SqliteDatabase db) =>
    Stream.multi((controller) {
      final subscription = db
          .watch('SELECT id, revision FROM parents ORDER BY id', throttle: null)
          .listen(
            (rows) => controller.add([
              for (final row in rows) Map<String, Object?>.from(row),
            ]),
            onError: controller.addError,
            onDone: controller.close,
          );
      controller.onCancel = subscription.cancel;
      controller.onPause = subscription.pause;
      controller.onResume = subscription.resume;
    }, isBroadcast: true);

/// Uses the supported sqlite3 online backup API on a leased reader. The
/// writer is never used as the backup source inside a write transaction.
Future<void> backupProbe(SqliteDatabase db, String destination) => db.readLock(
  (reader) => reader.computeWithDatabase((source) async {
    final output = sqlite.sqlite3.open(destination);
    try {
      output.execute('PRAGMA synchronous = FULL');
      await (source as sqlite.Database).backup(output, nPage: -1).drain<void>();
    } finally {
      output.close();
    }
  }),
);

Future<void> compareTwoReopens(
  String path,
  Map<String, Object?> expected,
) async {
  for (var reopen = 1; reopen <= 2; reopen++) {
    final database = openQualificationDatabase(path);
    try {
      await database.initialize();
      require(
        digest(await state(database)) == digest(expected),
        'Reopen $reopen changed state',
      );
      require(
        (await database.get('PRAGMA integrity_check')).values.single == 'ok',
        'Integrity check failed',
      );
      require(
        (await database.getAll('PRAGMA foreign_key_check')).isEmpty,
        'Foreign key check failed',
      );
    } finally {
      await database.close();
    }
  }
}

Future<Map<String, Object?>> qualifyDriver(Directory output) async {
  final path = p.join(output.path, 'driver.sqlite');
  var db = openQualificationDatabase(path);
  final cases = <String, String>{};
  final evidence = <String, Object?>{
    'sqlite_async': '0.14.7',
    'sqlite3_connection_pool': '0.2.15',
    'sqlite3_package': '3.5.0',
    'sqlite_native': sqlite.sqlite3.version.libVersion,
    'dart': Platform.version,
    'cases': cases,
    'physical_power_loss': 'UNRUN',
    'android': 'UNRUN',
    'app_boot': 'UNRUN',
  };
  try {
    await db.initialize();
    await db.withAllConnections((writer, readers) async {
      for (final connection in [writer, ...readers]) {
        require(
          (await connection.get('PRAGMA foreign_keys')).values.single == 1,
          'FK disabled on connection',
        );
        require(
          (await connection.get('PRAGMA synchronous')).values.single == 2,
          'FULL disabled on connection',
        );
        require(
          (await connection.get('PRAGMA journal_mode')).values.single == 'wal',
          'WAL disabled',
        );
      }
    });
    evidence['compile_options'] = [
      for (final row in await db.getAll('PRAGMA compile_options'))
        row.values.single,
    ];
    cases['all_connection_pragmas'] = 'PASS';
    await createProbeSchema(db);
    await db.execute('INSERT INTO parents VALUES (?, ?, ?)', [
      'base',
      1,
      [0, 255, 1, 0],
    ]);
    final baseline = await state(db);
    try {
      await db.writeTransaction<void>((tx) async {
        await tx.execute('INSERT INTO parents VALUES (?, ?, ?)', [
          'rollback',
          1,
          [4, 5],
        ]);
        throw StateError('injected callback failure after SQL');
      });
      throw StateError('Callback failure did not propagate');
    } catch (error) {
      require(
        error is StateError &&
            error.message == 'injected callback failure after SQL',
        'Wrong rollback failure: $error',
      );
    }
    require(
      digest(await state(db)) == digest(baseline),
      'Callback rollback mutated rows',
    );
    cases['statement_success_then_callback_rollback'] = 'PASS';

    final beforeFailureWatch = probeWatch(db);
    final watchReady = Completer<void>();
    final failureWatch = beforeFailureWatch.listen((rows) {
      if (!watchReady.isCompleted) watchReady.complete();
    });
    await watchReady.future.timeout(const Duration(seconds: 10));
    var statementsSucceeded = false;
    try {
      await db.writeTransaction((tx) async {
        await tx.execute('INSERT INTO parents VALUES (?, ?, ?)', [
          'commit-fail-parent',
          1,
          [6, 7],
        ]);
        await tx.execute('INSERT INTO children VALUES (?, ?, ?)', [
          'commit-fail-child',
          'missing',
          '80.0000000000010',
        ]);
        statementsSucceeded = true;
      });
      throw StateError('Deferred foreign key COMMIT unexpectedly succeeded');
    } on sqlite.SqliteException catch (error) {
      require(
        statementsSucceeded,
        'Failure occurred before successful statements',
      );
      require(
        error.extendedResultCode == 787,
        'Expected SQLITE_CONSTRAINT_FOREIGNKEY: $error',
      );
    }
    require(
      await db.getAutoCommit(),
      'Failed COMMIT left dangling transaction',
    );
    require(
      digest(await state(db)) == digest(baseline),
      'COMMIT failure did not rollback all statements',
    );
    cases['real_commit_failure_after_successful_statements'] = 'PASS';
    // Retain the mandatory recovery boundary. The old qualification's locked
    // checkpoint diagnosis is historical; record this stack's raw result below.
    evidence['checkpoint_after_commit_error'] = <String, Object?>{
      'status':
          'No safe dirty-pool reuse guarantee; mandatory drain/close/reopen',
      'historical_stack': 'sqlite_async 0.14.2 / pool 0.2.5 / SQLite 3.53.1',
      'historical_error': 'SQLITE_LOCKED (6), prior lifecycle diagnosis',
      'historical_cause':
          'Prepared-statement lifecycle was an inference in that qualification',
    };
    try {
      final observed = await db.writeLock(
        (writer) => writer.getAll('PRAGMA wal_checkpoint(TRUNCATE)'),
      );
      (evidence['checkpoint_after_commit_error']
          as Map<String, Object?>)['observed'] = [
        for (final row in observed) Map<String, Object?>.from(row),
      ];
    } on sqlite.SqliteException catch (error) {
      require(error.resultCode == 6, 'Unexpected checkpoint error: $error');
      (evidence['checkpoint_after_commit_error']
          as Map<String, Object?>)['observed_error'] = error
          .toString();
    }
    final errorBackup = p.join(
      output.path,
      'supported-after-error-backup.sqlite',
    );
    await backupProbe(db, errorBackup);
    await compareTwoReopens(errorBackup, baseline);
    cases['supported_backup_after_commit_error_two_reopens'] = 'PASS';
    // A store owner must close mutation admission, drain all owners and cancel
    // watches first. No ordinary write reuses this pool after COMMIT failure.
    await failureWatch.cancel();
    await db.close();
    db = openQualificationDatabase(path);
    await db.initialize();
    require(
      digest(await state(db)) == digest(baseline),
      'Recovery changed rows/bytes/revisions',
    );
    final recoveredWatch = await probeWatch(
      db,
    ).first.timeout(const Duration(seconds: 10));
    require(
      recoveredWatch.single['revision'] == 1,
      'Recovered watch changed revision',
    );
    final checkpoint = await db.writeLock(
      (writer) => writer.getAll('PRAGMA wal_checkpoint(TRUNCATE)'),
    );
    require(
      checkpoint.single['busy'] == 0,
      'Recovered pool checkpoint still busy',
    );
    await db.execute('UPDATE parents SET payload = ? WHERE id = ?', [
      [0, 255, 1, 0, 99],
      'base',
    ]);
    require(
      digest(await state(db)) != digest(baseline),
      'Recovered new write did not persist',
    );
    cases['failed_commit_drain_close_reopen_watch_newwrite_checkpoint'] =
        'PASS';

    try {
      await db.execute('UPDATE parents SET revision = 0 WHERE id = ?', [
        'base',
      ]);
      throw StateError('Revision CHECK accepted invalid revision');
    } on sqlite.SqliteException catch (error) {
      require(error.extendedResultCode == 275, 'Wrong CHECK failure');
    }
    cases['revision_check'] = 'PASS';

    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final order = <int>[];
    final first = db.writeTransaction((tx) async {
      order.add(1);
      firstEntered.complete();
      await releaseFirst.future;
      await tx.execute(
        'UPDATE parents SET revision = revision + 1 WHERE id = ?',
        ['base'],
      );
    });
    await firstEntered.future;
    final second = db.writeTransaction((tx) async {
      order.add(2);
      require(
        (await tx.get('SELECT revision FROM parents WHERE id = ?', [
              'base',
            ]))['revision'] ==
            2,
        'Second writer missed committed predecessor',
      );
      await tx.execute(
        'UPDATE parents SET revision = revision + 1 WHERE id = ?',
        ['base'],
      );
    });
    releaseFirst.complete();
    await Future.wait([first, second]);
    require(jsonEncode(order) == '[1,2]', 'Writers were not ordered');
    cases['ordered_writers'] = 'PASS';

    final watch = probeWatch(db);
    final observedInitial = await watch.first.timeout(
      const Duration(seconds: 10),
    );
    require(
      observedInitial.single['revision'] == 3,
      'Watch initial state wrong',
    );
    final watched = Completer<void>();
    final subscription = watch.listen((rows) {
      if (rows.any((row) => row['id'] == 'watched') && !watched.isCompleted) {
        watched.complete();
      }
    });
    await db.execute('INSERT INTO parents VALUES (?, ?, ?)', [
      'watched',
      1,
      [8, 9],
    ]);
    await watched.future.timeout(const Duration(seconds: 10));
    await subscription.cancel();
    require(
      (await watch.first.timeout(const Duration(seconds: 10))).length == 2,
      'Watch relisten failed',
    );
    cases['watch_invalidation_and_relisten'] = 'PASS';

    final snapshotReady = Completer<void>();
    final releaseSnapshot = Completer<void>();
    final beforeSnapshot = await state(db);
    final reading = db.readTransaction((reader) async {
      final firstSnapshot = await state(reader);
      snapshotReady.complete();
      await releaseSnapshot.future;
      require(
        digest(await state(reader)) == digest(firstSnapshot),
        'Read snapshot changed under concurrent writer',
      );
      return firstSnapshot;
    });
    await snapshotReady.future.timeout(const Duration(seconds: 10));
    try {
      await db.writeTransaction((writer) async {
        await writer.execute('INSERT INTO parents VALUES (?, ?, ?)', [
          'snapshot-new',
          2,
          [42, 0, 255],
        ]);
        await writer.execute('INSERT INTO children VALUES (?, ?, ?)', [
          'snapshot-child',
          'snapshot-new',
          '99.0000000000010',
        ]);
      });
    } finally {
      releaseSnapshot.complete();
    }
    require(
      digest(await reading) == digest(beforeSnapshot),
      'Initial snapshot was incoherent',
    );
    require(
      digest(await state(db)) != digest(beforeSnapshot),
      'Snapshot writer did not commit',
    );
    cases['read_transaction_snapshot_across_concurrent_writer'] = 'PASS';

    // Checkpoint the baseline, then put a committed value only in the WAL.
    await db.writeLock(
      (writer) => writer.getAll('PRAGMA wal_checkpoint(TRUNCATE)'),
    );
    await db.execute('INSERT INTO parents VALUES (?, ?, ?)', [
      'wal-tail',
      4,
      [11, 0, 255, 12],
    ]);
    await db.execute('INSERT INTO children VALUES (?, ?, ?)', [
      'wal-child',
      'wal-tail',
      '80.0000000000010',
    ]);
    require(await File('$path-wal').length() > 0, 'No committed WAL tail');
    final committed = await state(db);
    final hotCopyPath = p.join(output.path, 'unsupported-hot-main-copy.sqlite');
    await File(path).copy(hotCopyPath);
    final hotCopy = sqlite.sqlite3.open(hotCopyPath);
    try {
      require(
        hotCopy.select("SELECT * FROM parents WHERE id = 'wal-tail'").isEmpty,
        'Negative control unexpectedly contains WAL tail',
      );
    } finally {
      hotCopy.close();
    }
    cases['hot_main_copy_negative_control_detected'] = 'PASS';

    final partialWrite = Completer<void>();
    final releaseWrite = Completer<void>();
    final concurrentWriter = db.writeTransaction((tx) async {
      await tx.execute('INSERT INTO parents VALUES (?, ?, ?)', [
        'concurrent',
        5,
        [99, 1, 0, 99],
      ]);
      partialWrite.complete();
      await releaseWrite.future;
      await tx.execute('INSERT INTO children VALUES (?, ?, ?)', [
        'concurrent-child',
        'concurrent',
        '123456789.00000000000010',
      ]);
    });
    await partialWrite.future;
    final backupPath = p.join(output.path, 'supported-backup.sqlite');
    try {
      await backupProbe(db, backupPath).timeout(const Duration(seconds: 15));
    } finally {
      releaseWrite.complete();
      await concurrentWriter;
    }
    await compareTwoReopens(backupPath, committed);
    final after = await state(db);
    require(
      digest(after) != digest(committed),
      'Concurrent writer did not commit',
    );
    require(
      (await db.get('SELECT * FROM parents WHERE id = ?', [
            'concurrent',
          ]))['revision'] ==
          5,
      'Concurrent parent missing',
    );
    require(
      (await db.get('SELECT * FROM children WHERE id = ?', [
            'concurrent-child',
          ]))['exact_value'] ==
          '123456789.00000000000010',
      'Concurrent child missing',
    );
    evidence['backup_expected_state'] = committed;
    evidence['source_after_concurrent_writer'] = after;
    evidence['backup_expected_state_sha256'] = digest(committed);
    evidence['backup_file_sha256'] = sha256
        .convert(await File(backupPath).readAsBytes())
        .toString();
    cases['supported_online_backup_concurrent_writer_wal_two_reopens'] = 'PASS';
    await db.close();
    await compareTwoReopens(path, after);
    cases['wal_source_close_two_reopens'] = 'PASS';
  } finally {
    if (!db.closed) await db.close();
  }
  return evidence;
}

Future<void> child(String path, String boundary) async {
  require(
    boundary == 'before' || boundary == 'after',
    'Invalid child boundary',
  );
  require(
    p.isWithin('/tmp', p.absolute(path)),
    'Child database must be disposable',
  );
  require(
    p.basename(path) == 'crash-$boundary.sqlite',
    'Invalid child database name',
  );
  require(
    await File(
          p.join(p.dirname(path), '.qualification-owned'),
        ).readAsString() ==
        'alkion-driver/1',
    'Missing owned qualification marker',
  );
  final db = openQualificationDatabase(path);
  await db.initialize();
  await db.writeTransaction((tx) async {
    await tx.execute('INSERT INTO parents VALUES (?, ?, ?)', [
      'crash',
      7,
      [0, 255, 77],
    ]);
    await tx.execute('INSERT INTO children VALUES (?, ?, ?)', [
      'crash-child',
      'crash',
      '72.2500000000000000',
    ]);
    if (boundary == 'before') {
      stdout.writeln('BOUNDARY before COMMIT');
      await stdout.flush();
      await Completer<void>().future;
    }
  });
  stdout.writeln('BOUNDARY after COMMIT');
  await stdout.flush();
  await Completer<void>().future;
}

Future<void> qualifyChildCrash(Directory output, String boundary) async {
  final path = p.join(output.path, 'crash-$boundary.sqlite');
  final setup = openQualificationDatabase(path);
  await createProbeSchema(setup);
  final baseline = await state(setup);
  await setup.close();
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    Platform.script.toFilePath(),
    '--child',
    path,
    boundary,
  ], workingDirectory: Directory.current.path);
  final errorOutput = process.stderr.transform(utf8.decoder).join();
  final ready = Completer<void>();
  final outputSubscription = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line == 'BOUNDARY $boundary COMMIT' && !ready.isCompleted) {
          ready.complete();
        }
      });
  process.exitCode.then((code) {
    if (!ready.isCompleted) {
      ready.completeError(StateError('Child exited $code before boundary'));
    }
  });
  try {
    await ready.future.timeout(const Duration(seconds: 45));
    require(process.kill(ProcessSignal.sigkill), 'Could not kill owned child');
    require(await process.exitCode == -9, 'Child did not stop by SIGKILL');
    // Dart build-hook progress may be printed to stderr. Preserve exact bytes;
    // boundary, actual SIGKILL and restored SQL state determine success.
    await File(
      '$path.stderr.txt',
    ).writeAsString(await errorOutput, flush: true);
  } finally {
    process.kill(ProcessSignal.sigkill);
    await outputSubscription.cancel();
  }
  final expected = boundary == 'before'
      ? baseline
      : <String, Object?>{
          'parents': [
            {
              'id': 'crash',
              'revision': 7,
              'payload': [0, 255, 77],
            },
          ],
          'children': [
            {
              'id': 'crash-child',
              'parent_id': 'crash',
              'exact_value': '72.2500000000000000',
            },
          ],
          'schema_version': 1,
        };
  await compareTwoReopens(path, expected);
}

Future<Directory> ownedOutput(String path) async {
  final normalized = p.normalize(p.absolute(path));
  require(p.isWithin('/tmp', normalized), 'Output must be strictly under /tmp');
  require(
    !p.isWithin(Directory.current.parent.path, normalized),
    'Output must be outside checkout',
  );
  var component = '/';
  for (final part in p.split(normalized).skip(1)) {
    component = p.join(component, part);
    require(
      await FileSystemEntity.type(component, followLinks: false) !=
          FileSystemEntityType.link,
      'Output path contains a symlink',
    );
  }
  require(
    await FileSystemEntity.type(normalized, followLinks: false) ==
        FileSystemEntityType.notFound,
    'Output must be a fresh owned directory',
  );
  final directory = await Directory(normalized).create();
  await File(
    p.join(normalized, '.qualification-owned'),
  ).writeAsString('alkion-driver/1', flush: true);
  return directory;
}

Future<void> main(List<String> args) async {
  if (args.length == 2 && args[0] == '--diagnose') {
    final output = await ownedOutput(args[1]);
    final results = <String, Object?>{};
    for (final mode in ['clean', 'callback', 'commit_fk', 'statement_check']) {
      final db = openQualificationDatabase(p.join(output.path, '$mode.sqlite'));
      try {
        await createProbeSchema(db);
        await db.execute('INSERT INTO parents VALUES (?, ?, ?)', [
          'base',
          1,
          [1],
        ]);
        try {
          if (mode == 'callback') {
            await db.writeTransaction<void>((tx) async {
              await tx.execute('INSERT INTO parents VALUES (?, ?, ?)', [
                'rollback',
                1,
                [2],
              ]);
              throw StateError('injected callback failure');
            });
          } else if (mode == 'commit_fk') {
            await db.writeTransaction((tx) async {
              await tx.execute('INSERT INTO children VALUES (?, ?, ?)', [
                'invalid',
                'missing',
                '1.00',
              ]);
            });
          } else if (mode == 'statement_check') {
            await db.execute('UPDATE parents SET revision = 0');
          }
        } catch (error) {
          results['$mode.expected_error'] = error.toString();
        }
        results['$mode.state'] = await state(db);
        results['$mode.autocommit'] = await db.getAutoCommit();
        try {
          results['$mode.checkpoint'] = [
            for (final row in await db.writeLock(
              (writer) => writer.getAll('PRAGMA wal_checkpoint(TRUNCATE)'),
            ))
              Map<String, Object?>.from(row),
          ];
        } catch (error) {
          results['$mode.checkpoint_error'] = error.toString();
        }
        if (mode == 'commit_fk') {
          for (final rawMode in ['select', 'execute']) {
            try {
              await db.writeLock(
                (writer) => writer.computeWithDatabase((native) async {
                  if (rawMode == 'select') {
                    native.select('PRAGMA wal_checkpoint(TRUNCATE)');
                  } else {
                    native.execute('PRAGMA wal_checkpoint(TRUNCATE)');
                  }
                }),
              );
              results['$mode.raw_$rawMode'] = 'PASS';
            } catch (error) {
              results['$mode.raw_$rawMode'] = error.toString();
            }
          }
          final backupPath = p.join(output.path, 'after-error-backup.sqlite');
          try {
            await backupProbe(db, backupPath);
            await compareTwoReopens(backupPath, await state(db));
            results['$mode.backup_two_reopens'] = 'PASS';
          } catch (error) {
            results['$mode.backup_two_reopens'] = error.toString();
          }
        }
      } finally {
        await db.close();
      }
      if (mode == 'commit_fk') {
        final reopened = openQualificationDatabase(
          p.join(output.path, '$mode.sqlite'),
        );
        try {
          results['$mode.after_close_reopen_state'] = await state(reopened);
          results['$mode.after_close_reopen_checkpoint'] = [
            for (final row in await reopened.writeLock(
              (writer) => writer.getAll('PRAGMA wal_checkpoint(TRUNCATE)'),
            ))
              Map<String, Object?>.from(row),
          ];
        } catch (error) {
          results['$mode.after_close_reopen_error'] = error.toString();
        } finally {
          await reopened.close();
        }
      }
    }
    await File(p.join(output.path, 'diagnosis.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(results),
      flush: true,
    );
    stdout.writeln(jsonEncode(results));
    return;
  }
  if (args.length == 3 && args[0] == '--child') {
    await child(args[1], args[2]);
    return;
  }
  require(
    args.length == 2 && args[0] == '--output',
    'Use make -C app alkion-driver-qualification ALKION_OUTPUT=<fresh /tmp path>',
  );
  final output = await ownedOutput(args[1]);
  final result = await qualifyDriver(output);
  await qualifyChildCrash(output, 'before');
  await qualifyChildCrash(output, 'after');
  result['child_stderr'] = {
    for (final boundary in ['before', 'after'])
      boundary: await File(
        p.join(output.path, 'crash-$boundary.sqlite.stderr.txt'),
      ).readAsString(),
  };
  (result['cases']
          as Map<
            String,
            String
          >)['child_sigkill_before_after_commit_two_reopens'] =
      'PASS';
  await File(p.join(output.path, 'qualification.json')).writeAsString(
    const JsonEncoder.withIndent('  ').convert(result),
    flush: true,
  );
  stdout.writeln(jsonEncode(result));
}
