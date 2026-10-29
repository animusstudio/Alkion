import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:alkion/ui/add_weight_sheet.dart';
import 'package:alkion/ui/bodyweight_view.dart';
import 'package:alkion/units/unit_service.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/widgets/line_chart.dart';
import 'package:alkion/widgets/progress_widgets.dart';

import 'local_screen_harness.dart';
import 'prepared_intent_retry_test.dart' show FaultDatabase;
import 'prepared_ui_retry_test.dart' show observeDialog;

const measurementDate = '2026-10-13';
const exactKg = '82.450000000000000001';
const sourceValues = <String, String?>{
  'null-id': null,
  'valid-id': exactKg,
  'empty-id': '',
  'invalid-id': 'bad',
};

Future<void> seedMeasurements(
  LocalStore store, {
  String date = measurementDate,
  bool latestUnavailable = false,
}) async {
  await store.writeTransaction((tx) async {
    for (final entry in sourceValues.entries) {
      await putSourceMeasurement(tx, entry.key, entry.value, date);
    }
    if (latestUnavailable) {
      await putSourceMeasurement(tx, 'latest-null-id', null, '2026-10-14');
    }
  });
}

Future<void> putSourceMeasurement(
  LocalTransaction tx,
  String id,
  String? value,
  String date,
) async {
  final raw = Uint8List.fromList(
    utf8.encode(jsonEncode({'date': date, 'weight_kg': value, 'unknown': id})),
  );
  final ref = LocalRef(tx.profileId, RecordKind.bodyweight, id);
  final digest = sha256.convert(raw).toString();
  await tx.putArtifact(
    id: 'artifact-$id',
    bytes: raw,
    digest: digest,
    parserVersion: 'synthetic-measurement/1',
    format: 'synthetic-measurement',
    disposition: 'selected',
  );
  await tx.mapOrigin(
    SourceOrigin(
      profileId: tx.profileId,
      namespace: 'synthetic-null-measurements',
      sourceKind: 'bodyweight_logs',
      externalId: id,
    ),
    ref,
  );
  await tx
      .execute('INSERT INTO source_revisions VALUES(?,?,?,?,?,?,?,?,?,?,?)', [
        tx.profileId,
        'source-$id',
        'synthetic-null-measurements',
        'bodyweight_logs',
        id,
        'artifact-$id',
        digest,
        raw,
        'synthetic-measurement/1',
        null,
        OperationInstant.now().text,
      ]);
  final fields = <String, Object?>{'date': date, 'weight_kg': value};
  final revision = await tx.writeRevision(
    ref,
    localBytes(fields),
    layer: 'sourceSelection',
    sourceRevisionId: 'source-$id',
  );
  await tx.putRecord(ref, revision, fields, sourceRevisionId: 'source-$id');
}

/// Optional complete synthetic evidence; ordinary test runs need no output path.
Future<void> snapshot(LocalStore store, String name) async {
  const output = String.fromEnvironment('ALKION_NULL_PROOF');
  if (output.isEmpty) return;
  if (!RegExp(r'^/tmp/alkion-null-fix-[a-zA-Z0-9-]+$').hasMatch(output)) {
    throw StateError('Fresh owned /tmp/alkion-null-fix-* output required');
  }
  final directory = Directory(output);
  await directory.create(recursive: true);
  final file = File('$output/$name.json');
  if (await file.exists()) throw StateError('Evidence must not be overwritten');
  await file.writeAsString(jsonEncode(await store.inventory()), flush: true);
  await store.backupTo('$output/$name.sqlite');
}

void expectMeasurements(List<BodyweightEntry> entries) {
  expect(entries.map((e) => e.id).toSet(), sourceValues.keys.toSet());
  for (final entry in entries) {
    expect(entry.localRevision, 1);
    expect(entry.weightEvidence!.raw, sourceValues[entry.id]);
    final expected = switch (entry.id) {
      'null-id' => ValueState.nullValue,
      'empty-id' => ValueState.empty,
      'invalid-id' => ValueState.invalid,
      _ => ValueState.valid,
    };
    expect(entry.weightEvidence!.state, expected);
    expect(
      entry.weightKg,
      entry.id == 'valid-id' ? double.parse(exactKg) : null,
    );
  }
}

Future<void> expectOriginalsAndAlternatives(
  LocalStore store,
  Map<String, Object?> before,
) async {
  final after = await store.inventory();
  for (final table in [
    'source_artifacts',
    'source_revisions',
    'origin_mappings',
  ]) {
    expect(after[table], before[table], reason: table);
  }
  final oldRows = (before['bodyweight_logs'] as List).cast<Map>();
  final newRows = (after['bodyweight_logs'] as List).cast<Map>();
  expect(
    newRows.where((r) => r['id'] != 'null-id'),
    oldRows.where((r) => r['id'] != 'null-id'),
  );
}

Future<void> waitForSave(WidgetTester tester) async {
  for (
    var i = 0;
    i < 100 && find.text('Save entry').evaluate().isNotEmpty;
    i++
  ) {
    await settleReal(tester, ticks: 1);
  }
  expect(find.text('Save entry'), findsNothing);
}

Future<void> verifyTwoReopens(
  LocalStore store,
  Map<String, Object?> expected,
  String label,
) async {
  final profile = store.profile;
  await store.close();
  for (var i = 1; i <= 2; i++) {
    final reopened = await LocalStore.open(
      profile: profile,
      expectedProfileId: profile.profileId,
      schema: prescriptionSchemaRegistry(),
    );
    try {
      expect(await reopened.inventory(), expected);
      await snapshot(reopened, '$label-reopen-$i');
    } finally {
      await reopened.close();
    }
  }
}

Widget openSheet(ScreenHarness harness, {BodyweightEntry? selected}) =>
    harness.wrap(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAddWeightSheet(context, selected: selected),
            child: const Text('open'),
          ),
        ),
      ),
    );

/// Delays delivery of the first actual SQLite measurement watch result only.
/// Apply/fault/recovery remain the existing production-store forwarder.
class SeedGateDatabase extends FaultDatabase {
  SeedGateDatabase(super.store, {super.beforeCommit});
  final received = Completer<List<Map<String, dynamic>>>();
  final release = Completer<void>();
  final firstApplyFinished = Completer<void>();
  final expectedTokens = <StoreToken?>[];
  final trace = <String>[];
  bool _gated = false;

  @override
  Stream<List<Map<String, dynamic>>> watch(
    String sql, {
    List<Object?> parameters = const [],
  }) => super.watch(sql, parameters: parameters).asyncMap((rows) async {
    if (!_gated && sql.contains('FROM bodyweight_logs')) {
      _gated = true;
      trace.add('real_watch_received');
      received.complete(rows);
      await release.future;
      trace.add('real_watch_released');
    }
    return rows;
  });

  @override
  Future<LocalActionResult> apply(
    LocalAction action,
    Future<Object?> Function(LocalTransaction) mutate, {
    StoreToken? expected,
  }) async {
    expectedTokens.add(expected);
    trace.add('apply_${actions.length + 1}_started');
    try {
      final result = await super.apply(action, mutate, expected: expected);
      trace.add('apply_${actions.length}_committed');
      return result;
    } catch (error) {
      trace.add('apply_${actions.length}_refused: $error');
      rethrow;
    } finally {
      if (!firstApplyFinished.isCompleted) firstApplyFinished.complete();
    }
  }
}

Future<void> seedTrace(
  String name,
  SeedGateDatabase gate,
  WidgetTester tester,
) async {
  final value = {
    'events': gate.trace,
    'actions': [
      for (var i = 0; i < gate.actions.length; i++)
        {
          'bytes': gate.actions[i].bytes.toList(),
          'hash': gate.actions[i].hash,
          'token_profile': gate.expectedTokens[i]?.profileId,
          'token_generation': gate.expectedTokens[i]?.generation,
        },
    ],
    'requested_value_visible': find.text('181.7').evaluate().isNotEmpty,
    'unavailable_visible': find.text('—').evaluate().isNotEmpty,
    'save_visible': find.text('Save entry').evaluate().isNotEmpty,
    'focused_text': find.byType(TextField).evaluate().isEmpty
        ? null
        : tester.widget<TextField>(find.byType(TextField)).controller!.text,
  };
  debugPrintSynchronously('MEASUREMENT_SEED_TRACE ${jsonEncode(value)}');
  const output = String.fromEnvironment('ALKION_NULL_PROOF');
  if (output.isEmpty) return;
  if (!RegExp(r'^/tmp/alkion-null-fix-[a-zA-Z0-9-]+$').hasMatch(output)) {
    throw StateError('Fresh owned /tmp/alkion-null-fix-* output required');
  }
  final file = File('$output/$name.trace.json');
  await file.parent.create(recursive: true);
  if (await file.exists()) throw StateError('Evidence must not be overwritten');
  await file.writeAsString(jsonEncode(value), flush: true);
}

void main() {
  test(
    'NULL, empty and invalid preserve both repository reads and chosen correction across two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-null-measurements-',
      );
      var store = await openDomainStore(root);
      try {
        await seedMeasurements(store);
        await snapshot(store, 'repository-before');
        var repo = BodyweightRepository.local(store);
        expectMeasurements(await repo.watchSeriesAsc().first);
        expectMeasurements(await repo.onDate(measurementDate));
        expectMeasurements(await repo.watchSeriesAsc().first);
        final original = await store.inventory();
        for (var reopen = 0; reopen < 2; reopen++) {
          await store.close();
          store = await openDomainStore(root);
          repo = BodyweightRepository.local(store);
          expectMeasurements(await repo.watchSeriesAsc().first);
          expectMeasurements(await repo.onDate(measurementDate));
          expect(await store.inventory(), original);
        }
        final chosen = (await repo.onDate(
          measurementDate,
        )).singleWhere((e) => e.id == 'null-id');
        await repo.commitPrepared(
          repo.prepareMeasurement(
            dateIso: chosen.date,
            selected: chosen,
            kg: const DecimalEvidence(
              ValueState.valid,
              '83.000000000000000001',
            ),
          ),
        );
        final changed = await store.get(
          "SELECT * FROM bodyweight_logs WHERE id='null-id'",
        );
        expect(changed['weight_kg'], '83.000000000000000001');
        expect(changed['revision'], 2);
        expect(changed['source_revision_id'], 'source-null-id');
        await expectOriginalsAndAlternatives(store, original);
        final beforeStale = await store.inventory();
        await expectLater(
          repo.commitPrepared(
            repo.prepareMeasurement(
              dateIso: chosen.date,
              selected: chosen,
              kg: const DecimalEvidence(ValueState.valid, '84.00'),
            ),
          ),
          throwsA(isA<StoreException>()),
        );
        expect(await store.inventory(), beforeStale);
        await snapshot(store, 'repository-after-correction-and-stale-refusal');
        for (var reopen = 0; reopen < 2; reopen++) {
          await store.close();
          store = await openDomainStore(root);
          expect(await store.inventory(), beforeStale);
        }
      } finally {
        await store.close();
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'known chart remains usable and latest unavailable weight is not an older current value',
    (tester) async {
      setPhone(tester, width: 412);
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      await harness.open(
        tester,
        seed: (store) => seedMeasurements(store, latestUnavailable: true),
      );
      await tester.pumpWidget(
        harness.wrap(Scaffold(body: BodyweightView(onOpenPicker: () {}))),
      );
      await settleUntilFound(
        tester,
        find.textContaining('Measurement unavailable'),
        where: 'unavailable measurements',
      );
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.series, hasLength(1));
      expect(chart.series.single.value, double.parse(exactKg));
      expect(chart.series.every((e) => e.value.isFinite), isTrue);
      final stats = tester.widgetList<BigStat>(find.byType(BigStat)).toList();
      expect(stats[0].value, '—');
      expect(stats[1].value, '—');
      await scrollIntoView(
        tester,
        find.byType(BodyweightView),
        find.text('2026-10-14 · Measurement unavailable'),
      );
      expect(find.textContaining('Measurement unavailable'), findsNWidgets(4));
      await tester.runAsync(
        () => snapshot(harness.database, 'chart-unavailable'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final id in ['null-id', 'empty-id', 'invalid-id']) {
    testWidgets(
      'chosen $id opens in lb and untouched Save retains exact source evidence',
      (tester) async {
        setPhone(tester, width: 412);
        final harness = ScreenHarness();
        addTearDown(harness.close);
        addTearDown(() => harness.unmount(tester));
        await harness.open(
          tester,
          prefs: {'unit': 'lb'},
          seed: seedMeasurements,
        );
        final selected = (await tester.runAsync(
          () => BodyweightRepository.local(
            harness.database,
          ).onDate(measurementDate),
        ))!.singleWhere((e) => e.id == id);
        final before = (await tester.runAsync(harness.database.inventory))!;
        await tester.pumpWidget(openSheet(harness, selected: selected));
        await tester.runAsync(() => tester.tap(find.text('open')));
        await settleUntilFound(
          tester,
          find.text('Save entry'),
          where: 'chosen unavailable sheet',
        );
        await settleReal(tester, ticks: 10);
        expect(find.text('—'), findsOneWidget);
        await tester.tap(find.text('—'));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await waitForSave(tester);
        final row = (await tester.runAsync(
          () => harness.database.get(
            'SELECT * FROM bodyweight_logs WHERE id=?',
            [id],
          ),
        ))!;
        expect(row['weight_kg'], sourceValues[id]);
        expect(row['source_revision_id'], 'source-$id');
        expect(row['revision'], 2);
        final after = (await tester.runAsync(harness.database.inventory))!;
        expect(after['source_artifacts'], before['source_artifacts']);
        expect(after['source_revisions'], before['source_revisions']);
        expect(
          (after['bodyweight_logs'] as List).cast<Map>().where(
            (r) => r['id'] != id,
          ),
          (before['bodyweight_logs'] as List).cast<Map>().where(
            (r) => r['id'] != id,
          ),
        );
        final operations = (after['operations'] as List).cast<Map>();
        expect(operations, hasLength(1));
        expect(operations.single['target_id'], id);
        await tester.runAsync(
          () => snapshot(harness.database, 'untouched-$id-lb'),
        );
        await harness.unmount(tester);
        await tester.runAsync(
          () => verifyTwoReopens(harness.database, after, 'untouched-$id-lb'),
        );
      },
    );
  }

  testWidgets(
    'duplicate chooser labels unavailable NULL and correction updates only the chosen observed ID',
    (tester) async {
      setPhone(tester, width: 412);
      final harness = ScreenHarness();
      addTearDown(harness.close);
      addTearDown(() => harness.unmount(tester));
      await harness.open(
        tester,
        prefs: {'unit': 'lb'},
        seed: (store) => seedMeasurements(store, date: isoDate(DateTime.now())),
      );
      final before = (await tester.runAsync(harness.database.inventory))!;
      await tester.pumpWidget(openSheet(harness));
      await tester.runAsync(() => tester.tap(find.text('open')));
      await settleUntilFound(
        tester,
        find.textContaining('null-id'),
        where: 'explicit duplicate chooser',
      );
      await settleReal(tester, ticks: 10);
      expect(find.text('Measurement unavailable · null-id'), findsOneWidget);
      await tester.runAsync(
        () => tester.tap(find.text('Measurement unavailable · null-id')),
      );
      await settleUntilFound(
        tester,
        find.text('Save entry'),
        where: 'chosen NULL correction',
      );
      await settleReal(tester, ticks: 10);
      await tester.tap(find.text('—'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '181.7');
      await tester.runAsync(() => tester.tap(find.text('Save entry')));
      await waitForSave(tester);
      final row = (await tester.runAsync(
        () => harness.database.get(
          "SELECT * FROM bodyweight_logs WHERE id='null-id'",
        ),
      ))!;
      expect(
        row['weight_kg'],
        UnitService.toKg(181.7, Unit.lb).toStringAsFixed(2),
      );
      expect(row['revision'], 2);
      await tester.runAsync(
        () => expectOriginalsAndAlternatives(harness.database, before),
      );
      await tester.runAsync(
        () => snapshot(harness.database, 'chosen-null-lb-correction'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late real NULL seed cannot replace a refused prepared correction or prevent identical retry',
    (tester) async {
      setPhone(tester, width: 412);
      final harness = ScreenHarness();
      addTearDown(harness.close);
      await harness.open(tester, prefs: {'unit': 'lb'}, seed: seedMeasurements);
      final chosen = (await tester.runAsync(
        () => BodyweightRepository.local(
          harness.database,
        ).onDate(measurementDate),
      ))!.singleWhere((e) => e.id == 'null-id');
      final before = (await tester.runAsync(harness.database.inventory))!;
      final initialPoolEpoch = harness.database.poolEpoch;
      final gate = (await tester.runAsync(
        () async => SeedGateDatabase(harness.database, beforeCommit: true),
      ))!;
      harness.overrideDatabase = gate;
      try {
        await tester.pumpWidget(openSheet(harness, selected: chosen));
        await tester.runAsync(() => tester.tap(find.text('open')));
        await settleUntilFound(
          tester,
          find.text('Save entry'),
          where: 'gated NULL sheet',
        );
        final realRows = (await tester.runAsync(
          () => gate.received.future.timeout(const Duration(seconds: 5)),
        ))!;
        expect(
          realRows.singleWhere((r) => r['id'] == 'null-id')['weight_kg'],
          isNull,
        );
        expect(realRows.map((r) => r['id']).toSet(), sourceValues.keys.toSet());
        await settleReal(
          tester,
          ticks: 10,
        ); // Modal only: real seed stays gated.
        await tester.tap(find.text('—'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '181.7');
        await tester.runAsync(
          () => snapshot(harness.database, 'seed-retry-before'),
        );
        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        await tester.runAsync(
          () => gate.firstApplyFinished.future.timeout(
            const Duration(seconds: 5),
          ),
        );
        await observeDialog(tester, harness.database);
        expect(gate.actions, hasLength(1));
        final first = gate.actions.single;
        expect(first.target.id, 'null-id');
        expect(first.baseLocalRevision, 1);
        expect(harness.database.poolEpoch, greaterThan(initialPoolEpoch));
        expect(await tester.runAsync(harness.database.inventory), before);
        await tester.runAsync(
          () => snapshot(harness.database, 'seed-retry-refused'),
        );
        expect(find.text('181.7'), findsOneWidget);
        await tester.runAsync(() async {
          gate.release.complete();
        });
        await settleReal(tester, ticks: 3);
        await tester.runAsync(
          () => seedTrace('seed-retry-after-late-seed', gate, tester),
        );
        final requestedAfterSeed = find.text('181.7').evaluate().isNotEmpty;
        await tester.tap(find.text('OK'));
        await settleReal(tester, ticks: 3);
        await tester.runAsync(() => tester.tap(find.text('Save entry')));
        try {
          await waitForSave(tester);
        } finally {
          await tester.runAsync(
            () => seedTrace('seed-retry-after-retry', gate, tester),
          );
          await tester.runAsync(
            () => snapshot(harness.database, 'seed-retry-after-retry'),
          );
        }
        expect(requestedAfterSeed, isTrue);
        expect(gate.actions, hasLength(2));
        expect(gate.actions[1].bytes, first.bytes);
        expect(gate.actions[1].hash, first.hash);
        expect(gate.actions[1].operationId, first.operationId);
        expect(
          gate.expectedTokens[1]?.profileId,
          gate.expectedTokens[0]?.profileId,
        );
        expect(
          gate.expectedTokens[1]?.generation,
          gate.expectedTokens[0]?.generation,
        );
        expect(
          gate.trace.where((e) => e.contains('_refused:')).single,
          contains('FOREIGN KEY'),
        );
        final after = (await tester.runAsync(harness.database.inventory))!;
        final operations = (after['operations'] as List).cast<Map>();
        expect(operations, hasLength(1));
        expect(operations.single['input_bytes'], first.bytes);
        final rows = (after['bodyweight_logs'] as List).cast<Map>();
        final updated = rows.singleWhere((r) => r['id'] == 'null-id');
        expect(
          updated['weight_kg'],
          UnitService.toKg(181.7, Unit.lb).toStringAsFixed(2),
        );
        expect(updated['revision'], 2);
        await tester.runAsync(
          () => expectOriginalsAndAlternatives(harness.database, before),
        );
        expect(tester.takeException(), isNull);
        await harness.unmount(tester);
        await tester.runAsync(
          () => verifyTwoReopens(harness.database, after, 'seed-retry-final'),
        );
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
        await harness.unmount(tester);
      }
    },
  );

  for (final focused in [false, true]) {
    testWidgets(
      'late real seed preserves ${focused ? 'focused' : 'committed'} correction before first Save',
      (tester) async {
        setPhone(tester, width: 412);
        final harness = ScreenHarness();
        addTearDown(harness.close);
        await harness.open(
          tester,
          prefs: {'unit': 'lb'},
          seed: seedMeasurements,
        );
        final selected = (await tester.runAsync(
          () => BodyweightRepository.local(
            harness.database,
          ).onDate(measurementDate),
        ))!.singleWhere((e) => e.id == 'null-id');
        final before = (await tester.runAsync(harness.database.inventory))!;
        final gate = (await tester.runAsync(
          () async => SeedGateDatabase(harness.database),
        ))!;
        harness.overrideDatabase = gate;
        try {
          await tester.pumpWidget(openSheet(harness, selected: selected));
          await tester.runAsync(() => tester.tap(find.text('open')));
          await settleUntilFound(
            tester,
            find.text('Save entry'),
            where: 'gated authored sheet',
          );
          await tester.runAsync(
            () => gate.received.future.timeout(const Duration(seconds: 5)),
          );
          await settleReal(tester, ticks: 10);
          await tester.tap(find.text('—'));
          await tester.pump();
          await tester.enterText(find.byType(TextField), '181.7');
          if (!focused) {
            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pump();
          }
          await tester.runAsync(() async {
            gate.release.complete();
          });
          await settleReal(tester, ticks: 3);
          if (focused) {
            expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              '181.7',
            );
          } else {
            expect(find.text('181.7'), findsOneWidget);
          }
          expect(gate.actions, isEmpty);
          expect(await tester.runAsync(harness.database.inventory), before);
          await tester.runAsync(
            () => seedTrace('seed-before-save-$focused', gate, tester),
          );
          await tester.runAsync(() => tester.tap(find.text('Save entry')));
          await waitForSave(tester);
          final after = (await tester.runAsync(harness.database.inventory))!;
          expect(gate.actions, hasLength(1));
          expect((after['operations'] as List), hasLength(1));
          final row = (after['bodyweight_logs'] as List)
              .cast<Map>()
              .singleWhere((r) => r['id'] == 'null-id');
          expect(
            row['weight_kg'],
            UnitService.toKg(181.7, Unit.lb).toStringAsFixed(2),
          );
          await tester.runAsync(
            () => expectOriginalsAndAlternatives(harness.database, before),
          );
          await tester.runAsync(
            () => snapshot(harness.database, 'seed-before-save-$focused-final'),
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!gate.release.isCompleted) gate.release.complete();
          await harness.unmount(tester);
        }
      },
    );
  }
}
