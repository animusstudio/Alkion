import 'package:alkion/data/bodyweight_repository.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/historical_measurements.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'import_test.dart' show domainRow, localId;
import 'transfer_harness.dart';

const seams = 'full-historical-seams-synthetic-v1.json';
const ns = 'seams';

Map<String, Object?> stableFields(Map<String, dynamic> row) =>
    Map<String, Object?>.from(row)
      ..remove('revision')
      ..remove('deleted')
      ..remove('weight_kg');

void main() {
  test(
    'historical measurement null/missing/empty/invalid raw date: selected-ID edit/delete/restore never touches the date',
    () async {
      final h = await TransferHarness.open('seam-measurement');
      try {
        final db = h.store;
        expect(
          (await TransferService(
            db,
          ).importArtifact(fixture(seams), namespace: ns)).status,
          ImportStatus.selected,
        );
        final actions = HistoricalMeasurementActions(db);
        final entries = await actions.unavailableDateEntries();
        final expectedDates = <String, Object?>{
          'bw-missing-date': null,
          'bw-null-date': null,
          'bw-empty-date': '',
          'bw-rolled-date': '2026-02-30',
          'bw-number-date': '20261015',
        };
        final ids = {
          for (final e in expectedDates.keys)
            await localId(db, ns, 'bodyweight_logs', e): e,
        };
        expect(
          entries.map((e) => ids[e['id']]).toSet(),
          expectedDates.keys.toSet(),
        );
        // The retained repository stays strict and offers no guessed date.
        final repo = BodyweightRepository.local(db);
        final visible = await repo.watchSeriesAsc().first;
        expect(visible.where((e) => !e.dateAvailable), hasLength(5));
        expect(
          () => repo.prepareMeasurement(
            dateIso: '2026-02-30',
            kg: DecimalEvidence(ValueState.valid, '81.0'),
          ),
          throwsA(isA<FormatException>()),
        );
        final sources = await db.getAll(
          'SELECT * FROM source_revisions WHERE profile_id=? ORDER BY source_revision_id',
          [db.profileId],
        );
        for (final MapEntry(key: id, value: external) in ids.entries) {
          final original = await db.get(
            'SELECT * FROM bodyweight_logs WHERE profile_id=? AND id=?',
            [db.profileId, id],
          );
          expect(original['date'], expectedDates[external], reason: external);
          final edit = actions.prepare(
            selectedId: id,
            observedRevision: 1,
            action: LocalActionKind.bodyweightEdit,
            weightKg: ExactDecimal.parse('81.005000'),
          );
          await actions.commit(edit);
          expect((await actions.commit(edit)).replayed, isTrue);
          await expectLater(
            actions.commit(
              actions.prepare(
                selectedId: id,
                observedRevision: 1,
                action: LocalActionKind.bodyweightDelete,
              ),
            ),
            throwsA(
              isA<StoreException>().having(
                (e) => e.category,
                'c',
                'revision_conflict',
              ),
            ),
          );
          await actions.commit(
            actions.prepare(
              selectedId: id,
              observedRevision: 2,
              action: LocalActionKind.bodyweightDelete,
            ),
          );
          final deleted = await db.get(
            'SELECT * FROM bodyweight_logs WHERE profile_id=? AND id=?',
            [db.profileId, id],
          );
          expect(deleted['deleted'], 1);
          expect(deleted['date'], expectedDates[external]);
          await actions.commit(
            actions.prepare(
              selectedId: id,
              observedRevision: 3,
              action: LocalActionKind.bodyweightRestore,
            ),
          );
          final restored = await db.get(
            'SELECT * FROM bodyweight_logs WHERE profile_id=? AND id=?',
            [db.profileId, id],
          );
          expect(restored['revision'], 4);
          expect(restored['deleted'], 0);
          expect(restored['weight_kg'], '81.005000');
          expect(stableFields(restored), stableFields(original));
          expect(
            restored['source_revision_id'],
            original['source_revision_id'],
          );
        }
        final valid = await localId(db, ns, 'bodyweight_logs', 'bw-valid');
        await expectLater(
          actions.commit(
            actions.prepare(
              selectedId: valid,
              observedRevision: 1,
              action: LocalActionKind.bodyweightEdit,
              weightKg: ExactDecimal.parse('1'),
            ),
          ),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'c',
              'qualified_date_uses_measurement_repository',
            ),
          ),
        );
        expect(
          await db.getAll(
            'SELECT * FROM source_revisions WHERE profile_id=? ORDER BY source_revision_id',
            [db.profileId],
          ),
          sources,
        );
        final ops = await db.getAll(
          "SELECT action FROM operations WHERE profile_id=? AND family='bodyweight' ORDER BY action",
          [db.profileId],
        );
        expect(ops, hasLength(15));
        expect(ops.map((o) => o['action']).toSet(), {
          'bodyweightEdit',
          'bodyweightDelete',
          'bodyweightRestore',
        });
        final inventory = await db.inventory();
        expect(
          inventoryDigest(await h.reopenTwice()),
          inventoryDigest(inventory),
        );
      } finally {
        await h.close();
      }
    },
  );

  test(
    'invalid ordinals and metadata stay byte-identical through retained mutations; coverage is derived, logging continues',
    () async {
      final h = await TransferHarness.open('seam-ordinals');
      try {
        final db = h.store;
        await TransferService(db).importArtifact(fixture(seams), namespace: ns);
        final workout = await localId(db, ns, 'sessions', 'w-ordinals');
        final known = await localId(db, ns, 'exercises', 'ex-known');
        final repo = SessionRepository.local(db);
        final sets = await repo.setsForSession(workout);
        expect(sets, hasLength(5));
        final invalid = sets.where((s) => s.exerciseId == known).toList();
        expect(invalid.map((s) => s.qualifiedSetNumber), everyElement(isNull));
        final coverage = CompatibilityCoverage.sets(sets);
        expect(coverage.total, 5);
        expect(coverage.known, 4);
        expect(coverage.complete, isFalse);
        Future<List<Map<String, dynamic>>> invalidRows() => db.getAll(
          'SELECT * FROM sets WHERE profile_id=? AND exercise_id=? ORDER BY id',
          [db.profileId, known],
        );
        final before = await invalidRows();
        final ordString = await localId(db, ns, 'sets', 'ord-string');
        expect(
          before.singleWhere((r) => r['id'] == ordString)['set_number'],
          '"x"',
        );
        expect(before.where((r) => r['set_number'] is String), hasLength(2));
        final inventory = await db.inventory();
        final ordNull = await localId(db, ns, 'sets', 'ord-null');
        await expectLater(
          repo.commitPrepared(
            repo.prepareHistoryEdit(workout, 1, {
              'mode': 'edit',
              'set': {
                'id': ordNull,
                'base': 1,
                'fields': {'reps': 9},
              },
            }),
          ),
          throwsA(
            isA<StoreException>().having(
              (e) => e.category,
              'c',
              'set_order_review_required',
            ),
          ),
        );
        expect(
          inventoryDigest(await db.inventory()),
          inventoryDigest(inventory),
        );
        final sessionBefore = await db.get(
          'SELECT * FROM sessions WHERE profile_id=? AND id=?',
          [db.profileId, workout],
        );
        // A qualified unrelated group in the same workout is editable; the
        // invalid ordinals, BLOB lexemes and invalid created_at stay untouched.
        final valid = await localId(db, ns, 'sets', 'ord-valid');
        await repo.commitPrepared(
          repo.prepareHistoryEdit(workout, 1, {
            'mode': 'edit',
            'set': {
              'id': valid,
              'base': 1,
              'fields': {'reps': 7},
            },
          }),
        );
        expect(await invalidRows(), before);
        // AC-10: the touched set changed reps only; its exact load text and
        // untouched RIR survive the retained edit.
        final edited = await domainRow(db, ns, 'sets', 'ord-valid');
        expect(edited['reps'], 7);
        expect(edited['weight_kg'], '50.00');
        expect(edited['rir'], 2);
        expect(edited['set_number'], 7);
        final sessionAfter = await db.get(
          'SELECT * FROM sessions WHERE profile_id=? AND id=?',
          [db.profileId, workout],
        );
        expect(sessionAfter['revision'], 2);
        expect(sessionAfter['created_at'], 'yesterday');
        expect(sessionAfter['duration_min'], '"50"');
        expect(stableFields(sessionAfter), stableFields(sessionBefore));
        await repo.commitPrepared(repo.prepareDelete(workout, 2));
        await repo.commitPrepared(
          repo.prepareDelete(workout, 3, restore: true),
        );
        final restored = await db.get(
          'SELECT * FROM sessions WHERE profile_id=? AND id=?',
          [db.profileId, workout],
        );
        expect(stableFields(restored), stableFields(sessionBefore));
        expect(await invalidRows(), before);
        // Unrelated new logging remains usable.
        final draft = SessionDraft(
          templateId: null,
          name: 'Unrelated',
          focus: '',
          startedAt: DateTime.utc(2026, 10, 15, 10),
          blocks: [],
        );
        await commitWorkflowState(
          db,
          PreparedWorkflowState(db, draft.toJson(), {
            'draftId': draft.draftId,
            'restTotal': 0,
          }, 0),
        );
        final writer = WorkoutRepository.local(db);
        await writer.commitPrepared(
          writer.prepareFinish(
            write: SessionWrite(
              id: 'native-workout',
              dateIso: '2026-10-15',
              sets: [
                SetWrite(
                  id: 'native-set',
                  exerciseId: await localId(db, ns, 'exercises', 'ex-other'),
                  setNumber: 1,
                  weightKg: '55.0000',
                  reps: 5,
                  rir: null,
                  isWarmup: false,
                ),
              ],
            ),
            baseRevision: 0,
            setBases: {},
            recovery: FinishedSession(
              sessionId: 'native-workout',
              sessionDate: '2026-10-15',
              finishedAt: DateTime.utc(2026, 10, 15, 10, 1),
              elapsedSeconds: 60,
              draft: draft,
            ).toJson(),
            draftRevision: 1,
            draftId: draft.draftId,
          ),
        );
        expect(await invalidRows(), before);
        final settled = await db.inventory();
        expect(
          inventoryDigest(await h.reopenTwice()),
          inventoryDigest(settled),
        );
      } finally {
        await h.close();
      }
    },
  );

  test(
    'exact values, source times and captured flags survive; Last availability stays typed',
    () async {
      final h = await TransferHarness.open('seam-last');
      try {
        final db = h.store;
        await TransferService(db).importArtifact(fixture(seams), namespace: ns);
        final repo = SessionRepository.local(db);
        final known = await localId(db, ns, 'exercises', 'ex-known');
        final last = await repo.lastTopSetEvidence(known);
        expect(last.unavailable, isFalse);
        expect(last.value!.weight, 100.0);
        expect(last.value!.reps, 3);
        expect(last.value!.date, '2026-05-01');
        final unknown = await repo.lastTopSetEvidence(
          await localId(db, ns, 'exercises', 'ex-unknown-load'),
        );
        expect(unknown.unavailable, isTrue);
        expect(unknown.value, isNull);
        final none = await repo.lastTopSetEvidence(
          await localId(db, ns, 'exercises', 'ex-no-history'),
        );
        expect(none.unavailable, isFalse);
        expect(none.value, isNull);
        final top = await domainRow(db, ns, 'sets', 'known-top');
        expect(top['weight_kg'], '100.0000');
        expect(top['created_at'], '2026-05-01T09:10:00Z');
        final captured = await db.get(
          'SELECT captured_top,captured_pr FROM reps_compat1_captured WHERE profile_id=? AND id=?',
          [db.profileId, top['id']],
        );
        expect(captured, {'captured_top': 1, 'captured_pr': 1});
        final stringFlag = await domainRow(db, ns, 'sets', 'ord-missing');
        expect(stringFlag['is_top_set'], '"1"');
        final loaded = (await repo.setsForSession(
          await localId(db, ns, 'sessions', 'w-ordinals'),
        )).singleWhere((s) => s.id == stringFlag['id']);
        expect(loaded.capturedTop, isNull);
        expect(loaded.isTopSet, isFalse);
        final rolled = await domainRow(db, ns, 'sessions', 'w-rolled');
        expect(rolled['date'], '2026-02-30');
        expect(rolled['created_at'], '2026-05-03T09:00:00');
        final history = await repo.watchSessionStats().first;
        expect(
          history.singleWhere((s) => s.id == rolled['id']).dateAvailable,
          isFalse,
        );
        expect(
          TimeEvidence.fromRow(rolled, 'created_at').kind,
          TimeKind.offsetless,
        );
      } finally {
        await h.close();
      }
    },
  );
}
