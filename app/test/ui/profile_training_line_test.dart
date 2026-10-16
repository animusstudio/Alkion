import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/ui/profile_screen.dart';

void main() {
  setUpAll(() async {
    // DateFormat for non-system locales needs the symbol tables loaded.
    await initializeDateFormatting();
  });

  for (final (code, since, split, oneDay) in [
    ('en', 'Training since Mar 2026', '4-\u2060day split', '1-\u2060day split'),
    (
      'it',
      'Ti alleni da mar 2026',
      'split di 4\u00A0giorni',
      'split di 1\u00A0giorno',
    ),
    (
      'de',
      'Training seit März 2026',
      '4-\u2060Tage-Split',
      '1-\u2060Tag-Split',
    ),
    (
      'es',
      'Entrenando desde mar 2026',
      'rutina de 4\u00A0días',
      'rutina de 1\u00A0día',
    ),
  ]) {
    group('profileTrainingLine ($code)', () {
      final l = lookupAppLocalizations(Locale(code));

      test('both parts, joined by a middle dot', () {
        expect(
          profileTrainingLine(
            l,
            code,
            firstSessionDate: '2026-03-14',
            dayCount: 4,
          ),
          '$since · $split',
        );
      });

      test('a one-day split is singular', () {
        expect(
          profileTrainingLine(
            l,
            code,
            firstSessionDate: '2026-03-14',
            dayCount: 1,
          ),
          '$since · $oneDay',
        );
      });

      test('no training days: "since" alone', () {
        expect(
          profileTrainingLine(
            l,
            code,
            firstSessionDate: '2026-03-14',
            dayCount: 0,
          ),
          since,
        );
        expect(
          profileTrainingLine(l, code, firstSessionDate: '2026-03-14'),
          since,
        );
      });

      test('no workouts: the split alone', () {
        expect(profileTrainingLine(l, code, dayCount: 4), split);
      });

      test('neither part: null, so the line is hidden', () {
        expect(profileTrainingLine(l, code), isNull);
        expect(profileTrainingLine(l, code, dayCount: 0), isNull);
      });

      test('a date that does not parse drops "since"', () {
        expect(
          profileTrainingLine(
            l,
            code,
            firstSessionDate: 'garbage',
            dayCount: 4,
          ),
          split,
        );
        expect(
          profileTrainingLine(l, code, firstSessionDate: '', dayCount: 0),
          isNull,
        );
      });
    });
  }
}
