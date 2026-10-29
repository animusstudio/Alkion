import 'dart:io';

import '../identity/alkion_identity.dart';
import '../identity/alkion_profile.dart';
import '../identity/entry_journal.dart';
import '../recovery/restore.dart';
import '../store/generation_selection.dart';
import '../store/local_store.dart';
import '../store/schema.dart';
import 'connection.dart';
import 'runtime.dart';

typedef EntryConnectionFactory =
    AnimusConnectionController Function(
      EntryReservation reservation,
      Future<void> Function() beforeRetain,
    );

/// Owns the first-use auth scope while the normal local root remains fresh.
/// No authentication client exists until prepareConnection follows a tap.
final class AnimusEntryLifecycle {
  AnimusEntryLifecycle(
    this.supportRoot, {
    EntryJournal? journal,
    this.connectionFactory,
    this.checkpoint,
  }) : journal = journal ?? EntryJournal(supportRoot);
  final Directory supportRoot;
  final EntryJournal journal;
  final EntryConnectionFactory? connectionFactory;
  final Future<void> Function(String)? checkpoint;
  EntryReservation? _reservation;
  AnimusConnectionController? _connection;
  Future<void>? _creation;
  LocalStore? _preparedStore;
  bool _confirming = false,
      _identityPublished = false,
      _localProfileReady = false,
      _completed = false;
  int _epoch = 0;
  AnimusConnectionController? get connection => _connection;
  bool get hasLocalProfile => _localProfileReady;
  LocalStore? get preparedStore => _preparedStore;

  /// Transfers the already owned generation to the runtime without a reopen
  /// gap in which a replacement could change the confirmed local scope.
  LocalStore? takePreparedStore() {
    final store = _preparedStore;
    _preparedStore = null;
    return store;
  }

  /// Startup recovery never restores credentials or contacts the provider.
  /// A durable creation marker is explicit consent to finish that exact local
  /// identity; a mere reservation can only resume the still-fresh entry flow.
  Future<void> recover() async {
    // Fresh restore recovery owns precedence, including an empty claim.
    final preparation = freshPreparationDirectory(
      supportRoot.path,
      AlkionIdentity.applicationId,
    );
    if (FileSystemEntity.typeSync(preparation, followLinks: false) !=
            FileSystemEntityType.notFound &&
        !File('${supportRoot.path}/local-profile.json').existsSync()) {
      return;
    }
    if (File('${supportRoot.path}/local-profile.json').existsSync()) {
      final profile = (await AlkionProfile.existing(supportRoot: supportRoot))!;
      final directory = await profile.profileDirectory(
        expectedProfileId: profile.profileId,
      );
      if (pendingRestoreIds(directory).isNotEmpty) {
        throw const GenerationSelectionException('restore_interrupted');
      }
    }
    final reservation = await journal.read();
    _reservation = reservation;
    if (reservation == null) return;
    if (reservation.creating) {
      await _createExact(reservation);
      await journal.preserve(reservation);
      _reservation = null;
      return;
    }
    final fresh = await RestoreService(supportRoot).freshState();
    if (fresh == null || !fresh.canStartLocal) {
      throw const StoreException('entry_profile_conflict');
    }
  }

  Future<AnimusConnectionController> prepareConnection() async {
    if (_connection != null) return _connection!;
    final epoch = _epoch;
    final fresh = await RestoreService(supportRoot).freshState();
    if (fresh == null || !fresh.canStartLocal) {
      throw const StoreException('entry_profile_conflict');
    }
    final reservation = await journal.reserve();
    _reservation = reservation;
    _completed = false;
    if (epoch != _epoch) throw const StoreException('entry_cancelled');
    final factory =
        connectionFactory ??
        (reservation, beforeRetain) => createAnimusConnection(
          installationId: reservation.installationId,
          profileId: reservation.profileId,
          generation: reservation.generation,
          beforeRetain: beforeRetain,
        );
    return _connection = factory(reservation, () {
      if (epoch != _epoch) throw const StoreException('entry_cancelled');
      if (_completed) return Future.value();
      return _creation ??= _materialize(reservation, epoch).whenComplete(() {
        _creation = null;
      });
    });
  }

  Future<void> _materialize(EntryReservation reservation, int epoch) async {
    await journal.beginCreation(reservation);
    if (epoch != _epoch) throw const StoreException('entry_cancelled');
    await _createExact(reservation, keepOpen: true);
  }

  Future<void> _createExact(
    EntryReservation reservation, {
    bool keepOpen = false,
  }) async {
    if (_preparedStore != null) return;
    final profile = await AlkionProfile.createReserved(
      supportRoot: supportRoot,
      installationId: reservation.installationId,
      profileId: reservation.profileId,
    );
    _identityPublished = true;
    await checkpoint?.call('entry-identity-published');
    final store = await LocalStore.open(
      profile: profile,
      expectedProfileId: reservation.profileId,
      schema: prescriptionSchemaRegistry(),
    );
    try {
      if (store.token.generation != reservation.generation ||
          store.profile.installationId != reservation.installationId) {
        throw const StoreException('entry_generation_conflict');
      }
      await checkpoint?.call('entry-store-created');
    } catch (_) {
      await store.close();
      rethrow;
    }
    if (keepOpen) {
      _preparedStore = store;
    } else {
      await store.close();
    }
    _localProfileReady = true;
  }

  /// Fences synchronously before waiting for bounded adapter cleanup or disk.
  Future<void> abandonAuthentication() async {
    // Confirmation is a serialized commit transition. A published profile can
    // never be presented as a fresh foreign-profile restore target.
    if (_confirming || _identityPublished) {
      throw const StoreException('entry_confirmation_in_progress');
    }
    _epoch++;
    final connection = _connection;
    _connection = null;
    final closing = connection?.close();
    try {
      await _creation;
    } on Object {
      // Creation evidence remains durable; never erase an uncertain identity.
    }
    await closing;
    connection?.dispose();
    await journal.preserve(_reservation ?? await journal.read());
    _reservation = null;
    _creation = null;
  }

  /// Secure-storage failure does not remove the confirmed local profile or
  /// require a restart. This route enters that profile, never a fresh restore.
  Future<void> continueOffline() async {
    if (_confirming || !_localProfileReady) {
      throw const StoreException('entry_local_profile_not_ready');
    }
    _epoch++;
    final connection = _connection;
    _connection = null;
    await connection?.close();
    connection?.dispose();
    await journal.preserve(_reservation ?? await journal.read());
    _reservation = null;
    _completed = true;
  }

  /// The connection survives handoff to Profile in the selected local runtime.
  /// API denial/offline status is retained truthfully after secure confirmation.
  Future<AnimusConnectionController?> confirmConnection() async {
    final connection = _connection;
    if (connection == null) return null;
    if (_confirming) return null;
    _confirming = true;
    final epoch = _epoch;
    try {
      await connection.confirm();
      if (epoch != _epoch || !connection.confirmed) return null;
      await journal.preserve(_reservation);
      _reservation = null;
      _completed = true;
      return connection;
    } finally {
      _confirming = false;
    }
  }
}
