import 'package:alkion/domain/evidence.dart';
import 'package:alkion/domain/local_action.dart';
import 'package:alkion/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'decimal spelling and exact comparison survive display precision loss',
    () {
      final exact = ExactDecimal.parse('80.125000000000000001');
      expect(exact.text, '80.125000000000000001');
      expect(
        exact.compareTo(ExactDecimal.parse('80.125000000000000000')),
        greaterThan(0),
      );
      expect(ExactDecimal.parse('080.1200').text, '080.1200');
      for (final value in [null, '', 'invalid', '90.000000000000000007']) {
        final row = <String, dynamic>{
          'weight_kg': value,
          'id': 'set',
          'exercise_id': 'exercise',
          'rir': 9,
        };
        final display = LoggedSet.fromRow(row);
        expect(display.weightEvidence!.raw, value);
        expect(display.rir, 9);
      }
      expect(DecimalEvidence.fromRow({}, 'weight').state, ValueState.missing);
      expect(
        DecimalEvidence.fromRow({'weight': null}, 'weight').state,
        ValueState.nullValue,
      );
      expect(
        DecimalEvidence.fromRow({'weight': ''}, 'weight').state,
        ValueState.empty,
      );
      expect(
        DecimalEvidence.fromRow({'weight': 'bad'}, 'weight').state,
        ValueState.invalid,
      );
    },
  );
  test('calendar and offsetless source time never become guessed instants', () {
    expect(CalendarDay('2026-10-25').text, '2026-10-25');
    expect(() => CalendarDay('2026-02-30'), throwsFormatException);
    expect(
      TimeEvidence.fromRow({'t': '2026-10-25T02:30:00'}, 't').kind,
      TimeKind.offsetless,
    );
    expect(
      TimeEvidence.fromRow({'t': '2026-10-25T02:30:00+02:00'}, 't').kind,
      TimeKind.offsetInstant,
    );
    for (final raw in [
      '2026-02-30T02:30:00',
      '2026-10-25T25:00:00',
      '2026-10-25T02:99:00',
      '2026-10-25T02:30:99',
      '2026-13-25T02:30:00',
    ]) {
      final evidence = TimeEvidence.fromRow({'t': raw}, 't');
      expect(evidence.kind, TimeKind.invalid);
      expect(evidence.raw, raw);
    }
    expect(
      () => OperationInstant('2026-10-25T02:30:00'),
      throwsFormatException,
    );
    expect(
      () => OperationInstant('2026-02-30T02:30:00Z'),
      throwsFormatException,
    );
  });
  test(
    'typed references and dependencies refuse foreign family before lookup',
    () {
      expect(
        () => LocalAction(
          operationId: 'id',
          target: const LocalRef('profile', RecordKind.exercise, 'record'),
          action: LocalActionKind.bodyweightEdit,
          baseLocalRevision: 0,
          createdAt: OperationInstant('2026-10-13T12:00:00Z'),
          input: {},
        ),
        throwsFormatException,
      );
      expect(
        () => LocalAction(
          operationId: 'id',
          target: const LocalRef('profile', RecordKind.exercise, 'record'),
          action: LocalActionKind.definitionCreate,
          baseLocalRevision: 0,
          createdAt: OperationInstant('2026-10-13T12:00:00Z'),
          input: {},
          dependencies: [
            const OperationDependency(
              'profile',
              GrantFamily.bodyweight,
              'dependency',
            ),
          ],
        ),
        throwsFormatException,
      );
    },
  );
}
