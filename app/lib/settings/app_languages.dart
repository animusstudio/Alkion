import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';
import '../widgets/w_action_sheet.dart';

/// The app's languages, each named in its own language (an Italian UI still
/// lists "Deutsch"), in the order the language sheet shows them.
const appLanguages = [
  (code: 'en', name: 'English'),
  (code: 'it', name: 'Italiano'),
  (code: 'de', name: 'Deutsch'),
  (code: 'es', name: 'Español'),
];

/// Asks for the app language, checking [current] (the stored override, null
/// for the system default). Returns a language code, `'system'` for the
/// system default (null already means dismissed), or null on dismiss.
Future<String?> showLanguageSheet(
  BuildContext context, {
  required String? current,
}) {
  final l = AppLocalizations.of(context);
  return showWActionSheet<String>(
    context,
    title: l.settingsLanguage,
    actions: [
      WSheetAction(
        label: l.languageSystem,
        value: 'system',
        selected: current == null,
      ),
      for (final lang in appLanguages)
        WSheetAction(
          label: lang.name,
          value: lang.code,
          labelLocale: Locale(lang.code),
          selected: lang.code == current,
        ),
    ],
  );
}
