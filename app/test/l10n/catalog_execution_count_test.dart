import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';

void main() {
  for (final (language, singular, plural) in [
    ('en', '1 execution', '2 executions'),
    ('it', '1 esecuzione', '2 esecuzioni'),
    ('de', '1 Ausführung', '2 Ausführungen'),
    ('es', '1 ejecución', '2 ejecuciones'),
  ]) {
    test('$language execution counts use singular and plural', () {
      final l = lookupAppLocalizations(Locale(language));
      expect(l.catalogMatchingExecutions(1), singular);
      expect(l.catalogMatchingExecutions(2), plural);
    });
  }
}
