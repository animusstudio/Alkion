import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/l10n/app_localizations.dart';

void main() {
  // Flutter falls back to the first supported locale, and gen_l10n sorts
  // them alphabetically unless told otherwise: "System default" on a device
  // with no app language showed German while the notifications were English.
  test('English is the first supported locale', () {
    expect(AppLocalizations.supportedLocales.first, const Locale('en'));
  });

  test('a device with no supported language falls back to English', () {
    expect(
      basicLocaleListResolution(const [
        Locale('fr', 'FR'),
      ], AppLocalizations.supportedLocales),
      const Locale('en'),
    );
  });
}
