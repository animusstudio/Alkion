import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/data/is_template_backfill.dart';
import 'package:workout_tracker/data/template_absorb.dart';
import 'package:workout_tracker/data/top_set_backfill.dart';
import 'package:workout_tracker/sync/db.dart';
import 'package:workout_tracker/sync/schema.dart';

import '../support/capture_fixture.dart';

/// The single qualified source profile these host tests run under.
QualifiedSourceProfile get linuxProfile => qualifiedSourceProfiles
    .singleWhere((p) => p.runtime.platform == Platform.operatingSystem);

Matcher unsupported(String code) =>
    throwsA(isA<UnsupportedCaptureProfile>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtures = <CaptureFixture>[];
  final opened = <PowerSyncDatabase>[];

  Future<CaptureFixture> fixture({
    Schema sourceSchema = schema,
    bool committedTailInWal = false,
  }) async {
    final f = await CaptureFixture.create(
        sourceSchema: sourceSchema, committedTailInWal: committedTailInWal);
    fixtures.add(f);
    return f;
  }

  tearDown(() async {
    for (final d in opened) {
      await d.close();
    }
    opened.clear();
    dbForTests = null;
    for (final f in fixtures) {
      await f.dispose();
    }
    fixtures.clear();
  });

  test('opens_fixture_without_domain_or_queue_mutation', () async {
    final f = await fixture();
    final before = await f.snapshot();
    // The fixture is a real, nonempty source: owned and template rows and
    // several local transactions waiting to upload.
    expect(before.rawRows['exercises'], hasLength(4));
    expect(before.queueText.map((r) => (jsonDecode(r) as List)[1]).toSet(),
        hasLength(greaterThan(1)));

    final database =
        await openCaptureDatabase(path: f.dbPath, profile: linuxProfile.openProfile);
    opened.add(database);
    expect(identical(db, database), isTrue,
        reason: 'normal startup must reuse the capture-opened instance');
    expect(identical(await openDatabase(), database), isTrue);

    // The public views read back exactly the raw stored rows.
    for (final table in fixtureTables) {
      final viaViews =
          await database.getAll('SELECT id FROM "$table" ORDER BY id');
      expect(viaViews.map((r) => r['id']),
          before.rawRows[table]!.map((r) => (jsonDecode(r) as List).first));
    }

    final profile = await qualifyCaptureProfile(database, linuxProfile.runtime);
    expect(profile.profileId, linuxProfile.profileId);
    expect(profile.evidenceDigest, linuxProfile.evidenceDigest);
    expect(profile.evidenceDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(profile.runtime, linuxProfile.runtime);

    final connectEffects = (database.currentStatus.connected ||
                database.currentStatus.connecting ||
                database.currentStatus.lastSyncedAt != null)
        ? 1
        : 0;
    await database.close();
    opened.remove(database);
    dbForTests = null;

    final after = await f.snapshot();
    expect(after.rawRows, before.rawRows);
    expect(after.queueText, before.queueText);
    expect(after.crudSequence, before.crudSequence);
    expect(after.localTargetOp, before.localTargetOp);
    expect(after.allTables, before.allTables);
    expect(after.preferences, before.preferences);
    expect(after.fileNames, before.fileNames);
    // Nothing was written at all: even the main database file is unchanged.
    expect(after.sqliteFileDigests, before.sqliteFileDigests);
    expect(after.sourceFileDigests, before.sourceFileDigests);

    // Each boot writer leaves a visible effect on this fixture (control below);
    // count the effects that opening produced.
    final loaderEffects = [
      for (final name in fixtureRawFiles.keys)
        if (after.sourceFileDigests[name] != before.sourceFileDigests[name])
          name,
    ].length;
    final backfillEffects = [
      for (final table in fixtureTables)
        if (!listEquals(after.rawRows[table], before.rawRows[table])) table,
    ].length;
    final identityEffects =
        after.preferences.containsKey('identity.current_user_id') ? 1 : 0;
    expect(loaderEffects + backfillEffects + connectEffects + identityEffects, 0);

    // Control: the normal boot writers DO change this fixture, so the
    // equalities above show they did not run during capture opening.
    final normal = await f.openNormally();
    opened.add(normal);
    await backfillTopSets(normal);
    await backfillIsTemplate(normal);
    await absorbTemplates(normal, fixtureUserId);
    await normal.close();
    opened.remove(normal);
    final afterBoot = await f.snapshot();
    expect(afterBoot.rawRows['sets'], isNot(before.rawRows['sets']));
    expect(afterBoot.rawRows['exercises'], isNot(before.rawRows['exercises']));
    expect(afterBoot.queueText, isNot(before.queueText));

    // The qualified SDK is the one the lockfile resolves.
    final lock = File('pubspec.lock').readAsStringSync();
    final pinned = RegExp(r'\n  powersync:\n(?:    .*\n)*?    version: "([^"]+)"')
        .firstMatch(lock)!
        .group(1);
    expect(linuxProfile.runtime.sdkVersion, pinned);
    expect(linuxProfile.runtime.schemaFingerprint,
        linuxProfile.openProfile.preInitializeSchemaFingerprint);
    expect(linuxProfile.runtime.coreVersion, linuxProfile.openProfile.coreVersion);
  });

  test('unknown_core_or_schema_refuses_open', () async {
    // A database left by another layout: inspected read-only and refused.
    final older = await fixture(sourceSchema: olderLayoutSchema());
    final olderBefore = await older.snapshot();
    await expectLater(
      openCaptureDatabase(path: older.dbPath, profile: linuxProfile.openProfile),
      unsupported('schema_unqualified'),
    );
    expect(() => db, throwsStateError, reason: 'no database was installed');
    final olderAfter = await older.snapshot();
    expect(olderAfter.sqliteFileDigests, olderBefore.sqliteFileDigests);
    expect(olderAfter.fileNames, olderBefore.fileNames,
        reason: 'inspection creates no WAL or index side files');
    expect(olderAfter.allTables, olderBefore.allTables);
    expect(olderAfter.sourceFileDigests, olderBefore.sourceFileDigests);

    // The read-only inspection does observe the difference.
    final observed = await inspectPreInitialize(older.dbPath);
    expect(observed.coreVersion, linuxProfile.openProfile.coreVersion);
    expect(observed.schema.value,
        isNot(linuxProfile.openProfile.preInitializeSchemaFingerprint));

    // An unreviewed core version is refused before the file is touched.
    final current = await fixture();
    final currentBefore = await current.snapshot();
    final otherCore = QualifiedOpenProfile(
      profileId: linuxProfile.openProfile.profileId,
      platform: linuxProfile.openProfile.platform,
      coreVersion: '0.4.14/00000000',
      preInitializeSchemaFingerprint:
          linuxProfile.openProfile.preInitializeSchemaFingerprint,
      procedure: linuxProfile.openProfile.procedure,
    );
    await expectLater(
      openCaptureDatabase(path: current.dbPath, profile: otherCore),
      unsupported('open_profile_unqualified'),
    );
    final currentAfter = await current.snapshot();
    expect(currentAfter.sqliteFileDigests, currentBefore.sqliteFileDigests);
    expect(currentAfter.fileNames, currentBefore.fileNames);

    // A missing database is never created by capture opening.
    final missing = '${current.dir.path}/absent.db';
    await expectLater(
      openCaptureDatabase(path: missing, profile: linuxProfile.openProfile),
      unsupported('database_missing'),
    );
    expect(File(missing).existsSync(), isFalse);

    // Runtime evidence that differs from a registered profile is refused,
    // and so is a registered runtime the database does not match.
    final database = await current.openNormally();
    opened.add(database);
    final r = linuxProfile.runtime;
    final unknownRuntime = CaptureRuntime(
      appVersion: r.appVersion,
      platform: r.platform,
      sdkVersion: r.sdkVersion,
      coreVersion: '0.4.14/00000000',
      schemaFingerprint: r.schemaFingerprint,
      producerRevision: r.producerRevision,
    );
    await expectLater(qualifyCaptureProfile(database, unknownRuntime),
        throwsA(isA<UnsupportedCaptureProfile>()));
    final otherVersion = CaptureRuntime(
      appVersion: '0.18.0+36',
      platform: r.platform,
      sdkVersion: r.sdkVersion,
      coreVersion: r.coreVersion,
      schemaFingerprint: r.schemaFingerprint,
      producerRevision: r.producerRevision,
    );
    await expectLater(qualifyCaptureProfile(database, otherVersion),
        unsupported('runtime_unqualified'));

    final olderDatabase =
        await older.openNormally(withSchema: olderLayoutSchema());
    opened.add(olderDatabase);
    await expectLater(qualifyCaptureProfile(olderDatabase, r),
        unsupported('schema_unqualified'));
  });

  test('initialization_retains_committed_wal_rows', () async {
    final f = await fixture(committedTailInWal: true);
    expect(await f.walOnlyIds(), walTailIds,
        reason: 'the tail transaction is committed only in the WAL');
    final before = await f.snapshot();

    final database =
        await openCaptureDatabase(path: f.dbPath, profile: linuxProfile.openProfile);
    opened.add(database);
    final viaViews = await database.getAll(
        "SELECT id FROM sessions WHERE id = 's-2' UNION ALL "
        "SELECT id FROM sets WHERE id = 'set-2-1' UNION ALL "
        "SELECT id FROM day_templates WHERE id = 'own-day-b' UNION ALL "
        "SELECT id FROM day_template_items WHERE id = 'own-item-b1'");
    expect(viaViews, hasLength(4));
    final queue = await database
        .getAll('SELECT id, tx_id, data FROM ps_crud ORDER BY id');
    expect([for (final r in queue) jsonEncode(r.values)], before.queueText);

    await database.close();
    opened.remove(database);
    dbForTests = null;

    final after = await f.snapshot();
    expect(after.rawRows, before.rawRows);
    expect(after.queueText, before.queueText);
    expect(after.crudSequence, before.crudSequence);
    expect(after.localTargetOp, before.localTargetOp);
    expect(after.allTables, before.allTables);
    expect(after.sourceFileDigests, before.sourceFileDigests);
    expect(after.preferences, before.preferences);
  });
}
