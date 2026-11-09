import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/export_failure.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'recovery errors get their own sentences and keep only the category',
    () async {
      for (final code in ['en', 'it', 'de', 'es']) {
        final l = await AppLocalizations.delegate.load(Locale(code));
        final cases = <Object, String>{
          const StoreException('unsaved_editor_input'):
              l.alkionBackupCloseEditor,
          const StoreException('workout_active'): l.alkionRestoreWorkoutActive,
          const GenerationSelectionException('restore_interrupted'):
              l.alkionRestoreInterruptedError,
          const StoreException('fresh_restore_interrupted'):
              l.alkionRestoreInterruptedError,
          const GenerationSelectionException('fresh_restore_interrupted'):
              l.alkionRestoreInterruptedError,
          const StoreException('restore_target_not_empty'):
              l.alkionRestoreTargetNotEmpty,
          const StoreException('restore_staging_changed'):
              l.alkionRestoreStagingChanged,
          const StoreException('restore_staging_corrupt'):
              l.alkionRestoreStagingChanged,
          const StoreException('restore_staging_mismatch'):
              l.alkionRestoreStagingChanged,
          const StoreException('foreign_profile'): l.errorForeignBackup,
          StateError('/synthetic/path'): l.errorUnexpected,
        };
        for (final MapEntry(key: error, value: sentence) in cases.entries) {
          final mapped = recoveryErrorMessage(l, error);
          expect(mapped.message, sentence, reason: '$code $error');
          expect(mapped.message, isNot(contains('_')), reason: '$code $error');
          expect(
            mapped.details,
            error is StateError ? isNull : isNot(contains('/')),
            reason: '$code $error',
          );
        }
      }
    },
  );
}
