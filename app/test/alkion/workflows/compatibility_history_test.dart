import 'package:alkion/data/exercise_repository.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/session_writer.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:alkion/util/dates.dart';
import 'package:alkion/util/group_by_week.dart';
import 'package:alkion/widgets/line_chart.dart';
import 'package:alkion/l10n/app_localizations_en.dart';
import 'package:alkion/data/stats_repository.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/data/history_numeric_evidence.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/data/progress_repository.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';

Future<void> archiveOwned(Directory root) async {
  final archive = Platform.environment['ALKION_FIXTURE_ARCHIVE'];
  if (archive != null) {
    final dest = Directory(
      '$archive/${root.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    );
    expect(await dest.exists(), isFalse);
    final files = <String, Object?>{};
    Future<void> copy(Directory from, Directory to) async {
      await to.create(recursive: true);
      await for (final item in from.list(followLinks: false)) {
        final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (item is Directory) {
          await copy(item, Directory('${to.path}/$name'));
        } else if (item is File) {
          final bytes = await item.readAsBytes();
          final target = await item.copy('${to.path}/$name');
          final written = await target.readAsBytes();
          expect(written, bytes);
          files[item.path.substring(root.path.length + 1)] = {
            'bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'verified_archive_sha256': sha256.convert(written).toString(),
          };
        } else {
          throw StateError('Unexpected synthetic fixture artifact');
        }
      }
    }

    await copy(root, dest);
    await File(
      '${dest.path}/archive-verification.json',
    ).writeAsString(jsonEncode(files), flush: true);
  }
  expect(
    root.path.startsWith('${Directory.systemTemp.path}/alkion-workflow-'),
    isTrue,
  );
  await root.delete(recursive: true);
}

Future<void> checkpoint(LocalStore store, Directory root, String name) async {
  await File(
    '${root.path}/$name.inventory.json',
  ).writeAsString(jsonEncode(await store.inventory()), flush: true);
  await store.backupTo('${root.path}/$name.sqlite');
}

Future<void> seed(
  LocalStore store,
  RecordKind kind,
  String id,
  Map<String, Object?> fields,
) => store.writeTransaction((tx) async {
  final ref = LocalRef(tx.profileId, kind, id);
  final revision = await tx.writeRevision(
    ref,
    localBytes(fields),
    layer: 'sourceSelection',
  );
  await tx.putRecord(ref, revision, fields);
});
Future<LocalStore> reopen(AlkionProfile p) => LocalStore.open(
  profile: p,
  expectedProfileId: p.profileId,
  schema: workflowSchemaRegistry(),
);

void main() {
  setUpAll(initializeDateFormatting);
  test(
    'reps-compat/1 keeps captured local and unavailable server distinct; known subtotal and revision-bound order resolution',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-compat-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      try {
        await seed(store, RecordKind.exercise, 'e', {
          'name': 'Synthetic',
          'is_template': 0,
        });
        for (final id in ['a', 'b']) {
          await seed(store, RecordKind.workout, id, {
            'date': '2026-10-14',
            'created_at': null,
            'split_label': id,
          });
          await seed(store, RecordKind.workoutSet, '$id-set', {
            'session_id': id,
            'exercise_id': 'e',
            'set_number': 1,
            'weight_kg': id == 'a' ? '80.125000000000100' : '82.5000',
            'reps': 5,
            'rir': 9,
            'is_warmup': 0,
            'is_top_set': 1,
            'is_pr': id == 'a' ? 1 : 0,
          });
        }
        await seed(store, RecordKind.workoutSet, 'unknown', {
          'session_id': 'a',
          'exercise_id': 'e',
          'set_number': 2,
          'weight_kg': '',
          'reps': 5,
          'rir': null,
          'is_warmup': 0,
          'is_top_set': 0,
          'is_pr': 0,
        });
        final repo = SessionRepository.local(store);
        expect(
          (await ExerciseRepository.local(store).prTopSets())['e'],
          await repo.bestTopSet('e'),
        );
        expect(
          (await repo.watchSessionStats().first).length,
          2,
          reason: 'uncertain history remains readable',
        );
        final a = (await repo.watchSessionStats().first).singleWhere(
          (s) => s.id == 'a',
        );
        expect(a.coverage!.known, 1);
        expect(a.coverage!.total, 2);
        expect(a.coverage!.complete, isFalse);
        expect(a.coverage!.knownSubtotal, 80.1250000000001 * 5);
        // History evidence keeps the exact text: 80.125000000000100 × 5.
        final evidence = a.volumeEvidence!;
        expect((evidence.known, evidence.total), (1, 2));
        expect(
          evidence.knownSum.coefficient * BigInt.from(10).pow(15),
          BigInt.parse('400625000000000500') *
              BigInt.from(10).pow(evidence.knownSum.scale),
        );
        final series = await ProgressRepository.local(
          store,
        ).watchSeriesFor('e').first;
        expect(series.first.coverage!.known, 1);
        expect(series.first.coverage!.total, 2);
        expect(est1rm(80, 5), 93);
        expect(
          (await store.get(
            "SELECT * FROM reps_compat1_captured WHERE id='a-set'",
          ))['captured_pr'],
          1,
        );
        expect(
          (await store.get(
            "SELECT * FROM reps_compat1_legacy_server WHERE id='a-set'",
          ))['server_derivation_available'],
          0,
        );
        HistoryOrderReview? review;
        try {
          await repo.lastTopSet('e');
          fail('affected Last must ask for a choice');
        } on HistoryOrderReview catch (e) {
          review = e;
        }
        expect(
          await repo.lastTopSet('unrelated'),
          isNull,
          reason: 'unrelated logging remains usable',
        );
        await repo.resolveOrder(review, 'a');
        expect((await repo.lastTopSet('e'))!.weight, 80.1250000000001);
        final resolution = await store.get(
          "SELECT * FROM local_state WHERE state_kind='orderResolution'",
        );
        final value =
            jsonDecode(
                  utf8.decode(
                    (resolution['payload_bytes'] as List).cast<int>(),
                  ),
                )
                as Map;
        expect(value['historical_fact'], false);
        final edit = repo.prepareHistoryEdit('a', 1, {
          'mode': 'edit',
          'set': {
            'id': 'a-set',
            'base': 1,
            'fields': {'reps': 6},
          },
        });
        await repo.commitPrepared(edit);
        await expectLater(
          repo.lastTopSet('e'),
          throwsA(isA<HistoryOrderReview>()),
          reason: 'changed input invalidates explicit preference',
        );
        expect(
          (await store.get("SELECT * FROM sets WHERE id='a-set'"))['is_pr'],
          1,
          reason: 'captured source flag retained',
        );
        expect(
          (await ExerciseRepository.local(store).prTopSets())['e'],
          await repo.bestTopSet('e'),
        );
        await checkpoint(store, root, 'compatibility');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), expected);
          expect(
            (await ExerciseRepository.local(store).prTopSets())['e'],
            await SessionRepository.local(store).bestTopSet('e'),
          );
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'invalid null empty and leap-day calendars retain every row, explicit unavailable grouping and no invented chart month or factual recent PR zero',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-invalid-dates-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      try {
        await seed(store, RecordKind.exercise, 'e', {
          'name': 'Synthetic',
          'is_template': 0,
        });
        final days = <String?>[
          null,
          '',
          'not-a-day',
          '2026-02-31',
          '2023-02-29',
          '2024-02-29',
          '2026-10-15',
        ];
        for (var i = 0; i < days.length; i++) {
          await seed(store, RecordKind.workout, 'date-$i', {
            'date': days[i],
            'created_at': i.isEven ? null : '2026-10-15T10:00:00',
            'split_label': 'date-$i',
          });
          await seed(store, RecordKind.workoutSet, 'date-set-$i', {
            'session_id': 'date-$i',
            'exercise_id': 'e',
            'set_number': 1,
            'weight_kg': i == 0 ? 'invalid' : '80.2500',
            'reps': i == 0 ? 'unknown' : 5,
            'rir': i == 0 ? 'unknown' : 9,
            'is_warmup': 0,
            'is_top_set': 1,
            'is_pr': 1,
          });
        }
        final history = await SessionRepository.local(
          store,
        ).watchSessionStats().first;
        expect(history.length, days.length);
        final groups = groupByWeek(history, (HistorySessionRow s) => s.date);
        expect(groups[unavailableCalendarBucket]!.length, 5);
        expect(
          groups.values
              .expand((rows) => rows)
              .map((row) => row.id)
              .toSet()
              .length,
          days.length,
        );
        expect(
          history.singleWhere((s) => s.id == 'date-0').dateEvidence!.state,
          ValueState.nullValue,
        );
        expect(
          history.singleWhere((s) => s.id == 'date-1').dateEvidence!.state,
          ValueState.empty,
        );
        // Invalid load and reps: counted, never a zero contribution.
        expect(
          history.singleWhere((s) => s.id == 'date-0').volumeEvidence!.state,
          HistoryVolumeState.none,
        );
        for (final raw in days.take(5)) {
          expect(qualifiedCalendarDate(raw), isNull);
          expect(fmtMonthYear(raw, 'en'), isNull);
          expect(fmtDate(raw ?? '', 'en'), contains('Date unavailable'));
          expect(
            localizedDaysAgo(AppLocalizationsEn(), raw ?? ''),
            contains('Date unavailable'),
          );
        }
        expect(fmtDate('2024-02-29', 'en'), '29 Feb');
        expect(qualifiedCalendarDate('2024-02-29')!.month, 2);
        expect(
          dateFractions(['2026-02-28', '2026-02-31', '2026-03-02'])[1],
          0.5,
        );
        expect(
          monthLabelPositions(['2026-02-31', 'not-a-day', '2026-13-01']),
          isEmpty,
          reason: 'no invalid month is extracted from unqualified text',
        );
        final stats = StatsRepository.local(store);
        final coverage = await stats.watchDateCoverage().first;
        expect(coverage, (known: 2, total: 7));
        expect(
          await stats
              .watchSetsThisWeek(weekStart: DateTime(2026, 10, 12))
              .first,
          1,
        );
        final prs = await stats.watchRecentPrs(limit: 20).first;
        expect(prs.length, 7);
        expect(
          prs.where((p) => p.date == '').map((p) => p.weight),
          contains(isNull),
          reason: 'invalid load is never factual zero',
        );
        final reader = SessionRepository.local(store);
        await expectLater(
          reader.lastTopSet('e', beforeDate: '2026-10-16'),
          throwsA(isA<HistoryOrderReview>()),
        );
        expect(await reader.lastTopSet('unrelated'), isNull);
        await checkpoint(store, root, 'unavailable-dates');
        final expected = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), expected);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'review F1 strict actual timestamp order and scoped uncertainty survive two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-review-order-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      final observations = <String, Object?>{};
      final cases = <String, (String, String, String)>{
        'invalid': ('not-a-timeZ', '2026-10-15T10:00:00Z', 'review'),
        'date-rollover': (
          '2026-02-31T10:00:00Z',
          '2026-10-15T10:00:00Z',
          'review',
        ),
        'clock-rollover': (
          '2026-10-15T25:00:00Z',
          '2026-10-15T10:00:00Z',
          'review',
        ),
        'offset-invalid': (
          '2026-10-15T10:00:00+99:00',
          '2026-10-15T10:00:00Z',
          'review',
        ),
        'offsetless': ('2026-10-15T11:00:00', '2026-10-15T10:00:00Z', 'review'),
        'same-instant': (
          '2026-10-15T10:00:00Z',
          '2026-10-15T12:00:00+02:00',
          'review',
        ),
        'cross-offset': (
          '2026-10-15T09:00:00-05:00',
          '2026-10-15T12:00:00+02:00',
          'a',
        ),
        'fraction': (
          '2026-10-15T10:00:00.010Z',
          '2026-10-15T10:00:00.009Z',
          'a',
        ),
        'deep-fraction': (
          '2026-10-15T10:00:00.0000000002Z',
          '2026-10-15T10:00:00.0000000001Z',
          'a',
        ),
        'same-fraction': (
          '2026-10-15T10:00:00.10Z',
          '2026-10-15T12:00:00.1000+02:00',
          'review',
        ),
      };
      try {
        for (final entry in cases.entries) {
          final name = entry.key;
          await seed(store, RecordKind.exercise, name, {
            'name': name,
            'is_template': 0,
          });
          for (final which in ['a', 'z']) {
            final id = '$name-$which';
            await seed(store, RecordKind.trainingDay, id, {'name': id});
            await seed(store, RecordKind.workout, id, {
              'date': '2026-10-15',
              'created_at': which == 'a' ? entry.value.$1 : entry.value.$2,
              'day_template_id': id,
              'split_label': id,
            });
            await seed(store, RecordKind.workoutSet, '$id-set', {
              'session_id': id,
              'exercise_id': name,
              'set_number': 1,
              'weight_kg': which == 'a' ? '80.000' : '90.000',
              'reps': 0,
              'is_warmup': 0,
              'is_top_set': 1,
              'is_pr': 0,
            });
          }
          final repo = SessionRepository.local(store);
          String result;
          HistoryOrderReview? lastReview, rotationReview;
          try {
            result = (await repo.lastTopSet(name))!.weight == 80 ? 'a' : 'z';
          } on HistoryOrderReview catch (review) {
            lastReview = review;
            result = 'review';
          }
          // Rotation must be checked against this scenario alone, while preserving all rows.
          await store.writeTransaction((tx) async {
            await tx.execute(
              'UPDATE sessions SET day_template_id=NULL WHERE id NOT IN (?,?)',
              ['$name-a', '$name-z'],
            );
          });
          String rotation;
          try {
            rotation = (await repo.lastDayForRotation()) == '$name-a'
                ? 'a'
                : 'z';
          } on HistoryOrderReview catch (review) {
            rotationReview = review;
            rotation = 'review';
          }
          observations[name] = {
            'last': result,
            'rotation': rotation,
            'expected': entry.value.$3,
          };
          if (name == 'invalid' || name == 'same-instant') {
            expect(lastReview, isNotNull);
            expect(rotationReview, isNotNull);
            final capturedRows = await store.getAll(
              'SELECT * FROM sets ORDER BY id',
            );
            await repo.resolveOrder(lastReview!, '$name-a');
            await repo.resolveOrder(rotationReview!, '$name-a');
            expect((await repo.lastTopSet(name))!.weight, 80);
            expect(await repo.lastDayForRotation(), '$name-a');
            expect(
              await store.getAll('SELECT * FROM sets ORDER BY id'),
              capturedRows,
            );
            await repo.commitPrepared(
              repo.prepareHistoryEdit('$name-a', 1, {
                'mode': 'edit',
                'set': {
                  'id': '$name-a-set',
                  'base': 1,
                  'fields': {'reps': 1},
                },
              }),
            );
            await expectLater(
              repo.lastTopSet(name),
              throwsA(isA<HistoryOrderReview>()),
            );
            await expectLater(
              repo.lastDayForRotation(),
              throwsA(isA<HistoryOrderReview>()),
            );
            expect(
              (await store.get('SELECT * FROM sessions WHERE id=?', [
                '$name-a',
              ]))['created_at'],
              entry.value.$1,
            );
          }
        }
        await File(
          '${root.path}/observations.json',
        ).writeAsString(jsonEncode(observations), flush: true);
        await checkpoint(store, root, 'before-reopen');
        final inventory = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), inventory);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
        for (final entry in observations.entries) {
          final v = entry.value as Map;
          expect(v['last'], v['expected'], reason: '${entry.key} Last');
          expect(v['rotation'], v['expected'], reason: '${entry.key} rotation');
        }
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'review F2 F3 raw reps ordinals and duration keep all real readers usable through two reopens',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-review-numeric-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      final outcomes = <String, Object?>{};
      try {
        for (final entry in {
          'null': null,
          'empty': '',
          'invalid': 'unknown',
          'zero': 0,
        }.entries) {
          final id = entry.key;
          await seed(store, RecordKind.exercise, id, {
            'name': id,
            'is_template': 0,
          });
          await seed(store, RecordKind.workout, id, {
            'date': '2026-10-15',
            'created_at': '2026-10-15T10:00:00Z',
            'duration_min': entry.value,
            'split_label': id,
          });
          await seed(store, RecordKind.workoutSet, '$id-set', {
            'session_id': id,
            'exercise_id': id,
            'set_number': entry.value,
            'weight_kg': '80.0000',
            'reps': entry.value,
            'is_warmup': 0,
            'is_top_set': 1,
            'is_pr': 0,
          });
        }
        final repo = SessionRepository.local(store);
        for (final id in ['null', 'empty', 'invalid', 'zero']) {
          try {
            final last = await repo.lastTopSet(id);
            outcomes['last-$id'] = {'reps': last?.reps};
          } catch (e) {
            outcomes['last-$id'] = {
              'error': e is StoreException
                  ? e.category
                  : e.runtimeType.toString(),
            };
          }
          try {
            outcomes['sets-$id'] = (await repo.setsForSession(
              id,
            )).map((s) => s.id).toList();
          } catch (e) {
            outcomes['sets-$id'] = {'error': e.runtimeType.toString()};
          }
          try {
            outcomes['progress-$id'] = (await ProgressRepository.local(
              store,
            ).watchSeriesFor(id).first).length;
          } catch (e) {
            outcomes['progress-$id'] = {'error': e.runtimeType.toString()};
          }
        }
        try {
          outcomes['history'] = (await repo.watchSessionStats().first)
              .map((s) => s.id)
              .toList();
        } catch (e) {
          outcomes['history'] = {'error': e.runtimeType.toString()};
        }
        try {
          outcomes['recent'] = (await repo.watchRecentSessions().first)
              .map((s) => s.id)
              .toList();
        } catch (e) {
          outcomes['recent'] = {'error': e.runtimeType.toString()};
        }
        await File(
          '${root.path}/observations.json',
        ).writeAsString(jsonEncode(outcomes), flush: true);
        await checkpoint(store, root, 'before-reopen');
        final inventory = await store.inventory();
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), inventory);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
        for (final id in ['null', 'empty', 'invalid']) {
          expect(
            (outcomes['last-$id'] as Map)['error'],
            'baseline_value_unavailable',
            reason: id,
          );
        }
        expect((outcomes['last-zero'] as Map)['reps'], 0);
        for (final id in ['null', 'empty', 'invalid', 'zero']) {
          expect(outcomes['sets-$id'], ['$id-set']);
          expect(outcomes['progress-$id'], 1);
        }
        expect((outcomes['history'] as List).toSet(), {
          'null',
          'empty',
          'invalid',
          'zero',
        });
        expect((outcomes['recent'] as List).toSet(), {
          'null',
          'empty',
          'invalid',
          'zero',
        });
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
  test(
    'F3 affected unknown ordinal actions preserve complete inventory while qualified unrelated logging remains usable',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'alkion-workflow-ordinal-actions-',
      );
      final profile = await AlkionProfile.open(
        supportRoot: Directory('${root.path}/dev.animusstudio.alkion.dev'),
      );
      var store = await reopen(profile);
      try {
        for (final id in ['bad', 'good']) {
          await seed(store, RecordKind.exercise, id, {
            'name': id,
            'is_template': 0,
          });
        }
        await seed(store, RecordKind.workout, 'old', {
          'date': '2026-10-14',
          'created_at': '2026-10-14T10:00:00Z',
        });
        for (final id in ['bad', 'good']) {
          await seed(store, RecordKind.workoutSet, '$id-set', {
            'session_id': 'old',
            'exercise_id': id,
            'set_number': id == 'bad' ? '' : 2,
            'weight_kg': '80.0000000',
            'reps': 5,
            'rir': null,
            'is_warmup': 0,
            'is_top_set': 1,
            'is_pr': 0,
          });
        }
        final repo = SessionRepository.local(store);
        final sets = await repo.setsForSession('old');
        expect(
          sets.singleWhere((s) => s.id == 'bad-set').qualifiedSetNumber,
          isNull,
        );
        expect(
          sets.singleWhere((s) => s.id == 'good-set').qualifiedSetNumber,
          2,
        );
        final before = await store.inventory();
        for (final input in <Map<String, Object?>>[
          {
            'mode': 'edit',
            'set': {
              'id': 'bad-set',
              'base': 1,
              'fields': {'reps': 6},
            },
          },
          {
            'mode': 'add',
            'set': {
              'id': 'new-set',
              'base': 0,
              'exercise_id': 'good',
              'is_warmup': 0,
              'fields': {'weight_kg': '82.5', 'reps': 5, 'rir': null},
            },
          },
        ]) {
          await expectLater(
            repo.commitPrepared(repo.prepareHistoryEdit('old', 1, input)),
            throwsA(
              isA<StoreException>().having(
                (e) => e.category,
                'category',
                'set_order_review_required',
              ),
            ),
          );
          expect(await store.inventory(), before);
        }
        await checkpoint(store, root, 'affected-actions-refused');
        final badRow = await store.get("SELECT * FROM sets WHERE id='bad-set'");
        await repo.commitPrepared(
          repo.prepareHistoryEdit('old', 1, {
            'mode': 'edit',
            'set': {
              'id': 'good-set',
              'base': 1,
              'fields': {'reps': 6},
            },
          }),
        );
        expect(
          await store.get("SELECT * FROM sets WHERE id='bad-set'"),
          badRow,
        );
        final draft = SessionDraft(
          templateId: null,
          name: 'Unrelated logging',
          focus: '',
          startedAt: DateTime.utc(2026, 10, 15, 10),
          blocks: [],
        );
        await commitWorkflowState(
          store,
          PreparedWorkflowState(store, draft.toJson(), {
            'draftId': draft.draftId,
            'restTotal': 0,
          }, 0),
        );
        final writer = WorkoutRepository.local(store);
        await writer.commitPrepared(
          writer.prepareFinish(
            write: const SessionWrite(
              id: 'new-workout',
              dateIso: '2026-10-15',
              sets: [
                SetWrite(
                  id: 'new-good-set',
                  exerciseId: 'good',
                  setNumber: 1,
                  weightKg: '82.5000',
                  reps: 0,
                  rir: null,
                  isWarmup: false,
                ),
              ],
            ),
            baseRevision: 0,
            setBases: {},
            recovery: FinishedSession(
              sessionId: 'new-workout',
              sessionDate: '2026-10-15',
              finishedAt: DateTime.utc(2026, 10, 15, 10, 1),
              elapsedSeconds: 60,
              draft: draft,
            ).toJson(),
            draftRevision: 1,
            draftId: draft.draftId,
          ),
        );
        expect(
          await store.get("SELECT * FROM sets WHERE id='bad-set'"),
          badRow,
        );
        expect(
          (await repo.watchSessionStats().first).map((s) => s.id).toSet(),
          {'old', 'new-workout'},
        );
        expect((await repo.setsForSession('old')).map((s) => s.id).toSet(), {
          'bad-set',
          'good-set',
        });
        final inventory = await store.inventory();
        expect(inventory['operations'], hasLength(2));
        await checkpoint(store, root, 'unrelated-actions-committed');
        await store.close();
        for (var i = 0; i < 2; i++) {
          store = await reopen(profile);
          expect(await store.inventory(), inventory);
          await checkpoint(store, root, 'reopen-$i');
          await store.close();
        }
      } finally {
        await store.close();
        await archiveOwned(root);
      }
    },
  );
}
