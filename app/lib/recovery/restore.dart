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
import '../identity/alkion_identity.dart';
import '../files/private_directory.dart';
import '../identity/directory_durability.dart';
import '../store/generation_selection.dart';
import '../store/local_store.dart';
import '../store/schema.dart';
import 'backup.dart';

const restoreIntentFormat = 'alkion-restore-intent/1';
const restoreJournalFormat = 'alkion-restore-journal/1';
const reconciliationFormat = 'alkion-restore-reconciliation/1';
const freshPreparationFormat = 'alkion-fresh-restore-preparation/1';

/// Null from [RestoreService.freshState] means an identity already exists.
final class FreshRestoreState {
  const FreshRestoreState({required this.canStartLocal, this.pending});
  final bool canStartLocal;
  final PendingRestore? pending;
  bool get canComplete => pending?.intent['staged'] is Map;
}

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
    verified.requireWriterVariant();
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
    final root = (await AlkionProfile.checkedRoot(
      supportRoot: supportRoot,
    )).path;
    _checkFreshTarget(root, verified.profileId);
    if (_readPreparation(root) == null &&
        Directory(root).existsSync() &&
        Directory(root)
            .listSync(followLinks: false)
            .any((entry) => p.basename(entry.path) != '.identity.lock')) {
      throw const StoreException('restore_target_not_empty');
    }
    final owner = _acquireFresh(root);
    try {
      if (File(p.join(root, 'local-profile.json')).existsSync()) {
        throw const StoreException('restore_source_changed');
      }
      return await _restoreFreshOwned(verified);
    } finally {
      owner.close();
    }
  }

  ProfileOwnership _acquireFresh(String root) {
    _readPreparation(root);
    final directory = _preparationDirectory(root);
    if (!Directory(directory).existsSync()) {
      claimPrivateDirectory(directory);
      flushDirectory(p.dirname(directory));
    }
    final path = p.join(directory, 'preparation.lock');
    rejectLinkedPath(path);
    try {
      return ProfileOwnership.acquire(path);
    } on FileSystemException {
      throw const StoreException('profile_in_use');
    }
  }

  Future<RestoreOutcome> _restoreFreshOwned(VerifiedBackup verified) async {
    final root = (await AlkionProfile.checkedRoot(
      supportRoot: supportRoot,
    )).path;
    final profileDirectory = p.join(root, 'profiles', verified.profileId);
    final preparation = await _prepareFresh(root, verified);
    final state = (await freshState())!;
    final resumable = state.canComplete ? state.pending!.restoreId : null;
    if (resumable != null) {
      final intent = _readIntent(profileDirectory, resumable);
      final outcome = await _select(profileDirectory, intent);
      await AlkionProfile.adoptRestored(
        supportRoot: Directory(root),
        profileId: verified.profileId,
        installationId: intent['installation_id'] as String,
      );
      return outcome;
    }
    await Directory(profileDirectory).create(recursive: true);
    rejectLinkedPath(profileDirectory);
    final installationId = preparation['installation_id'] as String;
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

  String _preparationDirectory(String root) =>
      p.join(freshPreparationDirectory(root, AlkionIdentity.applicationId));

  Map<String, Object?>? _readPreparation(String root) {
    final directory = _preparationDirectory(root);
    rejectLinkedPath(directory);
    final type = FileSystemEntity.typeSync(directory, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const StoreException('fresh_restore_preparation_invalid');
    }
    for (final entry in Directory(directory).listSync(followLinks: false)) {
      if (![
        'preparation.json',
        'preparation.json.tmp',
        'preparation.lock',
      ].contains(p.basename(entry.path))) {
        throw const StoreException('fresh_restore_preparation_invalid');
      }
      rejectLinkedPath(entry.path);
      if (entry is! File) {
        throw const StoreException('fresh_restore_preparation_invalid');
      }
    }
    final published = File(p.join(directory, 'preparation.json'));
    final temporary = File('${published.path}.tmp');
    if (published.existsSync() &&
        temporary.existsSync() &&
        (temporary.lengthSync() > 16384 ||
            published.lengthSync() > 16384 ||
            temporary.readAsStringSync() != published.readAsStringSync())) {
      throw const StoreException('fresh_restore_preparation_invalid');
    }
    final file = published.existsSync() ? published : temporary;
    if (!file.existsSync()) {
      return null; // Claim interrupted before first bytes.
    }
    if (file.lengthSync() > 16384) {
      throw const StoreException('fresh_restore_preparation_invalid');
    }
    try {
      final value = Map<String, Object?>.from(
        jsonDecode(file.readAsStringSync()) as Map,
      );
      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final evidence = value['backup'] as Map;
      if (value['format'] != freshPreparationFormat ||
          value['support_root'] != root ||
          value['application_id'] != AlkionIdentity.applicationId ||
          !uuid.hasMatch(value['profile_id'] as String) ||
          !uuid.hasMatch(value['installation_id'] as String) ||
          !restoreIdPattern.hasMatch(value['request_id'] as String) ||
          evidence['application_id'] != AlkionIdentity.applicationId ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(evidence['container_sha256'] as String) ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(evidence['manifest_sha256'] as String) ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(evidence['inventory_sha256'] as String) ||
          evidence['profile_generation'] is! int ||
          (evidence['profile_generation'] as int) < 0 ||
          evidence['schema_user_version'] is! int ||
          (evidence['schema_user_version'] as int) < 1 ||
          (evidence['schema_user_version'] as int) > schema.latestVersion ||
          evidence.length != 7 ||
          value.length != 8) {
        throw const FormatException();
      }
      OperationInstant(value['created_at'] as String);
      OperationInstant(evidence['created_at'] as String);
      return value;
    } catch (_) {
      throw const StoreException('fresh_restore_preparation_invalid');
    }
  }

  void _checkFreshTarget(String root, String profileId) {
    rejectLinkedPath(root);
    final rootType = FileSystemEntity.typeSync(root, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) return;
    if (rootType != FileSystemEntityType.directory) {
      throw const StoreException('restore_target_not_empty');
    }
    for (final entry in Directory(root).listSync(followLinks: false)) {
      final name = p.basename(entry.path);
      rejectLinkedPath(entry.path);
      if (['.identity.lock', 'local-profile.json.tmp'].contains(name) &&
          entry is File) {
        continue;
      }
      if (name != 'profiles' || entry is! Directory) {
        throw const StoreException('restore_target_not_empty');
      }
      final profiles = entry.listSync(followLinks: false);
      if (profiles.length != 1 ||
          p.basename(profiles.single.path) != profileId ||
          profiles.single is! Directory) {
        throw const StoreException('restore_target_not_empty');
      }
      for (final child in (profiles.single as Directory).listSync(
        followLinks: false,
      )) {
        rejectLinkedPath(child.path);
        if (![
          'generations',
          selectionFileName,
          '.store-owner.lock',
        ].contains(p.basename(child.path))) {
          throw const StoreException('restore_target_not_empty');
        }
      }
    }
  }

  Future<Map<String, Object?>> _prepareFresh(
    String root,
    VerifiedBackup verified,
  ) async {
    _checkFreshTarget(root, verified.profileId);
    final prior = _readPreparation(root);
    if (prior != null) {
      if (prior['profile_id'] != verified.profileId ||
          !_same(
            Map<String, Object?>.from(prior['backup'] as Map),
            _backupEvidence(verified),
          )) {
        throw const StoreException('fresh_restore_backup_mismatch');
      }
      return prior;
    }
    final directory = _preparationDirectory(root);
    if (!Directory(directory).existsSync()) {
      claimPrivateDirectory(directory);
      flushDirectory(p.dirname(directory));
    }
    final preparation = <String, Object?>{
      'format': freshPreparationFormat,
      'support_root': root,
      'application_id': AlkionIdentity.applicationId,
      'request_id': _newRestoreId(),
      'profile_id': verified.profileId,
      'installation_id': const Uuid().v4(),
      'created_at': OperationInstant.now().text,
      'backup': _backupEvidence(verified),
    };
    await _writeDurable(
      File(p.join(directory, 'preparation.json')),
      localBytes(preparation),
    );
    await checkpoint?.call('fresh-preparation');
    return preparation;
  }

  /// Inspect only the selected target and its variant-scoped preparation. No
  /// identity/store is created; incomplete preparation always blocks local start.
  Future<FreshRestoreState?> freshState() async {
    final root = (await AlkionProfile.checkedRoot(
      supportRoot: supportRoot,
    )).path;
    if (File(p.join(root, 'local-profile.json')).existsSync()) {
      await AlkionProfile.existing(supportRoot: supportRoot);
      return null;
    }
    final preparation = _readPreparation(root);
    final directory = _preparationDirectory(root);
    if (preparation == null) {
      // Empty claimed preparation is honest reselection, never an empty profile.
      if (Directory(directory).existsSync()) {
        return const FreshRestoreState(canStartLocal: false);
      }
      await AlkionProfile.existing(supportRoot: supportRoot);
      if (Directory(root).existsSync() &&
          Directory(
            root,
          ).listSync().any((e) => p.basename(e.path) != '.identity.lock')) {
        throw const StoreException('restore_target_not_empty');
      }
      return const FreshRestoreState(canStartLocal: true);
    }
    final profileId = preparation['profile_id'] as String;
    _checkFreshTarget(root, profileId);
    final identityTemporary = File(p.join(root, 'local-profile.json.tmp'));
    if (identityTemporary.existsSync()) {
      final expected = jsonEncode({
        'version': 1,
        'application_id': AlkionIdentity.applicationId,
        'installation_id': preparation['installation_id'],
        'profile_id': profileId,
      });
      if (identityTemporary.lengthSync() > 4096 ||
          identityTemporary.readAsStringSync() != expected) {
        throw const StoreException('fresh_restore_preparation_invalid');
      }
    }
    final profileDirectory = p.join(root, 'profiles', profileId);
    final generations = Directory(
      p.join(profileDirectory, generationsDirectoryName),
    );
    final candidates = <PendingRestore>[];
    if (generations.existsSync()) {
      rejectLinkedPath(generations.path);
      for (final entry in generations.listSync(followLinks: false)) {
        final id = p.basename(entry.path);
        if (!restoreIdPattern.hasMatch(id) || entry is! Directory) {
          throw const StoreException('fresh_restore_preparation_invalid');
        }
        rejectLinkedPath(entry.path);
        final intentFile = File(p.join(entry.path, restoreIntentName));
        if (!intentFile.existsSync()) continue;
        if (intentFile.lengthSync() > 16384) {
          throw const StoreException('fresh_restore_preparation_invalid');
        }
        final intent = _readIntent(profileDirectory, id);
        if (intent['mode'] != 'fresh' ||
            intent['profile_id'] != profileId ||
            intent['installation_id'] != preparation['installation_id'] ||
            !_same(
              Map<String, Object?>.from(intent['backup'] as Map),
              Map<String, Object?>.from(preparation['backup'] as Map),
            ) ||
            (intent['staged'] as Map)['database'] !=
                p.relative(
                  generationDatabasePath(profileDirectory, id),
                  from: profileDirectory,
                )) {
          throw const StoreException('fresh_restore_preparation_invalid');
        }
        candidates.add(PendingRestore(id, intent));
      }
    }
    if (candidates.length > 1) {
      throw const StoreException('fresh_restore_preparation_invalid');
    }
    return FreshRestoreState(
      canStartLocal: false,
      pending: candidates.isEmpty
          ? PendingRestore(preparation['request_id'] as String, preparation)
          : candidates.single,
    );
  }

  Future<RestoreOutcome> completeFresh(String restoreId) async {
    final initial = await freshState();
    if (initial == null ||
        !initial.canComplete ||
        initial.pending?.restoreId != restoreId) {
      throw const StoreException('restore_not_pending');
    }
    final root = (await AlkionProfile.checkedRoot(
      supportRoot: supportRoot,
    )).path;
    final owner = _acquireFresh(root);
    try {
      return await _completeFreshOwned(restoreId);
    } finally {
      owner.close();
    }
  }

  Future<RestoreOutcome> _completeFreshOwned(String restoreId) async {
    final state = await freshState();
    final pending = state?.pending;
    if (pending == null ||
        !state!.canComplete ||
        pending.restoreId != restoreId) {
      throw const StoreException('restore_not_pending');
    }
    final intent = pending.intent;
    final root = (await AlkionProfile.checkedRoot(
      supportRoot: supportRoot,
    )).path;
    final directory = p.join(root, 'profiles', intent['profile_id'] as String);
    final outcome = await _select(directory, intent);
    await checkpoint?.call('restore-before-identity');
    await AlkionProfile.adoptRestored(
      supportRoot: Directory(root),
      profileId: intent['profile_id'] as String,
      installationId: intent['installation_id'] as String,
    );
    return outcome;
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
    final intent = <String, Object?>{
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
    if (mode == RestoreMode.fresh) {
      await _writeDurable(
        File(p.join(directory.path, restoreIntentName)),
        localBytes(intent),
      );
    }
    await checkpoint?.call('restore-staged');
    return intent;
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
      }
      await checkpoint?.call('restore-intent');
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
    final expectedPath = p.relative(
      generationDatabasePath(profileDirectory, restoreId),
      from: profileDirectory,
    );
    if (staged['database'] != expectedPath) {
      throw const StoreException('restore_staging_changed');
    }
    rejectLinkedPath(p.join(profileDirectory, expectedPath));
    if (FileSystemEntity.typeSync(
          p.join(profileDirectory, expectedPath),
          followLinks: false,
        ) !=
        FileSystemEntityType.file) {
      throw const StoreException('restore_staging_changed');
    }
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
    if ((intent['backup'] as Map)['application_id'] !=
        AlkionIdentity.applicationId) {
      throw const StoreException('backup_foreign_variant');
    }
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
  'application_id': (verified.manifest['tool'] as Map)['application_id'],
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
  rejectLinkedPath(file.path);
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
