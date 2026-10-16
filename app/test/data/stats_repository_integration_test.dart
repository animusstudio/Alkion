import '../support/screen_harness.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/data/stats_repository.dart';

/// [StatsRepository.lastTrainedExerciseId] and
/// [StatsRepository.watchTrainingSummary] against a REAL PowerSync database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FixtureDatabase db;
  late StatsRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('reps-stats');
    db = await FixtureDatabase.open(dir);
    await db.initialize();
    repo = StatsRepository.local(db);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> seedSession(String id, String date) => db.execute(
    'INSERT INTO sessions (id, date, split_label, duration_min) VALUES (?, ?, ?, ?)',
    [id, date, 'Upper A', 40],
  );

  Future<void> seedSet(
    String id,
    String sessionId,
    String exerciseId,
    int n, {
    bool warmup = false,
  }) => db.execute(
    'INSERT INTO sets (id, session_id, exercise_id, set_number, weight_kg, reps, rir, '
    'is_warmup, is_top_set, is_pr) VALUES (?, ?, ?, ?, ?, 5, 1, ?, 0, 0)',
    [id, sessionId, exerciseId, n, '50.00', warmup ? 1 : 0],
  );

  test('no history: returns null', () async {
    expect(await repo.lastTrainedExerciseId(), isNull);
  });

  test('returns the exercise of the most recent working set', () async {
    await seedSession('s1', '2026-09-01');
    await seedSession('s2', '2026-09-10');
    await seedSet('a1', 's1', 'squat', 1);
    await seedSet('b1', 's2', 'bench', 1);
    expect(await repo.lastTrainedExerciseId(), 'bench');
  });

  test(
    'warm-up-only most recent session is skipped in favour of an earlier working set',
    () async {
      await seedSession('s1', '2026-09-01');
      await seedSession('s2', '2026-09-10');
      await seedSet('a1', 's1', 'squat', 1);
      await seedSet('b1', 's2', 'bench', 1, warmup: true);
      expect(await repo.lastTrainedExerciseId(), 'squat');
    },
  );

  test(
    'ties within the same session break on the highest set number',
    () async {
      await seedSession('s1', '2026-09-01');
      await seedSet('a1', 's1', 'squat', 1);
      await seedSet('a2', 's1', 'bench', 2);
      expect(await repo.lastTrainedExerciseId(), 'bench');
    },
  );

  group('watchTrainingSummary', () {
    Future<void> seedDay(String id, int? isTemplate) => db.execute(
      'INSERT INTO day_templates (id, name, position, is_template) '
      'VALUES (?, ?, 0, ?)',
      [id, 'Day $id', isTemplate],
    );

    test('counts only owned days: a template day sits next to its absorbed '
        'copy, and a NULL flag counts as owned', () async {
      await seedDay('tpl', 1);
      await seedDay('copy', 0);
      await seedDay('legacy', null);
      final summary = await repo.watchTrainingSummary().first;
      expect(summary.dayCount, 2);
    });

    test('an empty database emits no date and no days', () async {
      expect(await repo.watchTrainingSummary().first, (
        firstSessionDate: null,
        dayCount: 0,
      ));
    });

    test(
      'sessions inserted out of date order give the earliest date',
      () async {
        await seedSession('s2', '2026-05-02');
        await seedSession('s1', '2026-03-14');
        await seedSession('s3', '2026-04-20');
        final summary = await repo.watchTrainingSummary().first;
        expect(summary.firstSessionDate, '2026-03-14');
      },
    );

    test('one stream can be listened to twice', () async {
      await seedSession('s1', '2026-03-14');
      final stream = repo.watchTrainingSummary();
      final first = await stream.first; // listens, then cancels
      final second = await stream.first; // re-listens
      expect(first.firstSessionDate, '2026-03-14');
      expect(second.firstSessionDate, '2026-03-14');
    });

    // PowerSync also infers both tables from the query plan, so this passes
    // with or without triggerOnTables; it fails if an explicit list leaves
    // day_templates out. The listen can still catch the seeding write's late
    // notification and re-emit the old count first, so skip emissions until
    // the count moves.
    test(
      'a change to day_templates alone re-emits with one more day',
      () async {
        await seedSession('s1', '2026-03-14');
        await seedDay('d1', 0);
        final emissions = StreamIterator(repo.watchTrainingSummary());
        addTearDown(emissions.cancel);
        expect(await emissions.moveNext(), isTrue);
        expect(emissions.current, (
          firstSessionDate: '2026-03-14',
          dayCount: 1,
        ));
        await seedDay('d2', 0);
        do {
          expect(
            await emissions.moveNext().timeout(const Duration(seconds: 5)),
            isTrue,
          );
        } while (emissions.current.dayCount == 1);
        expect(emissions.current, (
          firstSessionDate: '2026-03-14',
          dayCount: 2,
        ));
      },
    );
  });
}
