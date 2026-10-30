import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sqlite3_connection_pool/sqlite3_connection_pool.dart';
import 'package:sqlite_async/native.dart';
import 'package:sqlite_async/sqlite_async.dart';

final class _Factory extends NativeSqliteOpenFactory {
  _Factory(String path)
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
    'PRAGMA foreign_keys=ON',
  ];
}

Map<String, List<int>> bytesAt(String path) => {
  for (final suffix in ['', '-wal', '-shm'])
    if (File('$path$suffix').existsSync())
      suffix: File('$path$suffix').readAsBytesSync(),
};

void main() {
  test(
    'failed prepared COMMIT is finalized before pool close returns; original bytes stay stable',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-pool-close-');
      final path = '${root.path}/store.sqlite';
      sqlite.Database connection({required bool writer}) {
        final db = sqlite.sqlite3.open(path);
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA foreign_keys=ON');
        if (!writer) db.execute('PRAGMA query_only=ON');
        return db;
      }

      final pool = SqliteConnectionPool.open(
        name: path,
        openConnections: () => PoolConnections(connection(writer: true), [
          connection(writer: false),
        ], preparedStatementCacheSize: 0),
      );
      var closed = false;
      try {
        final lease = await pool.writer();
        try {
          // Public leased critical section: no pointers, retained connection or
          // forced GC. It exercises the pool's failed fresh-statement cleanup on
          // the calling isolate before any finalizer can stand in for close.
          await lease.unsafeAccess((conn) {
            conn.execute(
              'CREATE TABLE parent(id TEXT PRIMARY KEY, value TEXT)',
            );
            conn.execute(
              'CREATE TABLE child(id TEXT PRIMARY KEY, parent_id TEXT REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)',
            );
            conn.execute(
              "INSERT INTO parent VALUES('kept','80.125000000000000001')",
            );
            conn.execute('BEGIN IMMEDIATE');
            conn.execute("INSERT INTO child VALUES('rolled-back','missing')");
            expect(
              () => conn.select('COMMIT'),
              throwsA(
                isA<sqlite.SqliteException>().having(
                  (e) => e.extendedResultCode,
                  'deferred COMMIT',
                  787,
                ),
              ),
            );
            conn.execute('ROLLBACK');
            expect(conn.select('SELECT * FROM child'), isEmpty);
          });
        } finally {
          lease.returnLease();
        }
        expect(File('$path-wal').existsSync(), isTrue);
        await Future<void>.sync(pool.close);
        closed = true;
        expect(
          File('$path-wal').existsSync(),
          isFalse,
          reason:
              'A reported close cannot leave a failed prepared statement holding the WAL.',
        );
        expect(File('$path-shm').existsSync(), isFalse);
        final afterClose = bytesAt(path);
        final copy = File(path).copySync('${root.path}/inspection.sqlite');
        final inspect = sqlite.sqlite3.open(
          copy.path,
          mode: sqlite.OpenMode.readOnly,
        );
        try {
          expect(
            inspect.select('PRAGMA integrity_check').single.values.single,
            'ok',
          );
          expect(inspect.select('PRAGMA foreign_key_check'), isEmpty);
          expect(inspect.select('SELECT * FROM child'), isEmpty);
          expect(
            inspect.select('SELECT value FROM parent').single['value'],
            '80.125000000000000001',
          );
        } finally {
          inspect.close();
        }
        // An event turn plus independent copied-file inspection must not allow
        // a deferred old close to checkpoint/delete the original after return.
        await Future<void>(() {});
        expect(bytesAt(path), afterClose);
      } finally {
        if (!closed) await Future<void>.sync(pool.close);
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'async close waits for an admitted operation and leaves no late WAL mutation',
    () async {
      final root = await Directory.systemTemp.createTemp('alkion-async-close-');
      final path = '${root.path}/store.sqlite';
      final db = SqliteDatabase.withFactory(_Factory(path));
      final entered = Completer<void>(), release = Completer<void>();
      Future<void>? closing;
      Future<Object?>? outcome;
      try {
        await db.initialize();
        await db.execute('CREATE TABLE kept(value TEXT)');
        await db.execute('INSERT INTO kept VALUES(?)', [
          '82.450000000000000001',
        ]);
        final pending = db.readLock((tx) async {
          await tx.get('SELECT value FROM kept');
          entered.complete();
          await release.future;
          return tx.get('SELECT value FROM kept');
        });
        outcome = pending.then<Object?>(
          (value) => value,
          onError: (Object error) => error,
        );
        await entered.future;
        var closeReturned = false;
        closing = db.close().then((_) => closeReturned = true);
        // This is an ordering barrier, not a timed sleep or delayed retry.
        await Future<void>(() {});
        expect(
          closeReturned,
          isFalse,
          reason: 'An admitted operation still owns its leased connection.',
        );
        release.complete();
        expect(await outcome, {'value': '82.450000000000000001'});
        await closing;
        expect(File('$path-wal').existsSync(), isFalse);
        expect(File('$path-shm').existsSync(), isFalse);
        final afterClose = bytesAt(path);
        await Future<void>(() {});
        expect(bytesAt(path), afterClose);
      } finally {
        if (!release.isCompleted) release.complete();
        await outcome;
        await (closing ?? db.close());
        await root.delete(recursive: true);
      }
    },
  );
}
