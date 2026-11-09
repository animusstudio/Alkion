import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../util/error_message.dart';

/// Compatibility output cannot carry these local semantics. Native backup can.
String? compatibilityExportRefusalMessage(AppLocalizations l, Object error) =>
    error is StoreException &&
        const {
          'compat_export_rir_policy_requires_native_backup',
          'compat_export_day_activation_requires_native_backup',
        }.contains(error.category)
    ? l.trainingCompatExportRefused
    : null;

/// The backup, restore and first-start text for [error]: the [userMessage]
/// with its category as details, except where these screens know a more
/// accurate sentence (an open editor, a running workout, an interrupted
/// restore at either start, a profile that already has data, a staging copy that changed).
/// Never the exception text.
UserMessage recoveryErrorMessage(AppLocalizations l, Object error) {
  final mapped = userMessage(l, error);
  final category = errorCategory(error);
  final specific =
      compatibilityExportRefusalMessage(l, error) ??
      switch (category) {
        'unsaved_editor_input' => l.alkionBackupCloseEditor,
        'workout_active' => l.alkionRestoreWorkoutActive,
        'restore_interrupted' ||
        'fresh_restore_interrupted' => l.alkionRestoreInterruptedError,
        'restore_target_not_empty' => l.alkionRestoreTargetNotEmpty,
        final String c when c.startsWith('restore_staging_') =>
          l.alkionRestoreStagingChanged,
        _ => null,
      };
  return specific == null
      ? mapped
      : UserMessage(mapped.bucket, specific, details: category);
}
