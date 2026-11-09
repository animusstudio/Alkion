import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/catalog/catalog_browse.dart';
import 'package:alkion/data/muscles.dart';

import '../support/l10n_harness.dart';

void main() {
  Future<String> resolve(
    WidgetTester tester,
    String key, {
    Locale locale = const Locale('en'),
  }) async {
    late String result;
    await tester.pumpWidget(
      wrapL10n(
        Builder(
          builder: (context) {
            result = localizedMuscle(context, key);
            return const SizedBox.shrink();
          },
        ),
        locale: locale,
      ),
    );
    return result;
  }

  testWidgets('known key resolves to the localized ARB string', (tester) async {
    expect(await resolve(tester, 'chest', locale: const Locale('it')), 'Petto');
    expect(await resolve(tester, 'chest'), 'Chest');
  });

  testWidgets('unknown custom key falls back to the title-cased label', (
    tester,
  ) async {
    expect(
      await resolve(tester, 'pinkies', locale: const Locale('it')),
      'Pinkies',
    );
  });

  testWidgets('the 5 further catalog groups have their own ARB strings', (
    tester,
  ) async {
    expect(
      await resolve(tester, 'forearms', locale: const Locale('it')),
      'Avambracci',
    );
    expect(
      await resolve(tester, 'glutes', locale: const Locale('de')),
      'Gesäß',
    );
    expect(
      await resolve(tester, 'adductors', locale: const Locale('es')),
      'Aductores',
    );
    expect(await resolve(tester, 'core'), 'Core');
    expect(await resolve(tester, 'abductors'), 'Abductors');
  });

  test('the legacy and further groups are exactly the catalog muscles', () {
    expect({
      ...kMuscleLabels.keys,
      ...kCatalogExtraMuscles,
    }, CatalogBrowse.muscleKeys);
    expect(kMuscleLabels.length + kCatalogExtraMuscles.length, 13);
  });

  test('Targets offers 8 legacy, 5 catalog, then stored custom keys', () {
    expect(
      targetMuscleKeys(const ['zeta', 'chest', '', '  ', 'alpha', 'core']),
      [
        ...kMuscleLabels.keys,
        'forearms',
        'glutes',
        'core',
        'adductors',
        'abductors',
        'alpha',
        'zeta',
      ],
    );
  });
}
