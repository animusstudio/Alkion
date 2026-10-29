import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/entry.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/identity/entry_journal.dart';
import 'package:alkion/main.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../tool/alkion_backup_recovery.dart' as proof;
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, root;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('alkion-entry-synthetic-');
    root = Directory('${temp.path}/${AlkionIdentity.applicationId}');
  });
  tearDown(() => temp.delete(recursive: true));

  test(
    'inspection and offline choice reserve no identity or adapter',
    () async {
      var factories = 0;
      final entry = AnimusEntryLifecycle(
        root,
        connectionFactory: (_, _) {
          factories++;
          return AnimusConnectionController();
        },
      );
      await entry.recover();
      expect((await RestoreService(root).freshState())!.canStartLocal, isTrue);
      await entry.abandonAuthentication();
      expect(root.existsSync(), isFalse);
      expect(temp.listSync(), isEmpty);
      expect(factories, 0);
    },
  );

  for (final intent in AnimusAuthIntent.values) {
    test(
      '$intent cancellation fences late return then restores another profile',
      () async {
        final fixture = await _backup(temp);
        final auth = _Auth()..login = Completer<AnimusAuthSession?>();
        final probe = _Probe();
        final entry = _entry(root, auth, probe);
        final controller = await entry.prepareConnection();
        final reservation = (await entry.journal.read())!;
        final pending = controller.connect(intent: intent);
        await Future<void>.delayed(Duration.zero);
        expect(auth.intent, intent);
        expect(root.existsSync(), isFalse);
        await entry.abandonAuthentication();
        expect(await entry.journal.read(), isNull);
        auth.login!.complete(_session());
        await pending;
        expect(auth.retains, 0);
        expect(probe.verifications, 0);
        expect(controller.identity, isNull);
        final outcome = await RestoreService(root).restore(File(fixture.path));
        expect(outcome.profileId, isNot(reservation.profileId));
        await AnimusEntryLifecycle(root).recover();
        final restored = await AlkionProfile.existing(supportRoot: root);
        expect(restored!.profileId, fixture.verified.profileId);
        expect(await RestoreService(root).freshState(), isNull);
        final retained = Directory(
          entry.journal.directory,
        ).listSync().whereType<Directory>().single;
        expect(File('${retained.path}/reservation.json').existsSync(), isTrue);
      },
    );
  }

  test(
    'restart preserves reservation but never restores auth or creates store',
    () async {
      final firstAuth = _Auth();
      final first = _entry(root, firstAuth, _Probe());
      final old = await first.prepareConnection();
      final reserved = (await first.journal.read())!;
      await old.close();
      old.dispose();
      final secondAuth = _Auth();
      final second = _entry(root, secondAuth, _Probe());
      await second.recover();
      expect(secondAuth.authorizations, 0);
      expect(root.existsSync(), isFalse);
      await second.prepareConnection();
      final resumed = (await second.journal.read())!;
      expect(resumed.installationId, reserved.installationId);
      expect(resumed.profileId, reserved.profileId);
      await second.abandonAuthentication();
      final fixture = await _backup(temp);
      await RestoreService(root).restore(File(fixture.path));
      expect(
        (await AlkionProfile.existing(supportRoot: root))!.profileId,
        fixture.verified.profileId,
      );
    },
  );

  test(
    'exact reserved store exists before retain and before read probe',
    () async {
      final auth = _Auth();
      final probe = _Probe()..result = AnimusProbeResult.accessDenied;
      final entry = _entry(root, auth, probe);
      final controller = await entry.prepareConnection();
      final reserved = (await entry.journal.read())!;
      LocalStore? handedStore;
      Future<void> checkScope() async {
        final profile = (await AlkionProfile.existing(supportRoot: root))!;
        expect(profile.installationId, reserved.installationId);
        expect(profile.profileId, reserved.profileId);
        final store = entry.preparedStore ?? handedStore!;
        expect(store.token.generation, reserved.generation);
        expect(await store.getAll('SELECT * FROM exercises'), isEmpty);
        await expectLater(
          LocalStore.open(
            profile: profile,
            expectedProfileId: profile.profileId,
            schema: workflowSchemaRegistry(),
          ),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'category',
              'profile_in_use',
            ),
          ),
        );
      }

      auth.beforeRetain = checkScope;
      probe.beforeVerify = checkScope;
      await controller.connect();
      expect(root.existsSync(), isFalse);
      final handed = await entry.confirmConnection();
      expect(identical(handed, controller), isTrue);
      expect(controller.state, AnimusConnectionState.accessDenied);
      expect(auth.retains, 1);
      expect(probe.verifications, 1);
      expect(await entry.journal.read(), isNull);
      final owned = entry.preparedStore;
      final runtime = await AlkionRuntime.open(
        root,
        preparedStore: entry.takePreparedStore(),
        connectionFactory: (_, _) => handed!,
      );
      handedStore = runtime.store;
      expect(runtime.store, same(owned));
      expect(runtime.animus, same(controller));
      await runtime.animus.disconnect();
      await runtime.animus.connect();
      await runtime.animus.confirm();
      expect(runtime.animus.state, AnimusConnectionState.accessDenied);
      expect(auth.retains, 2);
      expect(probe.verifications, 2);
      await runtime.close();
    },
  );

  test('offline transition refuses to race confirmation commit', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final journal = EntryJournal(
      root,
      checkpoint: (phase) async {
        if (phase == 'entry-creation-authorized') {
          entered.complete();
          await release.future;
        }
      },
    );
    final auth = _Auth(), probe = _Probe();
    final entry = _entry(root, auth, probe, journal: journal);
    final controller = await entry.prepareConnection();
    await controller.connect();
    final confirming = entry.confirmConnection();
    await entered.future;
    await expectLater(
      entry.abandonAuthentication(),
      throwsA(
        isA<StoreException>().having(
          (e) => e.category,
          'category',
          'entry_confirmation_in_progress',
        ),
      ),
    );
    expect(root.existsSync(), isFalse);
    release.complete();
    expect(await confirming, same(controller));
    expect(auth.retains, 1);
    await controller.close();
    controller.dispose();
  });

  test(
    'retention unavailable immediately continues in the confirmed local profile',
    () async {
      final auth = _Auth()
        ..retainFailure = const AnimusSecretStoreUnavailable();
      final probe = _Probe();
      final entry = _entry(root, auth, probe);
      final controller = await entry.prepareConnection();
      final reserved = (await entry.journal.read())!;
      await controller.connect();
      expect(await entry.confirmConnection(), isNull);
      expect(controller.issue, AnimusConnectionIssue.secureStorageUnavailable);
      expect(entry.hasLocalProfile, isTrue);
      final identity = File(
        '${root.path}/local-profile.json',
      ).readAsBytesSync();
      await entry.continueOffline();
      expect(await entry.journal.read(), isNull);
      expect(controller.identity, isNull);
      expect(probe.verifications, 0);
      final profile = (await AlkionProfile.existing(supportRoot: root))!;
      expect(profile.profileId, reserved.profileId);
      expect(
        File('${root.path}/local-profile.json').readAsBytesSync(),
        identity,
      );
      final runtime = await AlkionRuntime.open(
        root,
        preparedStore: entry.takePreparedStore(),
      );
      final store = runtime.store;
      expect(store.token.generation, reserved.generation);
      expect(await store.getAll('SELECT * FROM exercises'), isEmpty);
      await runtime.close();
      expect(await RestoreService(root).freshState(), isNull);
    },
  );

  test(
    'cancel while before-retain awaits fences secret retention and read',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final auth = _Auth(), probe = _Probe();
      final entry = _entry(
        root,
        auth,
        probe,
        checkpoint: (phase) async {
          if (phase == 'entry-identity-published') {
            entered.complete();
            await release.future;
          }
        },
      );
      final controller = await entry.prepareConnection();
      await controller.connect();
      final confirming = entry.confirmConnection();
      await entered.future;
      await controller.cancel();
      release.complete();
      expect(await confirming, isNull);
      expect(auth.retains, 0);
      expect(probe.verifications, 0);
      await expectLater(
        entry.abandonAuthentication(),
        throwsA(isA<StoreException>()),
      );
      // The proven local creation recovers, without resurrecting staged auth.
      await entry.takePreparedStore()?.close();
      await AnimusEntryLifecycle(root).recover();
      expect(await RestoreService(root).freshState(), isNull);
      expect(controller.identity, isNull);
      await controller.close();
      controller.dispose();
    },
  );

  for (final phase in [
    'entry-creation-authorized',
    'entry-identity-published',
    'entry-store-created',
  ]) {
    test(
      'crash at $phase recovers exact profile/generation without auth',
      () async {
        Future<void> crash(String point) async {
          if (point == phase) throw StateError('synthetic interruption');
        }

        final auth = _Auth(), probe = _Probe();
        final journal = EntryJournal(root, checkpoint: crash);
        final entry = _entry(
          root,
          auth,
          probe,
          journal: journal,
          checkpoint: crash,
        );
        final controller = await entry.prepareConnection();
        final reserved = (await journal.read())!;
        await controller.connect();
        expect(await entry.confirmConnection(), isNull);
        expect(auth.retains, 0);
        expect(probe.verifications, 0);
        await controller.close();
        controller.dispose();
        await AnimusEntryLifecycle(root).recover();
        final profile = (await AlkionProfile.existing(supportRoot: root))!;
        expect(profile.installationId, reserved.installationId);
        expect(profile.profileId, reserved.profileId);
        final store = await LocalStore.open(
          profile: profile,
          expectedProfileId: reserved.profileId,
          schema: workflowSchemaRegistry(),
        );
        expect(store.token.generation, 1);
        await store.close();
        expect(await EntryJournal(root).read(), isNull);
      },
    );
  }

  test(
    'interrupted fresh restore takes priority over pending sign-in journal',
    () async {
      final entry = _entry(root, _Auth(), _Probe());
      final controller = await entry.prepareConnection();
      final pending = File(
        '${entry.journal.directory}/pending/reservation.json',
      );
      final bytes = pending.readAsBytesSync();
      await controller.close();
      controller.dispose();
      final fixture = await _backup(temp);
      await expectLater(
        RestoreService(
          root,
          checkpoint: (phase) async {
            if (phase == 'fresh-preparation') {
              throw StateError('synthetic interruption');
            }
          },
        ).restore(File(fixture.path)),
        throwsStateError,
      );
      await AnimusEntryLifecycle(root).recover();
      expect((await RestoreService(root).freshState())!.canStartLocal, isFalse);
      expect(pending.readAsBytesSync(), bytes);
      expect(root.existsSync(), isFalse);
    },
  );

  test(
    'established identity conflict preserves original and journal bytes',
    () async {
      final entry = _entry(root, _Auth(), _Probe());
      final controller = await entry.prepareConnection();
      final pending = File(
        '${entry.journal.directory}/pending/reservation.json',
      );
      final bytes = pending.readAsBytesSync();
      final established = await AlkionProfile.open(supportRoot: root);
      final identity = File('${root.path}/local-profile.json');
      final identityBytes = identity.readAsBytesSync();
      await expectLater(
        AnimusEntryLifecycle(root).recover(),
        throwsA(isA<StoreException>()),
      );
      expect(identity.readAsBytesSync(), identityBytes);
      expect(pending.readAsBytesSync(), bytes);
      expect(
        (await AlkionProfile.existing(supportRoot: root))!.profileId,
        established.profileId,
      );
      await controller.close();
      controller.dispose();
    },
  );

  test(
    'interrupted established restore takes precedence over conflicting entry',
    () async {
      final entry = _entry(root, _Auth(), _Probe());
      final controller = await entry.prepareConnection();
      final pending = File(
        '${entry.journal.directory}/pending/reservation.json',
      );
      final bytes = pending.readAsBytesSync();
      await controller.close();
      controller.dispose();
      final fixture = await _backup(temp);
      await RestoreService(root).restore(File(fixture.path));
      await expectLater(
        RestoreService(
          root,
          checkpoint: (phase) async {
            if (phase == 'restore-intent') {
              throw StateError('synthetic interruption');
            }
          },
        ).restore(File(fixture.path)),
        throwsStateError,
      );
      await expectLater(
        AnimusEntryLifecycle(root).recover(),
        throwsA(
          isA<GenerationSelectionException>().having(
            (e) => e.category,
            'category',
            'restore_interrupted',
          ),
        ),
      );
      expect(pending.readAsBytesSync(), bytes);
      expect(await RestoreService(root).pending(), hasLength(1));
    },
  );

  test('generation mismatch fails before secret retention or probe', () async {
    final auth = _Auth(), probe = _Probe();
    final entry = _entry(
      root,
      auth,
      probe,
      checkpoint: (phase) async {
        if (phase != 'entry-store-created') return;
        throw StateError('synthetic interruption');
      },
    );
    final controller = await entry.prepareConnection();
    await controller.connect();
    expect(await entry.confirmConnection(), isNull);
    await controller.close();
    controller.dispose();
    final profile = (await AlkionProfile.existing(supportRoot: root))!;
    final path = await profile.databasePath(
      expectedProfileId: profile.profileId,
    );
    final db = sqlite.sqlite3.open(path);
    db.execute('UPDATE profile_state SET generation=2');
    db.close();
    await expectLater(
      AnimusEntryLifecycle(root).recover(),
      throwsA(
        isA<StoreException>().having(
          (e) => e.category,
          'category',
          'entry_generation_conflict',
        ),
      ),
    );
    expect(auth.retains, 0);
    expect(probe.verifications, 0);
    expect(File(path).existsSync(), isTrue);
    expect(await entry.journal.read(), isNotNull);
  });

  test(
    'exact identity temporary resumes; unknown journal bytes remain untouched',
    () async {
      final journal = EntryJournal(root);
      final reservation = await journal.reserve();
      await journal.beginCreation(reservation);
      await root.create();
      await File('${root.path}/local-profile.json.tmp').writeAsString(
        jsonEncode({
          'version': 1,
          'application_id': AlkionIdentity.applicationId,
          'installation_id': reservation.installationId,
          'profile_id': reservation.profileId,
        }),
        flush: true,
      );
      await AnimusEntryLifecycle(root).recover();
      expect(
        (await AlkionProfile.existing(supportRoot: root))!.profileId,
        reservation.profileId,
      );
      final other = Directory('${temp.path}/other');
      await other.create();
      final otherRoot = Directory(
        '${other.path}/${AlkionIdentity.applicationId}',
      );
      final otherJournal = EntryJournal(otherRoot);
      await otherJournal.reserve();
      final unknown = await File(
        '${otherJournal.directory}/pending/newer.json',
      ).writeAsString('unknown-byte-evidence', flush: true);
      await expectLater(
        AnimusEntryLifecycle(otherRoot).recover(),
        throwsA(isA<StoreException>()),
      );
      expect(unknown.readAsStringSync(), 'unknown-byte-evidence');
      expect(otherRoot.existsSync(), isFalse);
    },
  );
}

AnimusEntryLifecycle _entry(
  Directory root,
  _Auth auth,
  _Probe probe, {
  EntryJournal? journal,
  Future<void> Function(String)? checkpoint,
}) {
  final entry = AnimusEntryLifecycle(
    root,
    journal: journal,
    checkpoint: checkpoint,
    connectionFactory: (_, beforeRetain) => AnimusConnectionController(
      config: syntheticAnimusConfig(),
      auth: auth,
      probe: probe,
      beforeRetain: beforeRetain,
    ),
  );
  addTearDown(() async {
    await entry.connection?.close();
    entry.connection?.dispose();
    await entry.takePreparedStore()?.close();
  });
  return entry;
}

Future<BackupReceipt> _backup(Directory temp) async {
  final source = await Directory('${temp.path}/backup-source').create();
  final store = await proof.openStore(source);
  try {
    return await createBackup(
      store,
      await Directory('${temp.path}/backups').create(),
    );
  } finally {
    await store.close();
  }
}

AnimusAuthSession _session() => AnimusAuthSession(
  identity: AnimusIdentity(
    issuer: syntheticAnimusConfig().issuer,
    subject: 'synthetic-entry',
  ),
  accessToken: 'synthetic-token',
  expiresAt: DateTime.utc(2040),
);

final class _Auth implements AnimusAuthPort {
  int authorizations = 0, retains = 0;
  AnimusAuthIntent? intent;
  Completer<AnimusAuthSession?>? login;
  Future<void> Function()? beforeRetain;
  Object? retainFailure;
  @override
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  }) {
    this.intent = intent;
    authorizations++;
    return login?.future ?? Future.value(_session());
  }

  @override
  Future<void> retain(AnimusAuthSession session) async {
    await beforeRetain?.call();
    if (retainFailure != null) throw retainFailure!;
    retains++;
  }

  @override
  Future<AnimusAuthSession?> restore() =>
      throw StateError('no startup restore');
  @override
  Future<AnimusAuthSession?> refresh() =>
      throw StateError('no startup refresh');
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}

final class _Probe implements AnimusProbePort {
  int verifications = 0;
  AnimusProbeResult result = AnimusProbeResult.verified;
  Future<void> Function()? beforeVerify;
  @override
  Future<AnimusProbeResult> verify(AnimusAuthSession session) async {
    await beforeVerify?.call();
    verifications++;
    return result;
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> close() async {}
}
