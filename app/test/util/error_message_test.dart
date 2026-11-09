import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/files/document_access.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/store/generation_selection.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/ui/profile_screen.dart' show exportFailureMessage;
import 'package:alkion/util/error_message.dart';

const _locales = ['en', 'it', 'de', 'es'];

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('errorBucket', () {
    const table = <String, ErrorBucket>{
      // Stale or conflict.
      'revision_conflict': ErrorBucket.conflict,
      'observed_revision_required': ErrorBucket.conflict,
      'stale_local_state': ErrorBucket.conflict,
      'stale_catalog_runtime': ErrorBucket.conflict,
      'stale_workload_projection': ErrorBucket.conflict,
      // Recovery required (isStoreRecoveryRefusal), ahead of stale_*.
      'recovery_required': ErrorBucket.recovery,
      'stale_generation': ErrorBucket.recovery,
      'profile_fenced': ErrorBucket.recovery,
      // Busy.
      'notification_action_pending': ErrorBucket.busy,
      'finish_retry_required': ErrorBucket.busy,
      'profile_in_use': ErrorBucket.busy,
      // File problem.
      'backup_destination_exists': ErrorBucket.file,
      'backup_destination_invalid': ErrorBucket.file,
      'export_destination_exists': ErrorBucket.file,
      'export_filename_invalid': ErrorBucket.file,
      'export_verification_failed': ErrorBucket.file,
      // Wrong or foreign backup.
      'foreign_profile': ErrorBucket.foreignBackup,
      'backup_profile_mismatch': ErrorBucket.foreignBackup,
      'backup_foreign_variant': ErrorBucket.foreignBackup,
      'restore_source_changed': ErrorBucket.foreignBackup,
      'restore_target_not_empty': ErrorBucket.foreignBackup,
      'restore_staging_corrupt': ErrorBucket.foreignBackup,
      // Damaged.
      'corrupt_wal_preserved': ErrorBucket.damaged,
      'newer_schema_preserved': ErrorBucket.damaged,
      'malformed_draft_preserved': ErrorBucket.damaged,
      'backup_corrupt': ErrorBucket.damaged,
      'backup_truncated': ErrorBucket.damaged,
      'backup_newer_schema': ErrorBucket.damaged,
      // Too large.
      'backup_resource_limit': ErrorBucket.tooLarge,
      'inspection_resource_limit_preserved': ErrorBucket.tooLarge,
      // Unexpected.
      'not_found': ErrorBucket.unexpected,
      'malformed_value': ErrorBucket.unexpected,
      'a_category_no_build_has_yet': ErrorBucket.unexpected,
    };
    for (final entry in table.entries) {
      test('store ${entry.key} -> ${entry.value.name}', () {
        expect(errorBucket(StoreException(entry.key)), entry.value);
      });
    }

    test('document categories', () {
      expect(
        errorBucket(const DocumentException('document_busy')),
        ErrorBucket.busy,
      );
      expect(
        errorBucket(const DocumentException('document_resource_limit')),
        ErrorBucket.tooLarge,
      );
      for (final category in [
        'document_source_changed',
        'document_readback_mismatch',
        'document_symlink_refused',
        'document_unknown_future_category',
      ]) {
        expect(
          errorBucket(DocumentException(category)),
          ErrorBucket.file,
          reason: category,
        );
      }
    });

    test('generation selection categories', () {
      expect(
        errorBucket(const GenerationSelectionException('restore_interrupted')),
        ErrorBucket.foreignBackup,
      );
      expect(
        errorBucket(
          const GenerationSelectionException('fresh_restore_interrupted'),
        ),
        ErrorBucket.foreignBackup,
      );
      expect(
        errorBucket(
          const GenerationSelectionException('selected_generation_invalid'),
        ),
        ErrorBucket.damaged,
      );
    });

    test('a non-store exception is unexpected', () {
      expect(errorBucket(StateError('x')), ErrorBucket.unexpected);
      expect(errorBucket(Exception('x')), ErrorBucket.unexpected);
      expect(errorBucket('plain string'), ErrorBucket.unexpected);
    });
  });

  group('userMessage', () {
    test('a store error keeps its category only as details', () {
      final m = userMessage(en, const StoreException('revision_conflict'));
      expect(m.bucket, ErrorBucket.conflict);
      expect(m.message, en.errorConflict);
      expect(m.details, 'revision_conflict');
      expect(m.message, isNot(contains('revision_conflict')));
      expect(m.message, isNot(contains('Alkion store')));
    });

    test('recovery uses the unchanged recovery wording', () {
      final m = userMessage(en, const StoreException('recovery_required'));
      expect(m.message, en.alkionStoreRecoveryBody);
    });

    test('an unknown or non-store error never prints its text', () {
      const secret = '/data/user/0/synthetic/private/path.sqlite';
      for (final error in <Object>[
        StateError(secret),
        Exception(secret),
        const FormatException(secret),
      ]) {
        final m = userMessage(en, error);
        expect(m.bucket, ErrorBucket.unexpected);
        expect(m.message, en.errorUnexpected);
        expect(m.details, isNull);
      }
    });

    test('a document error never prints its retained path', () {
      const error = DocumentException(
        'document_readback_mismatch',
        originalPath: '/synthetic/private/original',
      );
      final m = userMessage(en, error);
      expect(m.details, 'document_readback_mismatch');
      expect(m.message, isNot(contains('/synthetic')));
      expect(m.details, isNot(contains('/synthetic')));
    });

    for (final code in _locales) {
      test('every bucket has its own message in $code', () {
        final l = lookupAppLocalizations(Locale(code));
        final samples = <Object>[
          const StoreException('revision_conflict'),
          const StoreException('recovery_required'),
          const StoreException('profile_in_use'),
          const DocumentException('document_source_changed'),
          const StoreException('foreign_profile'),
          const StoreException('backup_corrupt'),
          const StoreException('backup_resource_limit'),
          StateError('x'),
        ];
        final messages = [for (final e in samples) userMessage(l, e).message];
        expect(
          {for (final e in samples) errorBucket(e)}.length,
          ErrorBucket.values.length,
        );
        expect(messages.toSet().length, messages.length);
        for (final message in messages) {
          expect(message.trim(), isNotEmpty);
          expect(message, isNot(contains('_')));
        }
      });
    }
  });

  group('exportFailureMessage', () {
    for (final code in _locales) {
      test('maps store, document and other failures in $code', () {
        final l = lookupAppLocalizations(Locale(code));
        final store = exportFailureMessage(
          l,
          const StoreException('export_verification_failed'),
        );
        expect(store.message, l.alkionDocumentFailureMessage(l.errorFile));
        expect(store.details, 'export_verification_failed');

        final document = exportFailureMessage(
          l,
          const DocumentException(
            'document_readback_mismatch',
            originalPath: '/synthetic/private/original',
          ),
        );
        expect(document.message, l.alkionDocumentFailureMessage(l.errorFile));
        expect(document.message, isNot(contains('document_')));
        expect(document.message, isNot(contains('/synthetic')));
        expect(document.details, 'document_readback_mismatch');

        final other = exportFailureMessage(l, StateError('raw-marker'));
        expect(other.message, l.errorUnexpected);
        expect(other.details, isNull);

        final refusal = exportFailureMessage(
          l,
          const StoreException(
            'compat_export_rir_policy_requires_native_backup',
          ),
        );
        expect(refusal.message, l.trainingCompatExportRefused);
        expect(refusal.details, isNull);
      });
    }
  });
}
