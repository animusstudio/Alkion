// Synthetic source installations for capture-profile tests.
//
// A fixture is a disposable directory laid out like the app-support
// directory: the PowerSync database `workout-tracker.db` (optionally with
// committed rows still only in its WAL, as a killed process leaves it), a
// malformed draft, an expired finished snapshot and an orphan `.tmp` file.
// Every value is synthetic.
//
// [CaptureFixture.snapshot] observes the source WITHOUT opening it: it copies
// the database and its WAL into a private scratch directory and reads the
// copy, so observing never creates, updates or checkpoints anything in the
// fixture itself.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:workout_tracker/sync/schema.dart';

const fixtureUserId = 'synthetic-user-1';
const fixtureDatabaseName = 'workout-tracker.db';

/// The seven replicated tables, in capture order.
const fixtureTables = [
  'exercises',
  'day_templates',
  'day_template_items',
  'sessions',
  'sets',
  'bodyweight_logs',
  'muscle_targets',
];

/// Raw bytes of the non-SQLite source files every fixture carries.
final Map<String, List<int>> fixtureRawFiles = {
  // Truncated mid-write: the normal loader would delete it.
  'workout-draft.json':
      utf8.encode('{"sessionId":null,"startedAt":"2026-10-01T10:00:00.000","ex'),
  // Well formed but long expired: the normal resume window would clear it.
  'workout-last-finished.json': utf8.encode(
      '{"sessionId":"s-1","finishedAt":"2026-01-02T09:30:00.000","sets":[]}'),
  // An orphan temporary file from an interrupted save.
  'workout-draft.json.tmp': utf8.encode('{"sessionId":"s-'),
};

/// Preferences a synthetic installation holds. No identity has been generated
/// yet, so identity generation during opening would be visible.
const Map<String, Object> fixturePreferences = {
  'unit': 'kg',
  'identity.onboarding_complete': true,
  'settings.sync_enabled': false,
};

/// Ids written only after the main file was last checkpointed, so in a
/// [CaptureFixture.create] `committedTailInWal` fixture they exist only in the
/// WAL.
const walTailIds = ['own-day-b', 'own-item-b1', 's-2', 'set-2-1'];

class CaptureFixture {
  CaptureFixture._(this.dir);

  final Directory dir;

  String get dbPath => '${dir.path}/$fixtureDatabaseName';

  /// Creates a synthetic installation. [sourceSchema] simulates a database
  /// left by another app layout; [queue] false leaves the upload queue empty;
  /// [committedTailInWal] leaves the last committed transaction only in the
  /// WAL, as after a process kill.
  static Future<CaptureFixture> create({
    Schema sourceSchema = schema,
    bool queue = true,
    bool committedTailInWal = false,
  }) async {
    SharedPreferences.setMockInitialValues(fixturePreferences);
    final dir = await Directory.systemTemp.createTemp('reps-capture-fixture');
    final fixture = CaptureFixture._(dir);
    final staging =
        await Directory.systemTemp.createTemp('reps-capture-fixture-staging');
    final stagingPath = '${staging.path}/$fixtureDatabaseName';

    var database = PowerSyncDatabase(schema: sourceSchema, path: stagingPath);
    await database.initialize();
    await _seedSynced(database);
    if (queue) await _seedLocal(database);
    // Closing checkpoints everything so far into the main file.
    await database.close();

    if (committedTailInWal) {
      database = PowerSyncDatabase(schema: sourceSchema, path: stagingPath);
      await database.initialize();
      await _seedTail(database);
      // Copy while the writer is still open: the tail transaction is
      // committed in the WAL but not checkpointed. The WAL index (-shm) is
      // volatile and is not carried over, as after a reboot.
      for (final suffix in const ['', '-wal']) {
        await File('$stagingPath$suffix').copy('${fixture.dbPath}$suffix');
      }
      await database.close();
    } else {
      await File(stagingPath).copy(fixture.dbPath);
    }
    await staging.delete(recursive: true);

    for (final entry in fixtureRawFiles.entries) {
      await File('${dir.path}/${entry.key}').writeAsBytes(entry.value, flush: true);
    }
    return fixture;
  }

  /// Ids from [walTailIds] that are present with the WAL but absent from the
  /// main database file alone, i.e. committed rows that live only in the WAL.
  Future<List<String>> walOnlyIds() async {
    final withWal = await snapshot();
    final mainOnly = await _snapshotFiles(walSuffixes: const []);
    bool has(SourceSnapshot s, String id) => s.rawRows.values
        .expand((rows) => rows)
        .any((row) => (jsonDecode(row) as List).first == id);
    return [
      for (final id in walTailIds)
        if (has(withWal, id) && !has(mainOnly, id)) id,
    ];
  }

  /// Observes the source through a private copy of the database and WAL.
  Future<SourceSnapshot> snapshot() => _snapshotFiles(walSuffixes: const ['-wal']);

  Future<SourceSnapshot> _snapshotFiles({required List<String> walSuffixes}) async {
    final scratch =
        await Directory.systemTemp.createTemp('reps-capture-snapshot');
    try {
      final copyPath = '${scratch.path}/$fixtureDatabaseName';
      await File(dbPath).copy(copyPath);
      for (final suffix in walSuffixes) {
        final source = File('$dbPath$suffix');
        if (await source.exists()) await source.copy('$copyPath$suffix');
      }
      final conn = sqlite.sqlite3.open(copyPath);
      try {
        return await _read(conn);
      } finally {
        conn.close();
      }
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  Future<SourceSnapshot> _read(sqlite.Database conn) async {
    List<String> rows(String sql) =>
        [for (final r in conn.select(sql)) jsonEncode(r.values)];

    final tables = [
      for (final r in conn.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
        r['name'] as String,
    ];
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return SourceSnapshot(
      rawRows: {
        for (final t in fixtureTables)
          t: rows('SELECT id, data FROM "ps_data__$t" ORDER BY id'),
      },
      allTables: {
        for (final t in tables) t: rows('SELECT * FROM "$t"')..sort(),
      },
      queueText: rows('SELECT id, tx_id, data FROM ps_crud ORDER BY id'),
      crudSequence: rows("SELECT seq FROM sqlite_sequence WHERE name = 'ps_crud'"),
      localTargetOp: rows(
          r"SELECT CAST(target_op AS TEXT) FROM ps_buckets WHERE name = '$local'"),
      sqliteFileDigests: _digests((name) =>
          name == fixtureDatabaseName || name == '$fixtureDatabaseName-wal'),
      sourceFileDigests: _digests(fixtureRawFiles.containsKey),
      fileNames: _fileNames(),
      preferences: {for (final k in prefs.getKeys()) k: prefs.get(k)},
    );
  }

  Map<String, String> _digests(bool Function(String name) include) {
    final out = <String, String>{};
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (include(name)) out[name] = sha256.convert(f.readAsBytesSync()).toString();
    }
    return out;
  }

  /// Every file name in the fixture except SQLite's volatile WAL index.
  List<String> _fileNames() => [
        for (final f in dir.listSync())
          if (!f.path.endsWith('-shm')) f.uri.pathSegments.last,
      ]..sort();

  Future<PowerSyncDatabase> openNormally({Schema withSchema = schema}) async {
    final database = PowerSyncDatabase(schema: withSchema, path: dbPath);
    await database.initialize();
    return database;
  }

  Future<void> dispose() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

class SourceSnapshot {
  SourceSnapshot({
    required this.rawRows,
    required this.allTables,
    required this.queueText,
    required this.crudSequence,
    required this.localTargetOp,
    required this.sqliteFileDigests,
    required this.sourceFileDigests,
    required this.fileNames,
    required this.preferences,
  });

  /// `[id, data]` of every row of the seven tables' raw storage, by id.
  final Map<String, List<String>> rawRows;

  /// Every row of every SQLite table, including PowerSync's own.
  final Map<String, List<String>> allTables;

  /// `[id, tx_id, data]` of the upload queue, in queue order.
  final List<String> queueText;
  final List<String> crudSequence;
  final List<String> localTargetOp;

  /// Main database file and WAL bytes.
  final Map<String, String> sqliteFileDigests;

  /// Draft, finished and orphan temporary file bytes.
  final Map<String, String> sourceFileDigests;
  final List<String> fileNames;
  final Map<String, Object?> preferences;
}

/// Rows as a real synced installation holds them: written straight to the
/// replica tables, so they never enter the upload queue.
Future<void> _seedSynced(PowerSyncDatabase db) async {
  await db.writeTransaction((tx) async {
    Future<void> put(String table, String id, Map<String, Object?> data) =>
        tx.execute('INSERT INTO "ps_data__$table" (id, data) VALUES (?, ?)',
            [id, jsonEncode(data)]);
    await put('exercises', 'tpl-ex-bench', {
      'name': 'Bench Press', 'slug': 'bench-press', 'muscle_group': 'chest',
      'is_template': 1, 'created_by': null, 'equip': 'barbell', 'compound': 1,
      'base_weight_kg': '20', 'plate_step_kg': '2.50',
    });
    await put('exercises', 'tpl-ex-squat', {
      'name': 'Back Squat', 'slug': 'back-squat', 'muscle_group': 'legs',
      'is_template': 1, 'created_by': null, 'equip': 'barbell', 'compound': 1,
      'base_weight_kg': '20', 'plate_step_kg': '2.50',
    });
    await put('day_templates', 'tpl-day-a', {
      'slug': 'push-a', 'name': 'Push A', 'position': 1, 'is_template': 1,
      'created_by': null, 'focus': 'Chest', 'scheduled_weekday': 1,
    });
    await put('day_template_items', 'tpl-item-a1', {
      'day_template_id': 'tpl-day-a', 'exercise_id': 'tpl-ex-bench',
      'position': 1, 'target_working_sets': 3, 'is_template': 1,
      'created_by': null,
    });
    await put('muscle_targets', 'synced-mt-chest', {
      'user_id': fixtureUserId, 'muscle': 'chest', 'target_sets': 12,
      'created_at': '2026-09-01T08:00:00.000Z',
    });
  });
}

/// Local writes through the public views: each transaction enters the upload
/// queue with its own transaction id.
Future<void> _seedLocal(PowerSyncDatabase db) async {
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO exercises (id, name, slug, muscle_group, is_template, '
      'created_by, created_at, equip, compound, base_weight_kg, plate_step_kg) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['own-ex-row', 'Cable Row', 'cable-row-ownexrow', 'back', 0,
        fixtureUserId, '2026-09-02T08:00:00.000Z', 'cable', 0, '30', '5'],
    );
    // A pre-fix legacy row: is_template NULL and an empty base weight.
    await tx.execute(
      'INSERT INTO exercises (id, name, slug, muscle_group, equip, compound, '
      'base_weight_kg, plate_step_kg) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      ['own-ex-legacy', 'Pec Deck', 'pec-deck-ownexleg', 'chest', '', 0, '',
        '2.50'],
    );
  });
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO sessions (id, user_id, date, split_label, day_template_id, '
      'created_at, duration_min) VALUES (?, ?, ?, ?, ?, ?, ?)',
      ['s-1', fixtureUserId, '2026-10-01', 'Push A', 'tpl-day-a',
        '2026-10-01T10:00:00.000Z', 55],
    );
    // No top set flagged yet; one set still points at a template exercise.
    for (final (id, n, w, reps, warm, ex) in [
      ('set-1-1', 1, '40', 10, 1, 'tpl-ex-bench'),
      ('set-1-2', 2, '80', 5, 0, 'tpl-ex-bench'),
      ('set-1-3', 3, '82.5', 4, 0, 'tpl-ex-bench'),
      ('set-1-4', 4, '50', 12, 0, 'own-ex-row'),
    ]) {
      await tx.execute(
        'INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, '
        'weight_kg, reps, rir, is_warmup, is_top_set, is_pr, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [id, 's-1', ex, fixtureUserId, n, w, reps, 2, warm, 0, 0,
          '2026-10-01T10:30:00.000Z'],
      );
    }
  });
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO bodyweight_logs (id, user_id, date, weight_kg, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['bw-1', fixtureUserId, '2026-10-01', '81.4', '2026-10-01T07:00:00.000Z'],
    );
    await tx.execute(
      'INSERT INTO bodyweight_logs (id, user_id, date, weight_kg, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['bw-2', fixtureUserId, '2026-10-02', '81.0', '2026-10-02T07:00:00.000Z'],
    );
    await tx.execute(
      'INSERT INTO muscle_targets (id, user_id, muscle, target_sets, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      ['mt-back', fixtureUserId, 'back', 10, '2026-10-01T07:05:00.000Z'],
    );
    await tx.execute(
        "UPDATE exercises SET name = 'Seated Cable Row' WHERE id = 'own-ex-row'");
    // A delete leaves its row absent but its operation queued.
    await tx.execute("DELETE FROM bodyweight_logs WHERE id = 'bw-2'");
  });
}

Future<void> _seedTail(PowerSyncDatabase db) async {
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO day_templates (id, slug, name, notes, position, is_template, '
      'created_by, created_at, focus, scheduled_weekday) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['own-day-b', 'pull-b', 'Pull B', '', 2, 0, fixtureUserId,
        '2026-10-03T08:00:00.000Z', 'Back', 3],
    );
    await tx.execute(
      'INSERT INTO day_template_items (id, day_template_id, exercise_id, '
      'position, target_working_sets, is_template, created_by, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      ['own-item-b1', 'own-day-b', 'tpl-ex-squat', 1, 4, 0, fixtureUserId,
        '2026-10-03T08:00:00.000Z'],
    );
    await tx.execute(
      'INSERT INTO sessions (id, user_id, date, split_label, day_template_id, '
      'created_at, duration_min) VALUES (?, ?, ?, ?, ?, ?, ?)',
      ['s-2', fixtureUserId, '2026-10-03', 'Pull B', 'own-day-b',
        '2026-10-03T10:00:00.000Z', 48],
    );
    await tx.execute(
      'INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, '
      'weight_kg, reps, is_warmup, is_top_set, is_pr, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ['set-2-1', 's-2', 'tpl-ex-squat', fixtureUserId, 1, '100', 5, 0, 0, 0,
        '2026-10-03T10:20:00.000Z'],
    );
  });
}

/// The app schema without the columns later releases added, simulating a
/// database left by an older, unqualified layout.
Schema olderLayoutSchema() => Schema([
      for (final table in schema.tables)
        Table(table.name, [
          for (final column in table.columns)
            if (!(table.name == 'exercises' &&
                    column.name == 'default_rest_seconds') &&
                !(table.name == 'day_templates' &&
                    column.name == 'scheduled_weekday'))
              column,
        ], indexes: table.indexes),
    ]);
