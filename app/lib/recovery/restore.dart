import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

import '../domain/evidence.dart';
import '../identity/alkion_profile.dart';
import '../identity/directory_durability.dart';
import '../store/generation_selection.dart';
import '../store/local_store.dart';
import '../store/schema.dart';
import 'backup.dart';

const restoreIntentFormat = 'alkion-restore-intent/1';
const restoreJournalFormat = 'alkion-restore-journal/1';
const reconciliationFormat = 'alkion-restore-reconciliation/1';

/// Review categories written into a restored generation. Every row of the
/// previous generation that the backup lacks or holds differently gets one
/// [newerWorkCategory] review with its exact bytes; nothing is merged,
/// replayed or discarded silently.
const newerWorkCategory = 'restore_newer_work';
const reconciliationCategory = 'restore_reconciliation';

/// Disposition of the single review recorded when the previous generation
/// could not be read: its newer work is an explicit unknown loss boundary.
const unknownNewerWork = 'unknown_previous_unreadable';

/// Never compared as newer work: metadata replaced by the selection itself.
const _selectionMetadata = {'profile_state', 'schema_migrations'};

enum RestoreMode { replace, fresh }

final class RestoreOutcome {
  const RestoreOutcome(this.intent);
  final Map<String, Object?> intent;
  String get restoreId => intent['restore_id'] as String;
  RestoreMode get mode => RestoreMode.values.byName(intent['mode'] as String);
  String get profileId => intent['profile_id'] as String;
  int get selectedGeneration => (intent['staged'] as Map)['generation'] as int;
  String get previousState => (intent['previous'] as Map)['state'] as String;
  Map<String, Object?> get reconciliation =>
      Map<String, Object?>.from(intent['reconciliation'] as Map);
}

/// One interrupted restore: durable intent, neither selected nor abandoned.
final class PendingRestore {
  const PendingRestore(this.restoreId, this.intent);
  final String restoreId;
  final Map<String, Object?> intent;
}

/// The previous generation as observed before staging.
final class _Previous {
  _Previous.readable(this.path, this.generation, this.state)
    : category = null,
      evidence = null;
  _Previous.unreadable(this.category, this.evidence)
    : path = null,
      generation = null,
      state = null;
  _Previous.absent()
    : path = null,
      generation = null,
      state = null,
      category = null,
      evidence = null;
  final String? path;
  final int? generation;
  final CoveredState? state;
  final String? category;
  final List<Map<String, Object?>>? evidence;

  Map<String, Object?> describe() => state != null
      ? {
          'state': 'readable',
          'path': path,
          'generation': generation,
          'covered_sha256': state!.digest(excluding: const {'profile_state'}),
          'rows': state!.rowCount,
        }
      : category != null
      ? {'state': 'unreadable', 'category': category, 'files': evidence}
      : {'state': 'absent'};
}

/// Manual restore onto Alkion staging, followed by one atomic generation
/// selection. Mutation stays closed for the whole procedure: the previous
/// store is read through the qualified opener, closed, then fenced and
/// deselected under the profile owner lock. No credential import, transport
/// or automatic replay exists.
final class RestoreService {
  RestoreService(
    this.supportRoot, {
    SchemaRegistry? schema,
    this.checkpoint,
    this.workDirectory,
  }) : schema = schema ?? workflowSchemaRegistry();
  final Directory supportRoot;
  final SchemaRegistry schema;
  final RecoveryCheckpoint? checkpoint;
  final Directory? workDirectory;

  /// Verifies [backup] on the receiving side, then restores it. The same
  /// profile is replaced with preservation and reconciliation; an empty
  /// support root receives the profile as separate storage; any other
  /// profile is refused before a byte changes.
  Future<RestoreOutcome> restore(File backup) async {
    final verified = await verifyBackupFile(
      backup,
      schema: schema,
      workDirectory: workDirectory,
    );
    final existing = await AlkionProfile.existing(supportRoot: supportRoot);
    if (existing == null) {
      return _restoreFresh(verified);
    }
    if (existing.profileId != verified.profileId) {
      throw const StoreException('foreign_profile');
    }
    return _restoreReplace(existing, verified);
  }

  Future<RestoreOutcome> _restoreReplace(
    AlkionProfile profile,
    VerifiedBackup verified,
  ) async {
    final profileDirectory = await profile.profileDirectory(
      expectedProfileId: profile.profileId,
    );
    late final _Previous previous;
    LocalStore? store;
    try {
      store = await LocalStore.open(
        profile: profile,
        expectedProfileId: profile.profileId,
        schema: schema,
      );
    } on StoreException catch (error) {
      if (error.category == 'profile_in_use') {
        rethrow;
      }
      previous = _Previous.unreadable(
        error.category,
        await _fileEvidence(profileDirectory),
      );
    } on GenerationSelectionException catch (error) {
      if (error.category == 'restore_interrupted') {
        rethrow;
      }
      previous = _Previous.unreadable(
        error.category,
        await _fileEvidence(profileDirectory),
      );
    }
    if (store != null) {
      try {
        // One read transaction: the reconciliation boundary, WAL included.
        final state = await store.readTransaction(
          (tx) => readCoveredState((sql) => tx.getAll(sql)),
        );
        previous = _Previous.readable(
          p.relative(store.path, from: profileDirectory),
          store.token.generation,
          state,
        );
      } finally {
        await store.close();
      }
    }
    final restoreId = _newRestoreId();
    final intent = await _stage(
      profileDirectory,
      restoreId,
      RestoreMode.replace,
      profile.installationId,
      verified,
      previous,
    );
    return _select(profileDirectory, intent);
  }

  Future<RestoreOutcome> _restoreFresh(VerifiedBackup verified) async {
    final root = p.normalize(p.absolute(supportRoot.path));
    final profileDirectory = p.join(root, 'profiles', verified.profileId);
    final resumable = _freshResumable(root, profileDirectory, verified);
    if (resumable != null) {
      final intent = _readIntent(profileDirectory, resumable);
      final selected = File(
        p.join(
          generationDirectory(profileDirectory, resumable),
          restoreSelectedName,
        ),
      ).existsSync();
      final outcome = selected
          ? RestoreOutcome(intent)
          : await _select(profileDirectory, intent);
      await AlkionProfile.adoptRestored(
        supportRoot: Directory(root),
        profileId: verified.profileId,
        installationId: intent['installation_id'] as String,
      );
      return outcome;
    }
    await Directory(profileDirectory).create(recursive: true);
    rejectLinkedPath(profileDirectory);
    final installationId = const Uuid().v4();
    final intent = await _stage(
      profileDirectory,
      _newRestoreId(),
      RestoreMode.fresh,
      installationId,
      verified,
      _Previous.absent(),
    );
    final outcome = await _select(profileDirectory, intent);
    await checkpoint?.call('restore-before-identity');
    await AlkionProfile.adoptRestored(
      supportRoot: Directory(root),
      profileId: verified.profileId,
      installationId: installationId,
    );
    return outcome;
  }

  /// Separate storage must be empty, or hold only an interrupted fresh restore
  /// of this same verified backup, which is then completed.
  String? _freshResumable(
    String root,
    String profileDirectory,
    VerifiedBackup verified,
  ) {
    if (FileSystemEntity.typeSync(root, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    for (final entry in Directory(root).listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      if (name == '.identity.lock') {
        continue;
      }
      final profiles = name == 'profiles'
          ? Directory(entry.path).listSync(followLinks: false)
          : null;
      if (profiles == null ||
          profiles.length != 1 ||
          p.basename(profiles.single.path) != verified.profileId) {
        throw const StoreException('restore_target_not_empty');
      }
    }
    final generations = Directory(
      p.join(profileDirectory, generationsDirectoryName),
    );
    if (generations.existsSync()) {
      for (final entry in generations.listSync(followLinks: false)) {
        final id = p.basename(entry.path);
        final directory = entry.path;
        if (!restoreIdPattern.hasMatch(id) ||
            !File(p.join(directory, restoreIntentName)).existsSync() ||
            File(p.join(directory, restoreAbandonedName)).existsSync()) {
          continue;
        }
        final intent = _readIntent(profileDirectory, id);
        if (intent['mode'] == RestoreMode.fresh.name &&
            (intent['backup'] as Map)['manifest_sha256'] ==
                verified.manifestSha256) {
          return id;
        }
      }
    }
    if (Directory(profileDirectory).existsSync()) {
      throw const StoreException('restore_target_not_empty');
    }
    return null;
  }

  /// Writes the verified snapshot into a new generation directory and turns it
  /// into the next generation in one SQLite transaction: target installation,
  /// new generation, local state adopted into it, carried restore lineage and
  /// one review per newer row of the previous generation.
  Future<Map<String, Object?>> _stage(
    String profileDirectory,
    String restoreId,
    RestoreMode mode,
    String installationId,
    VerifiedBackup verified,
    _Previous previous,
  ) async {
    final generations = Directory(
      p.join(profileDirectory, generationsDirectoryName),
    );
    await generations.create();
    rejectLinkedPath(generations.path);
    final directory = Directory(
      generationDirectory(profileDirectory, restoreId),
    );
    if (directory.existsSync()) {
      throw const StoreException('restore_id_collision');
    }
    await directory.create();
    final database = p.join(directory.path, generationDatabaseName);
    final partial = File('$database.partial');
    await partial.writeAsBytes(verified.databaseBytes, flush: true);
    await partial.rename(database);
    flushDirectory(directory.path);
    flushDirectory(generations.path);
    flushDirectory(profileDirectory);
    await checkpoint?.call('restore-staged-bytes');
    final previousGeneration = previous.generation;
    final generation =
        max(
          previousGeneration == null ? 0 : previousGeneration + 1,
          verified.generation,
        ) +
        1;
    final now = OperationInstant.now().text;
    final db = sqlite.sqlite3.open(database);
    late final Map<String, Object?> reconciliation;
    late final String stagedInventory;
    try {
      db.execute('PRAGMA foreign_keys = ON');
      db.execute('PRAGMA synchronous = FULL');
      final backup = await readCoveredState(rawSelect(db));
      if (backup.digest() != verified.facts.state.digest()) {
        throw const StoreException('restore_staging_mismatch');
      }
      final plan = _reconcile(previous.state, backup, restoreId, now);
      if (previous.category != null) {
        // Newer work of an unreadable previous generation is unknown, not
        // absent: an undecided review keeps it visible and gates transport.
        plan.counts[unknownNewerWork] = 1;
        plan.reviews.add({
          'profile_id': verified.profileId,
          'review_id': _reviewId(restoreId, unknownNewerWork, ''),
          'family': null,
          'operation_id': null,
          'category': newerWorkCategory,
          'evidence_bytes': {
            'blob_base64': base64.encode(
              localBytes({
                'format': reconciliationFormat,
                'restore_id': restoreId,
                'table': null,
                'key': const <Object?>[],
                'disposition': unknownNewerWork,
                'previous_row': null,
                'backup_row': null,
                'previous': previous.describe(),
              }),
            ),
          },
          'created_at': now,
        });
      }
      reconciliation = {
        'newer_work': previous.state == null
            ? (previous.category == null
                  ? 'none_no_previous_generation'
                  : unknownNewerWork)
            : plan.reviews.isEmpty
            ? 'none'
            : 'retained_for_review',
        'counts': plan.counts,
        'carried_restore_lineage': {
          for (final entry in plan.carry.entries) entry.key: entry.value.length,
        },
      };
      final adoptedFrom = {
        for (final row in backup.tables['local_state']!) row['generation'],
      }.toList()..sort((a, b) => (a as int).compareTo(b as int));
      db.execute('BEGIN IMMEDIATE');
      try {
        db.execute(
          "UPDATE profile_state SET installation_id=?, generation=?, write_state='writable' WHERE singleton=1",
          [installationId, generation],
        );
        db.execute('UPDATE local_state SET generation=?', [generation]);
        for (final entry in plan.carry.entries) {
          for (final row in entry.value) {
            _insert(db, entry.key, row);
          }
        }
        for (final row in plan.reviews) {
          _insert(db, 'reviews', row);
        }
        _insert(db, 'reviews', {
          'profile_id': verified.profileId,
          'review_id': _reviewId(restoreId, 'summary', ''),
          'family': null,
          'operation_id': null,
          'category': reconciliationCategory,
          'evidence_bytes': {
            'blob_base64': base64.encode(
              localBytes({
                'format': reconciliationFormat,
                'restore_id': restoreId,
                'previous': previous.describe(),
                ...reconciliation,
              }),
            ),
          },
          'created_at': now,
        });
        _insert(db, 'restore_journal', {
          'profile_id': verified.profileId,
          'restore_id': restoreId,
          'entry_id': 'selection',
          'from_generation': previousGeneration ?? 0,
          'to_generation': generation,
          'entry_bytes': {
            'blob_base64': base64.encode(
              localBytes({
                'format': restoreJournalFormat,
                'restore_id': restoreId,
                'mode': mode.name,
                'backup': _backupEvidence(verified),
                'previous': previous.describe(),
                'adopted': {
                  'installation_id_from': verified.installationId,
                  'installation_id_to': installationId,
                  'backup_generation': verified.generation,
                  'local_state_generations_from': adoptedFrom,
                  'generation_to': generation,
                },
                'reconciliation': reconciliation,
                'credentials': 'none_imported',
                'transport': 'none_started',
              }),
            ),
          },
          'created_at': now,
        });
        db.execute('COMMIT');
      } catch (_) {
        if (!db.autocommit) {
          db.execute('ROLLBACK');
        }
        rethrow;
      }
      if (db.select('PRAGMA integrity_check').single.values.single != 'ok' ||
          db.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const StoreException('restore_staging_corrupt');
      }
      stagedInventory = (await readCoveredState(rawSelect(db))).digest();
    } finally {
      db.close();
    }
    flushDirectory(directory.path);
    await checkpoint?.call('restore-staged');
    return {
      'format': restoreIntentFormat,
      'restore_id': restoreId,
      'mode': mode.name,
      'profile_id': verified.profileId,
      'installation_id': installationId,
      'created_at': now,
      'backup': _backupEvidence(verified),
      'staged': {
        'database': p.relative(database, from: profileDirectory),
        'sha256': await _fileDigest(database),
        'inventory_sha256': stagedInventory,
        'generation': generation,
      },
      'previous': previous.describe(),
      'reconciliation': reconciliation,
    };
  }

  /// Takes the profile owner lock, records the durable intent, then fences
  /// the previous generation and switches the selection.
  Future<RestoreOutcome> _select(
    String profileDirectory,
    Map<String, Object?> intent,
  ) async {
    final restoreId = intent['restore_id'] as String;
    final owner = _acquire(profileDirectory);
    try {
      final file = File(
        p.join(
          generationDirectory(profileDirectory, restoreId),
          restoreIntentName,
        ),
      );
      if (!file.existsSync()) {
        await _writeDurable(file, localBytes(intent));
        await checkpoint?.call('restore-intent');
      }
      await _finish(profileDirectory, intent);
      return RestoreOutcome(intent);
    } finally {
      owner.close();
    }
  }

  /// Requires the owner lock. Idempotent across interruption.
  Future<void> _finish(
    String profileDirectory,
    Map<String, Object?> intent,
  ) async {
    final restoreId = intent['restore_id'] as String;
    final directory = generationDirectory(profileDirectory, restoreId);
    final staged = intent['staged'] as Map;
    if (await _fileDigest(p.join(profileDirectory, staged['database'])) !=
        staged['sha256']) {
      throw const StoreException('restore_staging_changed');
    }
    final previous = intent['previous'] as Map;
    if (previous['state'] == 'readable') {
      try {
        await _fence(
          p.join(profileDirectory, previous['path'] as String),
          previous['covered_sha256'] as String,
          previous['generation'] as int,
        );
      } on StoreException catch (error) {
        if (error.category == 'restore_source_changed') {
          await _writeDurable(
            File(p.join(directory, restoreAbandonedName)),
            localBytes({
              'restore_id': restoreId,
              'reason': 'restore_source_changed',
              'at': OperationInstant.now().text,
            }),
          );
        }
        rethrow;
      }
      await checkpoint?.call('restore-fenced');
    }
    // A prior selection interrupted before its marker stays completed, not
    // pending, once this selection replaces it.
    final prior = selectedRestoreId(profileDirectory);
    final priorMarker = prior == null
        ? null
        : File(
            p.join(
              generationDirectory(profileDirectory, prior),
              restoreSelectedName,
            ),
          );
    if (prior != restoreId &&
        priorMarker != null &&
        !priorMarker.existsSync()) {
      await _writeDurable(
        priorMarker,
        localBytes({
          'restore_id': prior,
          'selected_at': 'before:${OperationInstant.now().text}',
        }),
      );
    }
    await _writeDurable(
      File(p.join(profileDirectory, selectionFileName)),
      localBytes({
        'format': selectionFormat,
        'version': 1,
        'restore_id': restoreId,
      }),
    );
    await checkpoint?.call('restore-selected');
    await _writeDurable(
      File(p.join(directory, restoreSelectedName)),
      localBytes({
        'restore_id': restoreId,
        'selected_at': OperationInstant.now().text,
      }),
    );
  }

  /// Interrupted restores of the existing profile, oldest ID first.
  Future<List<PendingRestore>> pending() async {
    final profile = await AlkionProfile.existing(supportRoot: supportRoot);
    if (profile == null) {
      return const [];
    }
    final directory = await profile.profileDirectory(
      expectedProfileId: profile.profileId,
    );
    return [
      for (final id in pendingRestoreIds(directory))
        PendingRestore(id, _readIntent(directory, id)),
    ];
  }

  /// Explicitly completes an interrupted restore from its verified staging.
  Future<RestoreOutcome> complete(String restoreId) async {
    final (directory, intent) = await _pendingIntent(restoreId);
    final owner = _acquire(directory);
    try {
      await _finish(directory, intent);
    } finally {
      owner.close();
    }
    return RestoreOutcome(intent);
  }

  /// Explicitly keeps the current generation: removes this restore's own fence
  /// (generation stays advanced, so earlier tokens remain stale), journals the
  /// decision there and marks the restore abandoned. Staging is retained.
  Future<void> abandon(String restoreId) async {
    final (directory, _) = await _pendingIntent(restoreId);
    final owner = _acquire(directory);
    try {
      // Re-read identity, intent and pending selection while holding ownership.
      final (lockedDirectory, intent) = await _pendingIntent(restoreId);
      if (lockedDirectory != directory) {
        throw const StoreException('foreign_profile');
      }
      if (pendingRestoreIds(directory).any((id) => id != restoreId)) {
        throw const StoreException('restore_source_changed');
      }
      final staged = intent['staged'] as Map;
      final stagedPath = p.relative(
        generationDatabasePath(directory, restoreId),
        from: directory,
      );
      if (staged['database'] != stagedPath) {
        throw const StoreException('restore_staging_changed');
      }
      final stagedFile = p.join(directory, stagedPath);
      rejectLinkedPath(stagedFile);
      if (FileSystemEntity.typeSync(stagedFile, followLinks: false) !=
              FileSystemEntityType.file ||
          await _fileDigest(stagedFile) != staged['sha256']) {
        throw const StoreException('restore_staging_changed');
      }
      final previous = intent['previous'] as Map;
      final stagedDb = sqlite.sqlite3.open(
        stagedFile,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        final stagedState = await readCoveredState(rawSelect(stagedDb));
        final metadata = stagedState.tables['profile_state']!.single;
        if (metadata['profile_id'] != intent['profile_id'] ||
            metadata['installation_id'] != intent['installation_id'] ||
            metadata['generation'] != staged['generation'] ||
            stagedState.digest() != staged['inventory_sha256']) {
          throw const StoreException('restore_staging_changed');
        }
        // Staging already carries the immutable source boundary from the
        // original selection transaction. The pending intent must still agree.
        final selection = stagedState.tables['restore_journal']!
            .where(
              (entry) =>
                  entry['restore_id'] == restoreId &&
                  entry['entry_id'] == 'selection',
            )
            .singleOrNull;
        if (selection == null) {
          throw const StoreException('restore_staging_changed');
        }
        final evidence =
            jsonDecode(
                  utf8.decode(
                    base64.decode(
                      (selection['entry_bytes'] as Map)['blob_base64']
                          as String,
                    ),
                  ),
                )
                as Map;
        if (selection['from_generation'] != (previous['generation'] ?? 0) ||
            selection['to_generation'] != staged['generation'] ||
            evidence['restore_id'] != restoreId ||
            evidence['mode'] != intent['mode'] ||
            !_same(
              Map<String, Object?>.from(evidence['previous'] as Map),
              Map<String, Object?>.from(previous),
            )) {
          throw const StoreException('restore_source_changed');
        }
      } finally {
        stagedDb.close();
      }
      if (previous['state'] == 'readable') {
        final selected = selectedRestoreId(directory);
        final selectedPath = selected == null
            ? generationDatabaseName
            : p.relative(
                generationDatabasePath(directory, selected),
                from: directory,
              );
        if (previous['path'] != selectedPath ||
            previous['generation'] is! int ||
            (previous['generation'] as int) < 1) {
          throw const StoreException('restore_source_changed');
        }
        final path = p.join(directory, selectedPath);
        rejectLinkedPath(path);
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const StoreException('restore_source_changed');
        }
        final db = sqlite.sqlite3.open(path);
        try {
          db.execute('PRAGMA foreign_keys = ON');
          db.execute('PRAGMA synchronous = FULL');
          db.execute('BEGIN IMMEDIATE');
          try {
            final state = await readCoveredState(rawSelect(db));
            final row = state.tables['profile_state']!.single;
            if (row['profile_id'] != intent['profile_id'] ||
                row['installation_id'] != intent['installation_id']) {
              throw const StoreException('foreign_profile');
            }
            final generation = previous['generation'] as int;
            final decision = {
              'blob_base64': base64.encode(
                localBytes({
                  'format': restoreJournalFormat,
                  'restore_id': restoreId,
                  'decision': 'explicit_keep_current_generation',
                  'staging_retained': stagedPath,
                }),
              ),
            };
            final decisions = state.tables['restore_journal']!
                .where((entry) => entry['restore_id'] == restoreId)
                .toList();
            if (decisions.isNotEmpty) {
              // Only our exact committed decision can bridge the marker gap.
              // Remove just that row to re-check every pre-decision work byte.
              final entry = decisions.singleOrNull;
              if (entry == null ||
                  entry['profile_id'] != intent['profile_id'] ||
                  entry['entry_id'] != 'abandoned' ||
                  entry['from_generation'] != row['generation'] ||
                  entry['to_generation'] != row['generation'] ||
                  !_same(
                    entry['entry_bytes'] as Map<String, Object?>,
                    decision,
                  ) ||
                  row['write_state'] != 'writable' ||
                  (row['generation'] != generation &&
                      row['generation'] != generation + 1)) {
                throw const StoreException('restore_source_changed');
              }
              final beforeDecision = CoveredState({
                ...state.tables,
                'restore_journal': [
                  for (final candidate in state.tables['restore_journal']!)
                    if (!identical(candidate, entry)) candidate,
                ],
              }, state.keys);
              if (beforeDecision.digest(excluding: const {'profile_state'}) !=
                  previous['covered_sha256']) {
                throw const StoreException('restore_source_changed');
              }
            } else {
              if (state.digest(excluding: const {'profile_state'}) !=
                  previous['covered_sha256']) {
                throw const StoreException('restore_source_changed');
              }
              if (row['write_state'] == 'fenced' &&
                  row['generation'] == generation + 1) {
                db.execute(
                  "UPDATE profile_state SET write_state='writable' WHERE singleton=1",
                );
              } else if (row['write_state'] != 'writable' ||
                  row['generation'] != generation) {
                throw const StoreException('restore_source_changed');
              }
              _insert(db, 'restore_journal', {
                'profile_id': intent['profile_id'],
                'restore_id': restoreId,
                'entry_id': 'abandoned',
                'from_generation': row['generation'],
                'to_generation': row['generation'],
                'entry_bytes': decision,
                'created_at': OperationInstant.now().text,
              });
            }
            db.execute('COMMIT');
            await checkpoint?.call('restore-abandon-committed');
          } catch (_) {
            if (!db.autocommit) {
              db.execute('ROLLBACK');
            }
            rethrow;
          }
        } finally {
          db.close();
        }
      }
      await _writeDurable(
        File(
          p.join(
            generationDirectory(directory, restoreId),
            restoreAbandonedName,
          ),
        ),
        localBytes({
          'restore_id': restoreId,
          'reason': 'explicit_keep_current_generation',
          'at': OperationInstant.now().text,
        }),
      );
    } finally {
      owner.close();
    }
  }

  Future<(String, Map<String, Object?>)> _pendingIntent(
    String restoreId,
  ) async {
    final profile = await AlkionProfile.existing(supportRoot: supportRoot);
    if (profile == null || !restoreIdPattern.hasMatch(restoreId)) {
      throw const StoreException('restore_not_pending');
    }
    final directory = await profile.profileDirectory(
      expectedProfileId: profile.profileId,
    );
    if (!pendingRestoreIds(directory).contains(restoreId)) {
      throw const StoreException('restore_not_pending');
    }
    final intent = _readIntent(directory, restoreId);
    if (intent['profile_id'] != profile.profileId ||
        intent['installation_id'] != profile.installationId) {
      throw const StoreException('foreign_profile');
    }
    return (directory, intent);
  }

  ProfileOwnership _acquire(String profileDirectory) {
    final path = p.join(profileDirectory, '.store-owner.lock');
    rejectLinkedPath(path);
    try {
      return ProfileOwnership.acquire(path);
    } on FileSystemException {
      throw const StoreException('profile_in_use');
    }
  }
}

/// Fences the previous generation in place after checking that its covered
/// state is exactly the reconciliation boundary. Repeating it is a no-op.
Future<void> _fence(String path, String coveredSha256, int generation) async {
  final db = sqlite.sqlite3.open(path);
  try {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA synchronous = FULL');
    db.execute('BEGIN IMMEDIATE');
    try {
      final state = await readCoveredState(rawSelect(db));
      final row = db
          .select(
            'SELECT generation,write_state FROM profile_state WHERE singleton=1',
          )
          .single;
      final same =
          state.digest(excluding: const {'profile_state'}) == coveredSha256;
      if (same &&
          row['write_state'] == 'writable' &&
          row['generation'] == generation) {
        db.execute(
          "UPDATE profile_state SET generation=generation+1,write_state='fenced' WHERE singleton=1",
        );
      } else if (!same ||
          row['write_state'] != 'fenced' ||
          row['generation'] != generation + 1) {
        throw const StoreException('restore_source_changed');
      }
      db.execute('COMMIT');
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK');
      }
      rethrow;
    }
  } finally {
    db.close();
  }
}

final class _Plan {
  final carry = <String, List<Map<String, Object?>>>{};
  final reviews = <Map<String, Object?>>[];
  final counts = <String, int>{};
}

bool _restoreLineageReview(Map<String, Object?> review) =>
    (review['category'] as String).startsWith('restore_');

/// Classifies every covered row of the previous generation against the
/// backup. Restore lineage (journal entries, restore reviews and their
/// decisions) is carried forward verbatim; all other differences become
/// exact-byte reviews. Local-state generation stamps are not work.
_Plan _reconcile(
  CoveredState? previous,
  CoveredState backup,
  String restoreId,
  String now,
) {
  final plan = _Plan();
  if (previous == null) {
    return plan;
  }
  final profileId =
      backup.tables['profile_state']!.single['profile_id'] as String;
  final lineageReviews = {
    for (final row in previous.tables['reviews']!)
      if (_restoreLineageReview(row)) row['review_id'],
  };
  bool lineage(String table, Map<String, Object?> row) => switch (table) {
    'restore_journal' => true,
    'reviews' => _restoreLineageReview(row),
    'review_decisions' => lineageReviews.contains(row['review_id']),
    _ => false,
  };
  Map<String, Object?> comparable(String table, Map<String, Object?> row) =>
      table == 'local_state' ? ({...row}..remove('generation')) : row;
  for (final table in preservedTables) {
    if (_selectionMetadata.contains(table)) {
      continue;
    }
    final before = {
      for (final row in backup.tables[table]!) backup.rowKey(table, row): row,
    };
    final after = {
      for (final row in previous.tables[table]!)
        previous.rowKey(table, row): row,
    };
    void review(
      String key,
      String disposition,
      Map<String, Object?>? current,
      Map<String, Object?>? backed,
    ) {
      plan.counts['$table.$disposition'] =
          (plan.counts['$table.$disposition'] ?? 0) + 1;
      plan.reviews.add({
        'profile_id': profileId,
        'review_id': _reviewId(restoreId, table, key),
        'family': null,
        'operation_id': null,
        'category': newerWorkCategory,
        'evidence_bytes': {
          'blob_base64': base64.encode(
            localBytes({
              'format': reconciliationFormat,
              'restore_id': restoreId,
              'table': table,
              'key': jsonDecode(key),
              'disposition': disposition,
              'previous_row': current,
              'backup_row': backed,
            }),
          ),
        },
        'created_at': now,
      });
    }

    for (final entry in after.entries) {
      final backed = before[entry.key];
      if (backed == null && lineage(table, entry.value)) {
        (plan.carry[table] ??= []).add(entry.value);
      } else if (backed == null) {
        review(entry.key, 'newer_than_backup', entry.value, null);
      } else if (!_same(
        comparable(table, backed),
        comparable(table, entry.value),
      )) {
        review(entry.key, 'changed_since_backup', entry.value, backed);
      }
    }
    for (final entry in before.entries) {
      if (!after.containsKey(entry.key)) {
        review(entry.key, 'absent_from_previous', null, entry.value);
      }
    }
  }
  return plan;
}

bool _same(Map<String, Object?> a, Map<String, Object?> b) {
  final x = localBytes(a), y = localBytes(b);
  if (x.length != y.length) {
    return false;
  }
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) {
      return false;
    }
  }
  return true;
}

String _reviewId(String restoreId, String table, String key) =>
    'rv-${sha256.convert(utf8.encode('$restoreId|$table|$key')).toString().substring(0, 40)}';

void _insert(sqlite.Database db, String table, Map<String, Object?> row) {
  final columns = row.keys.toList();
  db.execute(
    'INSERT INTO $table(${columns.join(',')}) VALUES(${List.filled(columns.length, '?').join(',')})',
    [for (final column in columns) sqlValue(row[column])],
  );
}

Map<String, Object?> _backupEvidence(VerifiedBackup verified) => {
  'container_sha256': verified.containerSha256,
  'manifest_sha256': verified.manifestSha256,
  'created_at': verified.createdAt,
  'profile_generation': verified.generation,
  'schema_user_version': verified.facts.schema['user_version'],
  'inventory_sha256': verified.facts.state.digest(),
};

Map<String, Object?> _readIntent(String profileDirectory, String restoreId) {
  final file = File(
    p.join(generationDirectory(profileDirectory, restoreId), restoreIntentName),
  );
  try {
    final value = Map<String, Object?>.from(
      jsonDecode(file.readAsStringSync()) as Map,
    );
    if (value['format'] != restoreIntentFormat ||
        value['restore_id'] != restoreId) {
      throw const FormatException('intent');
    }
    return value;
  } on FormatException {
    throw const StoreException('restore_intent_invalid');
  } on TypeError {
    throw const StoreException('restore_intent_invalid');
  }
}

/// Exact digests of the previous selection's bytes when it cannot be read as
/// a store; they are preserved in place and reported as unknown newer work.
Future<List<Map<String, Object?>>> _fileEvidence(
  String profileDirectory,
) async {
  final names = <String>{
    selectionFileName,
    for (final suffix in ['', '-wal', '-shm', '-journal'])
      '$generationDatabaseName$suffix',
  };
  try {
    final selected = selectedRestoreId(profileDirectory);
    if (selected != null) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        names.add(
          p.relative(
            '${generationDatabasePath(profileDirectory, selected)}$suffix',
            from: profileDirectory,
          ),
        );
      }
    }
  } on GenerationSelectionException {
    // The selection bytes themselves are recorded below.
  }
  return [
    for (final name in names.toList()..sort())
      if (FileSystemEntity.typeSync(
            p.join(profileDirectory, name),
            followLinks: false,
          ) ==
          FileSystemEntityType.file)
        {
          'path': name,
          'length': File(p.join(profileDirectory, name)).lengthSync(),
          'sha256': await _fileDigest(p.join(profileDirectory, name)),
        },
  ];
}

Future<String> _fileDigest(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

String _newRestoreId() =>
    'rs-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

/// Flushed temporary bytes, atomic rename, directory fsync.
Future<void> _writeDurable(File file, Uint8List bytes) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsBytes(bytes, flush: true);
  await temporary.rename(file.path);
  flushDirectory(file.parent.path);
}
