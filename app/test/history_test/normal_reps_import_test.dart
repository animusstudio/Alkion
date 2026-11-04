import 'dart:convert';
import 'dart:io';

import 'package:alkion/catalog/catalog.dart';
import 'package:alkion/history_test/history_mapping.dart';
import 'package:alkion/history_test/retired_history_workspace.dart';
import 'package:alkion/main.dart';
import 'package:alkion/recovery/backup.dart';
import 'package:alkion/recovery/restore.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/history_transfer_service.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:crypto/crypto.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/transfer/reps_import.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixture.dart';
import '../support/retired_history_workspace_fixture.dart';

Future<Map<String, String>> _treeDigests(Directory root) async => {
  for (final file
      in await root
          .list(recursive: true, followLinks: false)
          .where((entry) => entry is File)
          .toList())
    file.path.substring(root.path.length): sha256
        .convert(await File(file.path).readAsBytes())
        .toString(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'normal full import keeps current profile, refreshes caches and retires old profile only after backup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'alkion-normal-import-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final root = Directory('${directory.path}/dev.animusstudio.alkion.dev');
      final bundle = CatalogBundle.fromJsonString(
        jsonEncode(syntheticCatalog()),
      );
      var runtime = await AlkionRuntime.open(root, catalogBundle: bundle);
      addTearDown(() => runtime.close());
      final profile = runtime.store.profile;
      final path = runtime.store.path;
      final store = runtime.store;
      await runtime.settings.setProfileName('Existing synthetic athlete');
      final retired = await HistoryTestWorkspace.open(profile);
      final retiredId = retired.profile.profileId;
      await retired.close();
      final service = RepsImportService(store, profileId: profile.profileId);
      final preview = await service.previewFile(
        'test/fixtures/alkion/full-rich-synthetic-v1.json',
      );
      final review = HistoryMappingReview.unresolved(preview.mappingSource!);
      expect(preview.canImport, isTrue);
      expect(RetiredHistoryWorkspace.exists(profile), isTrue);
      expect(await store.getAll('SELECT * FROM sessions'), isEmpty);

      final active = ActiveSessionController()
        ..seedEmpty(name: 'Synthetic active', focus: '');
      runtime.sessions.register(active);
      await expectLater(runtime.importReps(preview, review), throwsStateError);
      expect(await store.getAll('SELECT * FROM sessions'), isEmpty);
      expect(RetiredHistoryWorkspace.exists(profile), isTrue);
      runtime.sessions.clear();
      active.dispose();

      await runtime.importReps(preview, review);
      expect(runtime.store, same(store));
      expect(runtime.store.path, path);
      expect(runtime.store.profile.profileId, profile.profileId);
      expect(runtime.store.profile.installationId, profile.installationId);
      expect(runtime.settings.profileName, 'Existing synthetic athlete');
      expect(runtime.units.unit, Unit.kg);
      expect(runtime.contentRevision.value, 1);
      expect(runtime.historyMappings.value, isNotEmpty);
      expect(
        runtime.catalog!.ownedExercises.length,
        preview.counts['exercises'],
      );
      expect(
        await store.getAll('SELECT * FROM sessions'),
        hasLength(preview.counts['sessions']!),
      );
      expect(RetiredHistoryWorkspace.exists(profile), isFalse);
      expect(RetiredHistoryWorkspace.rootFor(profile).existsSync(), isFalse);
      final backups = await Directory(
        '${root.path}/retired-history-backups',
      ).list().where((entry) => entry.path.endsWith(backupExtension)).toList();
      expect(backups, hasLength(1));
      final verified = await verifyBackupFile(
        File(backups.single.path),
        schema: runtime.store.schema,
      );
      expect(verified.profileId, retiredId);

      // An identical retry applies preferences only when explicitly requested.
      await runtime.importReps(preview, review, applySettings: true);
      expect(runtime.settings.profileName, 'Synthetic Lifter');
      expect(runtime.units.unit, Unit.lb);
      expect(
        await Directory('${root.path}/retired-history-backups').list().length,
        1,
      );
      await runtime.close();
      runtime = await AlkionRuntime.open(root, catalogBundle: bundle);
      expect(runtime.store.profile.profileId, profile.profileId);
      expect(runtime.historyMappings.value, isNotEmpty);
      expect(runtime.settings.profileName, 'Synthetic Lifter');
      expect(runtime.units.unit, Unit.lb);
    },
  );

  test(
    'cleanup preserves foreign marker and active ownership without deleting parent bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'alkion-retired-cleanup-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final runtime = await AlkionRuntime.open(
        Directory('${directory.path}/dev.animusstudio.alkion.dev'),
        catalogBundle: CatalogBundle.fromJsonString(
          jsonEncode(syntheticCatalog()),
        ),
      );
      addTearDown(runtime.close);
      final parent = runtime.store.profile;
      final retired = await HistoryTestWorkspace.open(parent);
      await expectLater(
        RetiredHistoryWorkspace.backupAndRemove(parent),
        throwsA(anything),
      );
      expect(RetiredHistoryWorkspace.rootFor(parent).existsSync(), isTrue);
      expect(runtime.store.admission.name, 'open');
      await retired.close();
      final marker = File(
        '${RetiredHistoryWorkspace.containerFor(parent).path}/workspace.json',
      );
      final value =
          jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      value['parent_profile_id'] = 'foreign-parent';
      await marker.writeAsString(jsonEncode(value), flush: true);
      await expectLater(
        RetiredHistoryWorkspace.backupAndRemove(parent),
        throwsA(anything),
      );
      expect(RetiredHistoryWorkspace.rootFor(parent).existsSync(), isTrue);
      expect(await runtime.store.getAll('SELECT * FROM sessions'), isEmpty);
    },
  );

  for (final location in ['root', 'profile']) {
    test(
      'cleanup refuses an unbacked regular file in $location and leaves both stores byte-for-byte intact',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'alkion-cleanup-unknown-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final runtime = await AlkionRuntime.open(
          Directory('${directory.path}/dev.animusstudio.alkion.dev'),
          catalogBundle: CatalogBundle.fromJsonString(
            jsonEncode(syntheticCatalog()),
          ),
        );
        addTearDown(runtime.close);
        await runtime.settings.setProfileName('Synthetic normal profile');
        final retired = await HistoryTestWorkspace.open(runtime.store.profile);
        final unknown = File(
          location == 'root'
              ? '${retired.profile.root.path}/exported-history.json'
              : '${File(retired.store.path).parent.path}/draft.json',
        );
        await unknown.writeAsString('synthetic retained bytes', flush: true);
        await retired.close();
        final parentBefore = await _treeDigests(runtime.store.profile.root);
        final retiredBefore = await _treeDigests(retired.container);
        await expectLater(
          RetiredHistoryWorkspace.backupAndRemove(runtime.store.profile),
          throwsA(
            isA<StoreException>().having(
              (error) => error.category,
              'category',
              'history_test_unbacked_bytes_preserved',
            ),
          ),
        );
        expect(await _treeDigests(runtime.store.profile.root), parentBefore);
        expect(await _treeDigests(retired.container), retiredBefore);
        expect(await unknown.readAsString(), 'synthetic retained bytes');
        final reopened = await openAlkionStore(retired.profile);
        expect(reopened.profileId, retired.profile.profileId);
        await reopened.close();
        expect(runtime.settings.profileName, 'Synthetic normal profile');
        expect(await runtime.store.getAll('SELECT * FROM sessions'), isEmpty);
      },
    );
  }

  test(
    'cleanup refuses a real restored workspace with selected and fenced generations and preserves both stores',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'alkion-cleanup-generations-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final runtime = await AlkionRuntime.open(
        Directory('${directory.path}/dev.animusstudio.alkion.dev'),
        catalogBundle: CatalogBundle.fromJsonString(
          jsonEncode(syntheticCatalog()),
        ),
      );
      addTearDown(runtime.close);
      await runtime.settings.setProfileName('Synthetic normal profile');
      final retired = await HistoryTestWorkspace.open(runtime.store.profile);
      final service = HistoryTransferService(
        retired.store,
        profileId: retired.profile.profileId,
      );
      final preview = await service.previewFile(
        'test/fixtures/alkion/history-synthetic-v1.json',
        namespace: 'synthetic-retired-history',
      );
      expect(
        (await service.importPreview(
          preview,
          namespace: 'synthetic-retired-history',
        )).status,
        ImportStatus.selected,
      );
      final canonicalPath = retired.store.path;
      final backupDirectory = await Directory(
        '${directory.path}/source-backup',
      ).create();
      final receipt = await createBackup(retired.store, backupDirectory);
      await retired.close();
      await RestoreService(
        retired.profile.root,
        schema: retired.store.schema,
        workDirectory: directory,
      ).restore(File(receipt.path));
      final selected = await openAlkionStore(retired.profile);
      expect(selected.path, isNot(canonicalPath));
      expect(File(canonicalPath).existsSync(), isTrue);
      expect(await selected.getAll('SELECT * FROM sessions'), hasLength(3));
      await selected.close();
      final parentBefore = await _treeDigests(runtime.store.profile.root);
      final retiredBefore = await _treeDigests(retired.container);
      await expectLater(
        RetiredHistoryWorkspace.backupAndRemove(runtime.store.profile),
        throwsA(
          isA<StoreException>().having(
            (error) => error.category,
            'category',
            'history_test_unbacked_bytes_preserved',
          ),
        ),
      );
      expect(await _treeDigests(runtime.store.profile.root), parentBefore);
      expect(await _treeDigests(retired.container), retiredBefore);
      expect(File(canonicalPath).existsSync(), isTrue);
      final reopened = await openAlkionStore(retired.profile);
      expect(reopened.path, selected.path);
      expect(await reopened.getAll('SELECT * FROM sessions'), hasLength(3));
      await reopened.close();
      expect(runtime.settings.profileName, 'Synthetic normal profile');
      expect(await runtime.store.getAll('SELECT * FROM sessions'), isEmpty);
    },
  );
}
