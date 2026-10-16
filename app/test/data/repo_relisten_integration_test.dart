import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart'
    show openDomainStore, seedExercise;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/data/day_template_repository.dart';
import 'package:alkion/data/exercise_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalStore db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('reps-relisten');
    db = await openDomainStore(dir);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('watchCatalog can be listened to twice', () async {
    await seedExercise(db, 'e1', 'Squat', muscle: 'quads');
    final stream = ExerciseRepository.local(db).watchCatalog();

    final first = await stream.first; // listens, then cancels
    final second = await stream.first; // re-listens — this threw before

    expect(first.length, 1);
    expect(second.length, 1);
  });

  test('watchDays can be listened to twice', () async {
    final stream = DayTemplateRepository.local(db).watchDays();
    await stream.first;
    await stream.first;
  });
}
