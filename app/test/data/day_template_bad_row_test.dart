// Pins the same contract that protects Home's day-rotation stream, but at the
// repository/stream boundary instead of mounting the screen: a widget test
// that mounts TodayScreen over a real PowerSync database leaves pending
// watch-throttle timers behind and hangs the test binding, so it can't be
// used to verify this. Testing directly against DayTemplateRepository gives
// the same coverage — a NULL exercise_id in day_template_items really does
// throw on the stream, and a listener that supplies onError really does
// receive it — without mounting anything.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/store/local_store.dart';
import '../alkion/domains/local_screen_harness.dart'
    show openDomainStore, seedDay;
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:alkion/data/day_template_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalStore db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('reps-day-template-bad-row');
    db = await openDomainStore(dir);
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'watchDays throws on a day_template_items row with a NULL exercise_id',
    () async {
      await seedDay(db, 'd1', 'Lower A', position: 1);
      final action = LocalAction(
        operationId: 'bad-slot',
        target: LocalRef(db.profileId, RecordKind.trainingSlot, 'i1'),
        action: LocalActionKind.slotAdd,
        baseLocalRevision: 0,
        createdAt: OperationInstant.now(),
        input: {},
      );
      await db.apply(action, (tx) async {
        final r = await tx.writeRevision(
          action.target,
          localBytes({'exercise_id': null}),
        );
        await tx.putRecord(action.target, r, {
          'day_template_id': 'd1',
          'exercise_id': null,
          'position': 0,
        });
        return null;
      });

      await expectLater(
        DayTemplateRepository.local(db).watchDays().first,
        throwsA(isA<TypeError>()),
      );
    },
  );

  test(
    'a listener with onError receives the error instead of it escaping',
    () async {
      await seedDay(db, 'd1', 'Lower A', position: 1);
      final action = LocalAction(
        operationId: 'bad-slot',
        target: LocalRef(db.profileId, RecordKind.trainingSlot, 'i1'),
        action: LocalActionKind.slotAdd,
        baseLocalRevision: 0,
        createdAt: OperationInstant.now(),
        input: {},
      );
      await db.apply(action, (tx) async {
        final r = await tx.writeRevision(
          action.target,
          localBytes({'exercise_id': null}),
        );
        await tx.putRecord(action.target, r, {
          'day_template_id': 'd1',
          'exercise_id': null,
          'position': 0,
        });
        return null;
      });

      final completer = Completer<Object>();
      final sub = DayTemplateRepository.local(db).watchDays().listen(
        (_) {},
        onError: (Object e, StackTrace st) {
          if (!completer.isCompleted) completer.complete(e);
        },
      );
      final err = await completer.future;
      expect(err, isA<TypeError>());
      await sub.cancel();
    },
  );
}
