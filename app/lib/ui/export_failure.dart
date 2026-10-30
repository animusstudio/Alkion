import '../l10n/app_localizations.dart';
import '../store/local_store.dart';

/// Compatibility output cannot carry these local semantics. Native backup can.
String? compatibilityExportRefusalMessage(AppLocalizations l, Object error) =>
    error is StoreException &&
        const {
          'compat_export_rir_policy_requires_native_backup',
          'compat_export_day_activation_requires_native_backup',
        }.contains(error.category)
    ? l.trainingCompatExportRefused
    : null;
