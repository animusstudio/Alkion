import 'dart:convert';

import 'package:alkion/domain/evidence.dart';
import 'package:alkion/transfer/full_v1.dart';
import 'package:alkion/transfer/json_span_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reader_test.dart' show rejects;
import 'transfer_harness.dart';

const rich = 'full-rich-synthetic-v1.json';
const seams = 'full-historical-seams-synthetic-v1.json';

SourceRow row(FullV1Document d, String table, String id) =>
    d.rows[table]!.singleWhere((r) => r.externalId == id);

void main() {
  group('envelope', () {
    test('E01 empty seven arrays and settings {} are eligible', () {
      final d = validateFullV1(fixture('full-empty-synthetic-v1.json'));
      expect(d.rowCount, 0);
      expect(d.incompatibilities, isEmpty);
      expect(
        d.settings.values.every((s) => s.state == ValueState.missing),
        isTrue,
      );
      expect(d.exportedAt.state, ValueState.missing);
    });

    test('E02 numeric version one only, original lexeme retained', () {
      for (final v in ['1', '1.0', '1e0', '10e-1', '1.000']) {
        final d = validateFullV1(
          mutate(rich, '"version": 1,', '"version": $v,'),
        );
        expect(d.versionLexeme, v);
      }
      for (final v in [
        '"1"',
        'true',
        'null',
        '2',
        '0.9999999999999999999',
        '1e-400',
        '1.0000000000000000001',
      ]) {
        expect(
          () => validateFullV1(mutate(rich, '"version": 1,', '"version": $v,')),
          rejects('version_unsupported'),
          reason: v,
        );
      }
      expect(
        () => validateFullV1(mutate(rich, '"version": 1,', '')),
        rejects('version_unsupported'),
      );
    });

    test('E03 history, wrong format/kind and non-object roots reject', () {
      expect(
        () =>
            validateFullV1(mutate(rich, '"kind": "full"', '"kind": "history"')),
        rejects('history_kind_rejected'),
      );
      expect(
        () => validateFullV1(mutate(rich, '"kind": "full"', '"kind": "Full"')),
        rejects('kind_unsupported'),
      );
      expect(
        () => validateFullV1(
          mutate(rich, '"format": "reps-export"', '"format": "alkion"'),
        ),
        rejects('format_unsupported'),
      );
      expect(() => validateFullV1(utf8Bytes('[]')), rejects('root_not_object'));
    });

    test('E04/E05 each table required as an array of objects', () {
      for (final table in fullV1Tables.map((t) => t.table)) {
        final text = utf8.decode(fixture('full-empty-synthetic-v1.json'));
        for (final (replacement, category) in [
          ('', 'table_missing'),
          ('"$table":null,', 'table_not_array'),
          ('"$table":{},', 'table_not_array'),
          ('"$table":[null],', 'row_not_object'),
          ('"$table":[1],', 'row_not_object'),
          ('"$table":["x"],', 'row_not_object'),
          ('"$table":[[]],', 'row_not_object'),
        ]) {
          final mutated = text
              .replaceFirst('"$table":[],', replacement)
              .replaceFirst(
                '"$table":[]}',
                '${replacement.isEmpty ? '' : replacement.substring(0, replacement.length - 1)}}',
              );
          final bytes = utf8Bytes(
            replacement.isEmpty ? mutated.replaceFirst(',}', '}') : mutated,
          );
          expect(
            () => validateFullV1(bytes),
            rejects(category),
            reason: '$table $replacement',
          );
        }
      }
    });

    test(
      'E06 settings envelope must be an object; {} has missing coverage',
      () {
        for (final bad in ['null', '[]', '"x"']) {
          expect(
            () => validateFullV1(
              utf8Bytes(
                utf8
                    .decode(fixture('full-empty-synthetic-v1.json'))
                    .replaceFirst('"settings":{}', '"settings":$bad'),
              ),
            ),
            rejects('settings_envelope_invalid'),
          );
        }
        expect(
          () => validateFullV1(
            utf8Bytes(
              utf8
                  .decode(fixture('full-empty-synthetic-v1.json'))
                  .replaceFirst('"settings":{},', ''),
            ),
          ),
          rejects('settings_envelope_invalid'),
        );
      },
    );

    test('E07/E08 settings states and unknown evidence are retained', () {
      final d = validateFullV1(fixture(rich));
      expect(d.settings['locale']!.state, ValueState.nullValue);
      expect(d.settings['unit']!.decoded, 'lb');
      expect(d.settings['rest_compound_seconds']!.decoded, '150');
      expect(d.unknownSettings, ['future_setting']);
      expect(d.unknownDatasets, ['future_dataset']);
      expect(row(d, 'exercises', 'e1').unknownFields, ['future_field']);
      final h = validateFullV1(fixture(seams));
      expect(h.settings['rest_compound_seconds']!.token, JsonKind.string);
      expect(h.settings['accent']!.state, ValueState.missing);
      expect(h.exportedAt.token, JsonKind.number);
    });
  });

  group('identity and references', () {
    test('I01 opaque decoded IDs keep spelling and distinct variants', () {
      final d = validateFullV1(
        mutate(
          rich,
          '{"id": "t2", "muscle": "back", "target_sets": 12}',
          r'{"id": "T1", "muscle": "back", "target_sets": 12}, {"id": " t1", "muscle": "x", "target_sets": 1}, {"id": "t1x", "muscle": "y", "target_sets": 2}',
        ),
      );
      expect(d.rows['muscle_targets']!.map((r) => r.externalId), [
        't1',
        'T1',
        ' t1',
        't1x',
      ]);
      expect(row(d, 'muscle_targets', 't1x').idLexeme, r'"t1x"');
    });

    test('I02 duplicate decoded IDs per kind reject; across kinds allowed', () {
      expect(
        () => validateFullV1(mutate(rich, '{"id": "t2",', r'{"id": "t1",')),
        rejects('duplicate_id'),
      );
      final d = validateFullV1(mutate(rich, '{"id": "t2",', '{"id": "e1",'));
      expect(row(d, 'muscle_targets', 'e1').policy.table, 'muscle_targets');
    });

    test('I03 identity-critical ID states reject without allocation', () {
      for (final bad in [
        '',
        '"id": null,',
        '"id": "",',
        '"id": 1,',
        '"id": true,',
        '"id": {},',
      ]) {
        final bytes = bad.isEmpty
            ? mutate(rich, '{"id": "t2", ', '{')
            : mutate(rich, '"id": "t2",', bad);
        expect(() => validateFullV1(bytes), rejects('id_invalid'), reason: bad);
      }
    });

    test('I06 control-bearing IDs are retained but block selection', () {
      final d = validateFullV1(
        mutate(rich, '{"id": "t2",', r'{"id": "t\u0007",'),
      );
      expect(
        d.incompatibilities.single.reason,
        'control_character_identity_unsupported',
      );
      final long = 'x' * maxSourceIdBytes;
      expect(
        validateFullV1(
          mutate(rich, '{"id": "t2",', '{"id": "$long",'),
        ).rowCount,
        15,
      );
      expect(
        () =>
            validateFullV1(mutate(rich, '{"id": "t2",', '{"id": "${long}y",')),
        rejects('id_invalid'),
      );
      final emoji = validateFullV1(
        mutate(rich, '{"id": "t2",', '{"id": "🏋️‍♀️",'),
      );
      expect(emoji.incompatibilities, isEmpty);
    });

    test('R01 required references: missing, empty, wrong type, dangling', () {
      for (final (from, to, category) in [
        (
          '"session_id": "s1", "exercise_id": "e1", "set_number": 1,',
          '"exercise_id": "e1", "set_number": 1,',
          'reference_missing',
        ),
        (
          '"session_id": "s1", "exercise_id": "e1", "set_number": 1,',
          '"session_id": "", "exercise_id": "e1", "set_number": 1,',
          'reference_missing',
        ),
        (
          '"session_id": "s1", "exercise_id": "e1", "set_number": 1,',
          '"session_id": 1, "exercise_id": "e1", "set_number": 1,',
          'reference_wrong_type',
        ),
        (
          '"session_id": "s1", "exercise_id": "e1", "set_number": 1,',
          '"session_id": "nope", "exercise_id": "e1", "set_number": 1,',
          'reference_broken',
        ),
        (
          '"day_template_id": "d1", "exercise_id": "e1"',
          '"day_template_id": "d1", "exercise_id": "s1"',
          'reference_broken',
        ),
        (
          '"day_template_id": "d1", "exercise_id": "e1"',
          '"day_template_id": null, "exercise_id": "e1"',
          'reference_missing',
        ),
      ]) {
        expect(
          () => validateFullV1(mutate(rich, from, to)),
          rejects(category),
          reason: to,
        );
      }
    });

    test('R02 optional day reference absence states; dangling rejects', () {
      final d = validateFullV1(fixture('full-incomplete-synthetic-v1.json'));
      expect(
        row(d, 'sessions', 'inc-session').fields['day_template_id']!.state,
        ValueState.missing,
      );
      expect(
        row(
          d,
          'sessions',
          'inc-session-empty-day',
        ).fields['day_template_id']!.state,
        ValueState.empty,
      );
      expect(
        row(
          validateFullV1(fixture(rich)),
          'sessions',
          's2',
        ).fields['day_template_id']!.state,
        ValueState.nullValue,
      );
      expect(
        () => validateFullV1(
          mutate(
            rich,
            '"day_template_id": null, "created_at": "2026-03-01',
            '"day_template_id": "gone", "created_at": "2026-03-01',
          ),
        ),
        rejects('reference_broken'),
      );
      expect(
        () => validateFullV1(
          mutate(
            rich,
            '"day_template_id": null, "created_at": "2026-03-01',
            '"day_template_id": 7, "created_at": "2026-03-01',
          ),
        ),
        rejects('reference_wrong_type'),
      );
    });

    test('R03 closure independent of array order', () {
      final text = utf8.decode(fixture(rich));
      final setsAt = text.indexOf('"sets": [');
      final setsEnd = text.indexOf('],\n    "bodyweight_logs"');
      final sets = text.substring(setsAt, setsEnd + 1);
      final reordered = text
          .replaceFirst('$sets,\n', '')
          .replaceFirst('"exercises": [', '$sets,\n    "exercises": [');
      expect(
        reordered.indexOf('"sets"'),
        lessThan(reordered.indexOf('"exercises"')),
      );
      expect(validateFullV1(utf8Bytes(reordered)).rowCount, 15);
    });
  });

  group('field projection policy', () {
    test('N02/N04/N05/N08 exact decimal TEXT and number projections', () {
      final d = validateFullV1(fixture(rich));
      FieldReading w(String id) => row(d, 'sets', id).fields['weight_kg']!;
      expect(w('set1').projected, '80.125000000000000001');
      expect(w('set1').token, JsonKind.string);
      expect(w('set2').projected, '82.5000');
      expect(w('set2').note, 'number_lexeme');
      expect(w('set3').projected, '40.50');
      expect(w('set3').lexeme, '4.050e1');
      expect(w('set4').state, ValueState.empty);
      expect(w('set5').projected, '-0.00');
      final e = validateFullV1(
        mutate(rich, '"weight_kg": 82.5000', '"weight_kg": 1e999999'),
      );
      expect(
        row(e, 'sets', 'set2').fields['weight_kg']!.state,
        ValueState.unavailable,
      );
      expect(row(e, 'sets', 'set2').fields['weight_kg']!.projected, '1e999999');
      final s = validateFullV1(
        mutate(rich, '"weight_kg": 82.5000', '"weight_kg": "4.050e1"'),
      );
      expect(
        row(s, 'sets', 'set2').fields['weight_kg']!.state,
        ValueState.invalid,
      );
      final b = validateFullV1(
        mutate(rich, '"weight_kg": 82.5000', '"weight_kg": true'),
      );
      expect(row(b, 'sets', 'set2').fields['weight_kg']!.projected, 'true');
    });

    test(
      'N09 tolerant integers keep raw invalid lexemes as uncoercible TEXT',
      () {
        final d = validateFullV1(fixture(seams));
        FieldReading f(String id, String field) =>
            row(d, 'sets', id).fields[field]!;
        expect(f('ord-string', 'set_number').projected, '"x"');
        expect(f('ord-string', 'set_number').state, ValueState.invalid);
        expect(f('ord-null', 'set_number').state, ValueState.nullValue);
        expect(f('ord-missing', 'set_number').state, ValueState.missing);
        expect(f('ord-fraction', 'set_number').projected, '"1.5"');
        expect(f('ord-fraction', 'reps').projected, '"10"');
        expect(f('ord-fraction', 'rir').projected, 'false');
        expect(f('ord-fraction', 'is_warmup').projected, 'true');
        expect(f('ord-missing', 'is_top_set').projected, '"1"');
        expect(
          row(d, 'sessions', 'w-ordinals').fields['duration_min']!.projected,
          '"50"',
        );
        expect(f('known-top', 'rir').projected, 1);
        final r = validateFullV1(fixture(rich));
        expect(row(r, 'sets', 'set2').fields['rir']!.projected, 9);
        expect(row(r, 'sets', 'set4').fields['rir']!.projected, -1);
        // Integral number spellings SQLite INTEGER affinity would coerce into
        // a valid-looking integer block selection.
        for (final n in [
          '10.0',
          '1e1',
          '1e0',
          '-0',
          '-0.0',
          '9223372036854775808',
          '1e999999',
        ]) {
          final b = validateFullV1(mutate(rich, '"reps": 10,', '"reps": $n,'));
          expect(
            b.incompatibilities.single.reason,
            'integral_number_spelling_coerced_by_sqlite',
            reason: n,
          );
        }
        // Non-integral numbers survive as invalid quoted-lexeme evidence.
        for (final n in ['1.5', '12.50', '1.25e1', '5e-1', '-0.5']) {
          final b = validateFullV1(mutate(rich, '"reps": 10,', '"reps": $n,'));
          expect(b.incompatibilities, isEmpty, reason: n);
          final reps = row(b, 'sets', 'set3').fields['reps']!;
          expect(reps.state, ValueState.invalid);
          expect(reps.projected, '"$n"');
          expect(reps.lexeme, n);
          expect(reps.token, JsonKind.number);
        }
      },
    );

    test('T01/T02 time text is preserved with its qualification', () {
      final d = validateFullV1(fixture(seams));
      final rolled = row(d, 'sessions', 'w-rolled').fields['date']!;
      expect(rolled.projected, '2026-02-30');
      expect(rolled.state, ValueState.invalid);
      final bw = d.rows['bodyweight_logs']!;
      expect(bw.first.fields['date']!.state, ValueState.missing);
      expect(bw[1].fields['date']!.state, ValueState.nullValue);
      expect(bw[2].fields['date']!.state, ValueState.empty);
      expect(bw[4].fields['date']!.projected, '20261015');
      expect(bw[4].fields['date']!.token, JsonKind.number);
      final r = validateFullV1(fixture(rich));
      expect(row(r, 'sessions', 's1').fields['created_at']!.note, 'offsetless');
      expect(
        row(r, 'day_templates', 'd1').fields['created_at']!.note,
        'offsetInstant',
      );
      expect(row(r, 'sessions', 's1').fields['date']!.note, 'calendarDay');
    });

    test('values the accepted readers cannot represent block selection', () {
      for (final (from, to, field) in [
        ('"compound": 0,', '"compound": null,', 'compound'),
        ('"compound": 0,', '', 'compound'),
        (
          '"position": 1, "is_template": 0, "created_at": "2026-01-03T00:00:00+02:00", "focus"',
          '"position": "1", "is_template": 0, "created_at": "2026-01-03T00:00:00+02:00", "focus"',
          'position',
        ),
        (
          '"muscle": "back", "target_sets": 12',
          '"muscle": "back", "target_sets": null',
          'target_sets',
        ),
        (
          '"muscle": "back", "target_sets": 12',
          '"muscle": "back", "target_sets": 12.0',
          'target_sets',
        ),
        ('"name": "Synthetic Row"', '"name": null', 'name'),
        ('"split_label": "Synthetic Day"', '"split_label": 5', 'split_label'),
        ('"default_rep_low": 5,', '"default_rep_low": "5",', 'default_rep_low'),
      ]) {
        final d = validateFullV1(mutate(rich, from, to));
        expect(
          d.incompatibilities.map((i) => i.field),
          contains(field),
          reason: to,
        );
      }
      expect(validateFullV1(fixture(rich)).incompatibilities, isEmpty);
      expect(validateFullV1(fixture(seams)).incompatibilities, isEmpty);
      expect(
        validateFullV1(
          fixture('full-template-owned-synthetic-v1.json'),
        ).incompatibilities,
        isEmpty,
      );
      expect(
        validateFullV1(
          fixture('full-incomplete-synthetic-v1.json'),
        ).incompatibilities,
        isEmpty,
      );
    });

    test('row bytes are exact spans and digests', () {
      final bytes = fixture(rich);
      final d = validateFullV1(bytes);
      final r = row(d, 'muscle_targets', 't2');
      expect(
        utf8.decode(r.rowBytes),
        '{"id": "t2", "muscle": "back", "target_sets": 12}',
      );
    });
  });
}
