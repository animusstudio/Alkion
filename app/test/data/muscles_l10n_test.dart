import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
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
      await resolve(tester, 'forearms', locale: const Locale('it')),
      'Forearms',
    );
  });
}
