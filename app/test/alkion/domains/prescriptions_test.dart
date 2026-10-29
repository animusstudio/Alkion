import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/export/alkion_exports.dart';
import 'package:alkion/settings/settings_service.dart';
import 'package:alkion/store/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'local_screen_harness.dart';
import 'preferences_retry_test.dart'
    show PreferenceFault, PreferenceFaultDatabase;
import 'prepared_intent_retry_test.dart' show FaultDatabase;

Matcher category(String value) =>
    throwsA(isA<StoreException>().having((e) => e.category, 'category', value));
DayDraft editDraft(DayTemplate day, String name) => DayDraft(
  name: name,
  weekday: day.scheduledWeekday,
  focus: day.focus,
  localRevision: day.localRevision,
  rawFields: day.rawFields,
  changedFields: {'name'},
  slots: [
    for (final slot in day.slots)
      SlotDraft(
        itemId: slot.id,
        exerciseId: slot.exerciseId,
        localRevision: slot.localRevision,
        rawFields: slot.rawFields,
        changedFields: {},
      ),
  ],
);

void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('alkion-prescriptions-');
    store = await openDomainStore(root);
    await seedExercise(store, 'ex', 'Bench', base: '80.125000000000000001');
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test(
    'RIR Off, inherit, explicit and unknown survive untouched edit/reopen and atomic evidence',
    () async {
      final repo = DayTemplateRepository.local(store);
      await repo.saveDay(
        draft: DayDraft(
          name: 'Policies',
          slots: [
            for (final policy in [
              RirPolicy.off,
              RirPolicy.inherit,
              RirPolicy.target,
              'future-policy',
              null,
            ])
              SlotDraft(
                exerciseId: 'ex',
                rirPolicy: policy,
                rirLow: 2,
                rirHigh: 3,
              ),
          ],
        ),
      );
      final first = (await repo.allDays()).single;
      final ex = (await store.getAll(
        'SELECT * FROM exercises',
      )).map(Exercise.fromRow).single;
      final resolved = first.slots.map((s) => resolveSlot(s, ex)).toList();
      expect(resolved[0].rirState, RirTargetState.absent);
      expect((resolved[0].rirLow, resolved[0].rirHigh), (null, null));
      expect((resolved[1].rirLow, resolved[1].rirHigh), (1, 2));
      expect((resolved[2].rirLow, resolved[2].rirHigh), (2, 3));
      expect(resolved[3].rirState, RirTargetState.unavailable);
      expect((resolved[4].rirLow, resolved[4].rirHigh), (2, 3));
      await repo.saveDay(id: first.id, draft: editDraft(first, 'Renamed'));
      expect(
        (await repo.byId(first.id))!.slots.map((s) => s.rirPolicy),
        first.slots.map((s) => s.rirPolicy),
      );
      final revisions = await store.getAll(
        "SELECT payload_bytes FROM record_revisions WHERE kind='trainingSlot'",
      );
      expect(
        revisions.any(
          (r) => utf8
              .decode((r['payload_bytes'] as List).cast<int>())
              .contains('future-policy'),
        ),
        isTrue,
      );
      final before = await store.inventory();
      await store.close();
      store = await openDomainStore(root);
      expect(await store.inventory(), before);
    },
  );

  test(
    'partial/invalid RIR stays unavailable and no unrelated bound or fallback is invented',
    () {
      final ex = Exercise.fromRow({
        'id': 'ex',
        'name': 'Bench',
        'default_rir_low': 1,
        'default_rir_high': 2,
      });
      for (final bounds in [(3, null), (null, 3), (4, 1), (-1, 2), (2, 9)]) {
        final result = resolveSlot(
          Slot(
            exerciseId: 'ex',
            position: 1,
            rirLow: bounds.$1,
            rirHigh: bounds.$2,
          ),
          ex,
        );
        expect(result.rirState, RirTargetState.unavailable);
        expect((result.rirLow, result.rirHigh), (null, null));
      }
      final empty = Exercise.fromRow({'id': 'ex', 'name': 'Bench'});
      expect(
        resolveSlot(const Slot(exerciseId: 'ex', position: 1), empty).rirState,
        RirTargetState.absent,
      );
      expect(
        resolveSlot(
          const Slot(
            exerciseId: 'ex',
            position: 1,
            rirPolicy: RirPolicy.target,
          ),
          empty,
        ).rirState,
        RirTargetState.unavailable,
      );
      final raw = Slot.fromRow({
        'exercise_id': 'ex',
        'target_rir_low': 'unknown',
        'target_rir_high': 2,
      });
      expect(resolveSlot(raw, ex).rirUnavailable, isTrue);
    },
  );

  test(
    'activation is status-only, shares revision conflicts with edits and full order skips inactive',
    () async {
      for (var i = 0; i < 3; i++) {
        await seedDay(
          store,
          'd$i',
          'Day $i',
          position: i + 1,
          weekday: i,
          exerciseIds: ['ex'],
        );
      }
      final repo = DayTemplateRepository.local(store);
      final first = (await repo.byId('d0'))!;
      final staleEdit = repo.prepareDay(
        editDraft(first, 'Stale'),
        id: first.id,
      );
      final before = await store.inventory();
      final intent = repo.prepareSetActive('d0', first.localRevision!, false);
      await repo.commitPrepared(intent);
      expect((await repo.commitPrepared(intent)).replayed, isTrue);
      final after = await store.inventory();
      for (final table in [
        'day_template_items',
        'exercises',
        'sessions',
        'sets',
        'source_artifacts',
        'source_revisions',
      ]) {
        expect(after[table], before[table], reason: table);
      }
      final disabled = (await repo.byId('d0'))!;
      expect(disabled.active, isFalse);
      expect(disabled.scheduledWeekday, first.scheduledWeekday);
      expect(disabled.position, first.position);
      expect(await repo.activeDays(), hasLength(2));
      expect(await repo.watchActiveDays().first, hasLength(2));
      expect(selectNextDay(await repo.allDays(), 'd0')!.id, 'd1');
      expect(selectNextDay(await repo.allDays(), 'd2')!.id, 'd1');
      await expectLater(
        repo.commitPrepared(staleEdit),
        category('revision_conflict'),
      );
      expect(await store.inventory(), after);
      final staleEnable = repo.prepareSetActive(
        'd0',
        disabled.localRevision!,
        true,
      );
      await repo.saveDay(
        id: 'd0',
        draft: editDraft(disabled, 'Edited inactive'),
      );
      expect((await repo.byId('d0'))!.active, isFalse);
      final edited = await store.inventory();
      await expectLater(
        repo.commitPrepared(staleEnable),
        category('revision_conflict'),
      );
      expect(await store.inventory(), edited);
      final latest = (await repo.byId('d0'))!;
      await repo.commitPrepared(
        repo.prepareSetActive('d0', latest.localRevision!, true),
      );
      expect(selectNextDay(await repo.allDays(), 'd2')!.id, 'd0');
      for (final day in await repo.allDays()) {
        await repo.commitPrepared(
          repo.prepareSetActive(day.id, day.localRevision!, false),
        );
      }
      expect(await repo.activeDays(), isEmpty);
      expect(await repo.allDays(), hasLength(3));
      expect(selectNextDay(await repo.allDays(), 'unknown'), isNull);
    },
  );

  for (final afterCommit in [false, true]) {
    test(
      'status retry after ${afterCommit ? 'lost return' : 'deferred COMMIT failure'} reconciles same bytes once',
      () async {
        await seedDay(store, 'day', 'Push', position: 1, exerciseIds: ['ex']);
        final before = await store.inventory();
        final fault = FaultDatabase(
          store,
          beforeCommit: !afterCommit,
          afterCommit: afterCommit,
        );
        final repo = DayTemplateRepository.local(fault);
        final intent = repo.prepareSetActive('day', 1, false);
        await expectLater(repo.commitPrepared(intent), throwsA(anything));
        if (!afterCommit) {
          expect(await store.inventory(), before);
        }
        final result = await repo.commitPrepared(intent);
        expect(result.replayed, afterCommit);
        expect(fault.actions.map((a) => a.hash).toSet(), {intent.action.hash});
        expect(
          (await store.getAll(
            "SELECT * FROM operations WHERE action='planSetActive'",
          )),
          hasLength(1),
        );
        expect(
          (await DayTemplateRepository.local(store).byId('day'))!.active,
          isFalse,
        );
        expect(
          (await store.inventory())['day_template_items'],
          before['day_template_items'],
        );
      },
    );
  }

  test(
    'reordering must retain inactive saved days and their content',
    () async {
      final repo = DayTemplateRepository.local(store);
      await seedDay(store, 'a', 'A', position: 1, exerciseIds: ['ex']);
      await seedDay(store, 'b', 'B', position: 2, exerciseIds: ['ex']);
      await repo.commitPrepared(repo.prepareSetActive('a', 1, false));
      final before = await store.inventory();
      final days = await repo.allDays();
      await expectLater(
        repo.commitPrepared(repo.prepareReorder('b', 1, ['b'], {'b': 1})),
        category('incomplete_aggregate'),
      );
      expect(await store.inventory(), before);
      await repo.commitPrepared(
        repo.prepareReorder(
          'b',
          1,
          ['b', 'a'],
          {for (final d in days) d.id: d.localRevision!},
        ),
      );
      expect((await repo.allDays()).map((d) => d.id), ['b', 'a']);
      expect((await repo.byId('a'))!.active, isFalse);
      expect((await repo.activeDays()).single.id, 'b');
      final after = await store.inventory();
      expect(after['day_template_items'], before['day_template_items']);
    },
  );

  test(
    'unknown flag is retained, excluded from active reads and compatibility export refuses it',
    () async {
      await seedDay(store, 'day', 'Push', position: 1);
      await store.writeTransaction(
        (tx) => tx.execute(
          'UPDATE day_templates SET is_active=7 WHERE profile_id=? AND id=?',
          [tx.profileId, 'day'],
        ),
      );
      final repo = DayTemplateRepository.local(store),
          day = (await DayTemplateRepository.local(store).byId('day'))!;
      expect(day.active, isNull);
      expect(day.isActive, isFalse);
      await repo.saveDay(id: 'day', draft: editDraft(day, 'Untouched status'));
      expect((await repo.byId('day'))!.rawFields['is_active'], 7);
      expect(await repo.activeDays(), isEmpty);
      await expectLater(
        store.readTransaction(
          (tx) =>
              buildCompatTransferExport(tx, exportedAt: '2026-10-29T10:00:00Z'),
        ),
        category('compat_export_day_activation_requires_native_backup'),
      );
    },
  );

  for (final fault in PreferenceFault.values) {
    test(
      'creation preferences preserve unrelated fields, isolate profiles and reconcile ${fault.name}',
      () async {
        await store.writeTransaction(
          (tx) => tx.putLocalState(
            LocalStateKind.semanticSetting,
            'settings',
            localBytes({
              'rest_compound_seconds': 123,
              'profile_name': 'Synthetic',
              'future_key': {'untouched': true},
            }),
            expectedRevision: 0,
          ),
        );
        final settings = SettingsService.local(
          PreferenceFaultDatabase(store, kind: fault),
        );
        await settings.load();
        expect(settings.repEntry, RepEntry.fixed);
        expect(settings.rirControls, RirControls.off);
        await expectLater(
          settings.setRepEntry(RepEntry.range),
          throwsA(anything),
        );
        await expectLater(
          settings.setRirControls(RirControls.show),
          throwsA(anything),
        );
        await settings.flushPersistence();
        final otherRoot = await Directory.systemTemp.createTemp(
          'alkion-preferences-other-',
        );
        final other = await openDomainStore(otherRoot);
        try {
          final untouched = SettingsService.local(other);
          await untouched.load();
          expect(untouched.repEntry, RepEntry.fixed);
          expect(untouched.rirControls, RirControls.off);
          final foreign = DayTemplateRepository.local(other);
          final intent = DayTemplateRepository.local(
            store,
          ).prepareSetActive('foreign', 1, false);
          await expectLater(
            foreign.commitPrepared(intent),
            category('foreign_profile'),
          );
        } finally {
          await other.close();
          await otherRoot.delete(recursive: true);
        }
        await store.close();
        store = await openDomainStore(root);
        final loaded = SettingsService.local(store);
        await loaded.load();
        expect(loaded.repEntry, RepEntry.range);
        expect(loaded.rirControls, RirControls.show);
        expect(loaded.restCompoundSeconds, 123);
        expect(loaded.profileName, 'Synthetic');
        final raw = await store.readTransaction(
          (tx) => tx.localState(LocalStateKind.semanticSetting, 'settings'),
        );
        expect(
          jsonDecode(
            utf8.decode((raw!['payload_bytes'] as List).cast<int>()),
          )['future_key'],
          {'untouched': true},
        );
      },
    );
  }
}
