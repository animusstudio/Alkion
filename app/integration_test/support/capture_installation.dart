// Disposable synthetic installations for capture interruption, fault and
// Go-compatibility qualification.
//
// An installation is a fresh directory under the system temp directory:
//
//   <root>/reps-synthetic-installation   marker; nothing runs without it
//   <root>/app-support/                  laid out like the app-support
//                                        directory: workout-tracker.db (real
//                                        PowerSync SQLite, seven tables,
//                                        UUID ids, a non-empty upload queue),
//                                        optional draft bytes, and the
//                                        private capture/ area once used
//   <root>/prefs/shared_preferences.json file-backed preferences, kept apart
//                                        from the stores (a file beside them
//                                        would be an unknown source entry)
//
// Every value is synthetic. Nothing here reads or writes the real
// application-support directory, secure storage, credentials or exports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart'
    show ClearParameters;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_faults.dart';
import 'package:workout_tracker/capture/capture_journal.dart'
    show CaptureJournal;
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/capture/capture_transport.dart';
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/data/finished_session_store.dart';
import 'package:workout_tracker/data/models.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/sync/schema.dart';

const syntheticUser = '00000000-0000-4000-8000-000000000001';
const templateExercise = '00000000-0000-4000-8000-0000000000e1';
const ownedExercise = 'a1000000-0000-4000-8000-000000000001';
const syntheticSession = 'd1000000-0000-4000-8000-000000000001';
const installationMarker = 'reps-synthetic-installation';

/// Half-written draft bytes the ordinary loader would delete.
final malformedDraftBytes = utf8.encode(
  '{"sessionId":null,"startedAt":"2026-10-10T09',
);

/// What the source holds as a draft before a capture.
enum SyntheticDraft {
  /// No draft file and no workout running.
  none,

  /// A malformed draft file and no workout running.
  malformed,

  /// A malformed (stale) draft file and a running workout whose draft the
  /// capture flushes over it: the one requested source change.
  live,
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

String _digestOrUnreadable(File f) {
  try {
    return sha256Of(f.readAsBytesSync());
  } on FileSystemException {
    return 'unreadable';
  }
}

/// Every entry under [dir] (links not followed) with its SHA-256.
Map<String, String> treeDigest(Directory dir) => {
  if (dir.existsSync())
    for (final e in dir.listSync(recursive: true, followLinks: false))
      p.relative(e.path, from: dir.path): switch (e) {
        File f => sha256Of(f.readAsBytesSync()),
        Link l => 'link:${l.targetSync()}',
        _ => 'dir',
      },
};

/// Copies [from] into the new directory [to], bytes and modes.
Future<void> copyTree(Directory from, Directory to) async {
  final r = await Process.run('cp', ['-a', from.path, to.path]);
  if (r.exitCode != 0) throw StateError('copy failed: ${r.stderr}');
}

/// Preferences backed by one JSON file, replaced through a flushed
/// temporary file on every change, so a killed process leaves the last
/// completed write and another process can read it.
class FilePreferencesStore extends InMemorySharedPreferencesStore {
  FilePreferencesStore._(this.file, Map<String, Object> data)
    : super.withData(data);

  factory FilePreferencesStore.open(File file) {
    final data = <String, Object>{};
    if (file.existsSync()) {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      for (final MapEntry(:key, :value) in json.entries) {
        data[key] = value is List ? value.cast<String>() : value!;
      }
    }
    return FilePreferencesStore._(file, data);
  }

  final File file;

  static void write(File file, Map<String, Object> data) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(data), flush: true);
    tmp.renameSync(file.path);
  }

  Future<bool> _persist(bool changed) async {
    write(file, await getAll());
    return changed;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _persist(await super.setValue(valueType, key, value));

  @override
  Future<bool> remove(String key) async => _persist(await super.remove(key));

  @override
  Future<bool> clear() async => _persist(await super.clear());

  @override
  Future<bool> clearWithPrefix(String prefix) async =>
      _persist(await super.clearWithPrefix(prefix));

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async =>
      _persist(await super.clearWithParameters(parameters));
}

/// One disposable installation on disk (see the file comment).
class SyntheticInstallation {
  SyntheticInstallation(this.root)
    : source = Directory(p.join(root.path, 'app-support')),
      preferencesFile = File(
        p.join(root.path, 'prefs', 'shared_preferences.json'),
      );

  final Directory root;
  final Directory source;
  final File preferencesFile;
  late final CaptureLocations locations = CaptureLocations(source);

  File get draftFile => File(p.join(source.path, DraftStore.fileName));
  String get databasePath => p.join(source.path, 'workout-tracker.db');

  /// Refuses to act on anything but a marked synthetic installation under
  /// the system temp directory.
  void checkSynthetic() {
    final temp = Directory.systemTemp.resolveSymbolicLinksSync();
    final real = root.resolveSymbolicLinksSync();
    if (!p.isWithin(temp, real) ||
        !File(p.join(real, installationMarker)).existsSync()) {
      throw StateError('not a synthetic installation: ${root.path}');
    }
  }

  /// Creates a seeded installation in the new, empty [root].
  /// [blockedQueue] adds a queued operation whose row id is not a UUID: the
  /// producer seals it for diagnosis only, and the Go reader blocks it.
  static Future<SyntheticInstallation> create(
    Directory root, {
    SyntheticDraft draft = SyntheticDraft.live,
    bool blockedQueue = false,
  }) async {
    final i = SyntheticInstallation(root);
    File(p.join(root.path, installationMarker)).writeAsStringSync('synthetic');
    i.checkSynthetic();
    i.source.createSync(recursive: true);
    FilePreferencesStore.write(i.preferencesFile, {
      'flutter.unit': 'kg',
      'flutter.identity.current_user_id': syntheticUser,
      'flutter.identity.onboarding_complete': true,
      'flutter.absorb.template_ids': [templateExercise],
      'flutter.settings.sync_enabled': false,
      'flutter.settings.rest_compound_seconds': 180,
    });
    final database = PowerSyncDatabase(schema: schema, path: i.databasePath);
    await database.initialize();
    await _seed(database, blockedQueue: blockedQueue);
    await database.close();
    if (draft != SyntheticDraft.none) {
      i.draftFile.writeAsBytesSync(malformedDraftBytes, flush: true);
    }
    return i;
  }

  /// A copy of this installation in the new directory [root].
  Future<SyntheticInstallation> copyTo(Directory root) async {
    checkSynthetic();
    await root.delete();
    await copyTree(this.root, root);
    return SyntheticInstallation(root)..checkSynthetic();
  }

  /// Makes this process's preferences this installation's file.
  void usePreferences() {
    SharedPreferencesStorePlatform.instance = FilePreferencesStore.open(
      preferencesFile,
    );
    SharedPreferences.resetStatic();
  }

  /// The source as it is stored, read from a private copy of the database
  /// and its WAL (the source itself is never opened): raw rows of the seven
  /// tables, the queue and its sequence, the digest of every non-database
  /// file beside the stores, and the preference file.
  Future<Map<String, Object?>> sourceState() async {
    final scratch = await Directory.systemTemp.createTemp('reps-source-state');
    try {
      final copy = p.join(scratch.path, 'copy.db');
      File(databasePath).copySync(copy);
      final wal = File('$databasePath-wal');
      if (wal.existsSync()) wal.copySync('$copy-wal');
      final conn = sqlite.sqlite3.open(copy);
      try {
        List<List<Object?>> rows(String sql) => [
          for (final r in conn.select(sql)) r.values.toList(),
        ];
        return {
          'tables': {
            for (final t in captureTables)
              t: rows('SELECT id, data FROM "ps_data__$t" ORDER BY id'),
          },
          'queue': rows('SELECT id, tx_id, data FROM ps_crud ORDER BY id'),
          'sequence': rows(
            "SELECT seq FROM sqlite_sequence WHERE name = 'ps_crud'",
          ),
          'files': {
            for (final e in source.listSync(followLinks: false))
              if (e is! Directory &&
                  !p.basename(e.path).startsWith('workout-tracker.db'))
                p.basename(e.path): switch (e) {
                  File f => _digestOrUnreadable(f),
                  _ => 'link:${(e as Link).targetSync()}',
                },
          },
          'preferences': preferencesFile.existsSync()
              ? sha256Of(preferencesFile.readAsBytesSync())
              : null,
        };
      } finally {
        conn.close();
      }
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  /// The queue as the producer must carry it: ids, transaction ids and the
  /// SHA-256 of each exact `data` text, in queue order.
  Future<List<Map<String, Object?>>> queueDigests() async {
    final state = await sourceState();
    return [
      for (final r in (state['queue']! as List).cast<List<Object?>>())
        {
          'client_id': r[0],
          'tx_id': r[1],
          'data_sha256': sha256Of(utf8.encode(r[2]! as String)),
        },
    ];
  }

  /// Every final capture directory (`captures/<id>`).
  List<Directory> finalDirectories() => [
    if (locations.captures.existsSync())
      for (final e in locations.captures.listSync(followLinks: false))
        Directory(e.path),
  ];
}

Future<void> _seed(PowerSyncDatabase db, {required bool blockedQueue}) async {
  // A server-seeded template, as sync stores it (not queued), carrying a
  // column this app version does not know.
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO "ps_data__exercises" (id, data) VALUES (?, ?)',
      [
        templateExercise,
        jsonEncode({
          'name': 'Bench Press',
          'slug': 'bench-press',
          'muscle_group': 'chest',
          'is_template': 1,
          'created_by': null,
          'created_at': '2026-01-01T00:00:00Z',
          'equip': 'barbell',
          'compound': 1,
          'base_weight_kg': '20.00',
          'plate_step_kg': '2.50',
          'legacy_note': 'synthetic unknown column',
        }),
      ],
    );
  });
  // Local writes through the views: each one is queued for upload.
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO exercises (id, name, slug, muscle_group, is_template, '
      'created_by, created_at, equip, compound, base_weight_kg, '
      'plate_step_kg) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        ownedExercise,
        'Cable Fly',
        'cable-fly-a1000000',
        'chest',
        0,
        syntheticUser,
        '2026-10-01T08:00:00.000Z',
        '',
        0,
        '',
        '2.50',
      ],
    );
    await tx.execute(
      'INSERT INTO day_templates (id, slug, name, notes, position, '
      'is_template, created_by, created_at, focus) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'b1000000-0000-4000-8000-000000000001',
        'upper-a-b1000000',
        'Upper A',
        null,
        1,
        0,
        syntheticUser,
        '2026-10-01T08:00:00.000Z',
        'Chest',
      ],
    );
    await tx.execute(
      'INSERT INTO day_template_items (id, day_template_id, exercise_id, '
      'position, target_warmup_sets, target_working_sets, target_rep_low, '
      'target_rep_high, target_rir_low, target_rir_high, is_template, '
      'created_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'c1000000-0000-4000-8000-000000000001',
        'b1000000-0000-4000-8000-000000000001',
        ownedExercise,
        1,
        1,
        3,
        8,
        12,
        1,
        2,
        0,
        syntheticUser,
        '2026-10-01T08:00:00.000Z',
      ],
    );
  });
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO sessions (id, user_id, date, split_label, created_at, '
      'duration_min) VALUES (?, ?, ?, ?, ?, ?)',
      [
        syntheticSession,
        syntheticUser,
        '2026-10-01',
        'Custom',
        '2026-10-01T10:00:00.000Z',
        45,
      ],
    );
    for (final (id, n) in [
      ('e1000000-0000-4000-8000-000000000001', 1),
      ('e1000000-0000-4000-8000-000000000002', 2),
    ]) {
      await tx.execute(
        'INSERT INTO sets (id, session_id, exercise_id, user_id, set_number, '
        'weight_kg, reps, rir, is_warmup, is_top_set, is_pr, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          syntheticSession,
          templateExercise,
          syntheticUser,
          n,
          '62.5',
          8,
          1,
          0,
          n == 2 ? 1 : 0,
          0,
          '2026-10-01T10:20:00.000Z',
        ],
      );
    }
  });
  await db.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO bodyweight_logs (id, user_id, date, weight_kg, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        'f1000000-0000-4000-8000-000000000001',
        syntheticUser,
        '2026-10-01',
        '72.3',
        '2026-10-01T07:00:00.000Z',
      ],
    );
    await tx.execute(
      'INSERT INTO muscle_targets (id, user_id, muscle, target_sets, '
      'created_at) VALUES (?, ?, ?, ?, ?)',
      [
        'f2000000-0000-4000-8000-000000000001',
        syntheticUser,
        'chest',
        12,
        '2026-10-01T07:00:00.000Z',
      ],
    );
    await tx.execute(
      "UPDATE sets SET rir = NULL WHERE id = 'e1000000-0000-4000-8000-000000000002'",
    );
    await tx.execute(
      "DELETE FROM sets WHERE id = 'e1000000-0000-4000-8000-000000000001'",
    );
  });
  if (blockedQueue) {
    // An operation the Go reader cannot attribute: its row id is no UUID.
    await db.execute(
      'INSERT INTO ps_crud (data, tx_id) VALUES (?, '
      '(SELECT MAX(tx_id) + 1 FROM ps_crud))',
      [
        jsonEncode({
          'op': 'PUT',
          'type': 'muscle_targets',
          'id': 'not-a-uuid',
          'data': {'muscle': 'back', 'target_sets': 10},
        }),
      ],
    );
  }
}

/// The draft of the running workout a [SyntheticDraft.live] source has.
SessionDraft syntheticDraft() {
  const exercise = Exercise(
    id: ownedExercise,
    name: 'Cable Fly',
    slug: 'cable-fly-a1000000',
    muscleGroup: 'chest',
    compound: false,
    plateStepKg: 2.5,
    isTemplate: false,
  );
  return SessionDraft(
    templateId: 'b1000000-0000-4000-8000-000000000001',
    name: 'Upper A',
    focus: 'Chest',
    startedAt: DateTime(2026, 10, 10, 9, 30),
    blocks: [
      BlockState(
        exercise: exercise,
        resolved: const ResolvedSlot(
          exercise: exercise,
          workSets: 3,
          warmupSets: 1,
          repLow: 8,
          repHigh: 12,
          rirLow: 1,
          rirHigh: 2,
        ),
        warmupSets: [],
        workingSets: [
          SetState(
            id: 'e2000000-0000-4000-8000-000000000001',
            weightKg: 27.5,
            reps: 10,
            rir: 2,
            isWarmup: false,
            done: true,
          ),
        ],
        expanded: true,
      ),
    ],
  );
}

/// The in-memory side of one app process over an installation: the real
/// native gate, session manager, capture hooks and (for a live draft) the
/// running workout. The database must already be open.
class InstallationProcess {
  InstallationProcess(
    this.installation,
    this.database, {
    required bool liveDraft,
  }) {
    installation.checkSynthetic();
    final source = installation.source;
    gate = SourceWriteGate(stateDirectory: installation.locations.gate);
    appSourceGate = gate;
    manager = SessionManager(
      finishedStore: FinishedSessionStore(directory: () async => source),
    );
    hooks = SessionCaptureHooks(
      manager: manager,
      preservation: RawPreservation(
        installation.locations.preparation,
        base: source,
      ),
    );
    if (liveDraft) {
      final c = ActiveSessionController.fromDraft(
        syntheticDraft(),
        draftStore: DraftStore(directory: () async => source),
      );
      manager.register(c);
      controller = c;
    }
  }

  final SyntheticInstallation installation;
  final PowerSyncDatabase database;
  late final SourceWriteGate gate;
  late final SessionManager manager;
  late final SessionCaptureHooks hooks;
  ActiveSessionController? controller;

  /// Prepares the private gate directory (the app does this at startup).
  Future<void> prepareGate([CaptureFiles files = const CaptureFiles()]) => files
      .ensureDirectory(installation.locations.gate, base: installation.source);

  CaptureCoordinator coordinator({
    CaptureFaults faults = const CaptureFaults(),
    CaptureFiles files = const CaptureFiles(),
    CaptureTransport Function(QualifiedProfile profile)? transportFor,
    String Function()? newCaptureId,
    DateTime Function()? clock,
  }) => CaptureCoordinator(
    locations: installation.locations,
    gate: gate,
    files: files,
    faults: faults,
    newCaptureId: newCaptureId,
    clock: clock,
    sources: CaptureSourceBindings(
      database: database,
      hooks: hooks,
      transportFor:
          transportFor ??
          (profile) => CaptureTransport.forProfile(
            database: database,
            profile: profile,
            reconnect: () async {},
          ),
    ),
  );

  void dispose() {
    controller?.dispose();
    manager.dispose();
  }
}

/// A coordinator with no sources (startup and recovery only), over the real
/// native gate and files.
CaptureCoordinator recoveryCoordinator(SyntheticInstallation installation) =>
    CaptureCoordinator(
      locations: installation.locations,
      gate: SourceWriteGate(stateDirectory: installation.locations.gate),
    );

/// Ordinary boot steps that only record that they ran.
class RecordingStartupSteps implements OrdinaryStartupSteps {
  final ran = <String>[];
  @override
  Future<void> loadSettings() async => ran.add('settings');
  @override
  Future<void> openDatabase() async => ran.add('database');
  @override
  Future<void> initIdentity() async => ran.add('identity');
  @override
  Future<void> runBootMigrations() async => ran.add('migrations');
  @override
  Future<void> prepareSessions() async => ran.add('sessions');
  @override
  Future<void> connect() async => ran.add('connect');
}

/// Capture-first startup over [installation] with coordinator recovery, as
/// `main` runs it, recording which ordinary steps ran.
Future<(StartupOutcome, List<String>)> syntheticStartup(
  SyntheticInstallation installation,
) async {
  final source = installation.source;
  final locations = installation.locations;
  final gate = SourceWriteGate(stateDirectory: locations.gate);
  final steps = RecordingStartupSteps();
  final outcome = await runCaptureAwareStartup(
    journal: CaptureJournal(locations.journal, base: source),
    probeGate: () => probeSourceGate(gate, base: source),
    source: source,
    preservation: RawPreservation(locations.preparation, base: source),
    files: const [],
    steps: steps,
    now: DateTime(2026, 10, 10, 12),
    recover: recoveryCoordinator(installation).recoverForStartup,
  );
  return (outcome, steps.ran);
}
