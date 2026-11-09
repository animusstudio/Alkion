import '../files/document_access.dart';
import '../l10n/app_localizations.dart';
import '../store/generation_selection.dart';
import '../store/local_store.dart';

/// What went wrong, in the words a user is shown. Several stable store and
/// document categories share one bucket.
enum ErrorBucket {
  /// The row changed since it was read: `revision_conflict`, `stale_*`,
  /// `observed_revision_required`.
  conflict,

  /// The store refused the write until it is recovered
  /// ([isStoreRecoveryRefusal]).
  recovery,

  /// Another step still holds the store or the file.
  busy,

  /// A file could not be read, written or published.
  file,

  /// A backup that belongs to another profile or does not match the restore.
  foreignBackup,

  /// Damaged, unknown or newer data, kept unchanged (`*_preserved`,
  /// `backup_*`).
  damaged,

  /// Over a size or resource limit.
  tooLarge,

  /// Anything else, including errors that are not store errors.
  unexpected,
}

/// A localized user message plus, at most, the stable category it came from.
/// [details] is a short code for a small mono line, never the message.
final class UserMessage {
  const UserMessage(this.bucket, this.message, {this.details});

  final ErrorBucket bucket;
  final String message;
  final String? details;
}

/// The stable category of a store, document or generation-selection error,
/// or null for any other error. Never the exception text, which can carry
/// file paths.
String? errorCategory(Object error) => switch (error) {
  StoreException(:final category) => category,
  DocumentException(:final category) => category,
  GenerationSelectionException(:final category) => category,
  _ => null,
};

/// Whether [error] is a write the store refused before applying it because
/// its admission is closed: it needs recovery, or its generation or profile
/// was fenced.
bool isStoreRecoveryRefusal(Object error) =>
    error is StoreException &&
    const {
      'recovery_required',
      'stale_generation',
      'profile_fenced',
    }.contains(error.category);

const _busy = {
  'notification_action_pending',
  'finish_retry_required',
  'profile_in_use',
  'document_busy',
};

const _foreign = {
  'foreign_profile',
  'backup_profile_mismatch',
  'backup_foreign_variant',
  'fresh_restore_interrupted',
};

const _fileStore = {
  'backup_destination_exists',
  'backup_destination_invalid',
  'export_destination_exists',
  'export_filename_invalid',
  'export_verification_failed',
};

/// The bucket for [error]. Pure: it reads only the error's category.
ErrorBucket errorBucket(Object error) {
  if (isStoreRecoveryRefusal(error)) return ErrorBucket.recovery;
  final category = errorCategory(error);
  if (category == null) return ErrorBucket.unexpected;
  if (category == 'revision_conflict' ||
      category == 'observed_revision_required' ||
      category.startsWith('stale_')) {
    return ErrorBucket.conflict;
  }
  if (_busy.contains(category)) return ErrorBucket.busy;
  if (category.contains('resource_limit')) return ErrorBucket.tooLarge;
  if (_foreign.contains(category) || category.startsWith('restore_')) {
    return ErrorBucket.foreignBackup;
  }
  if (_fileStore.contains(category)) return ErrorBucket.file;
  if (category.endsWith('_preserved') ||
      category.startsWith('backup_') ||
      category.startsWith('selected_generation_')) {
    return ErrorBucket.damaged;
  }
  if (error is DocumentException) return ErrorBucket.file;
  return ErrorBucket.unexpected;
}

/// The localized message for [error] and its category as [UserMessage.details].
/// An unknown or non-store error reads as unexpected and carries no details.
UserMessage userMessage(AppLocalizations l, Object error) {
  final bucket = errorBucket(error);
  final message = switch (bucket) {
    ErrorBucket.conflict => l.errorConflict,
    ErrorBucket.recovery => l.alkionStoreRecoveryBody,
    ErrorBucket.busy => l.errorBusy,
    ErrorBucket.file => l.errorFile,
    ErrorBucket.foreignBackup => l.errorForeignBackup,
    ErrorBucket.damaged => l.errorDamaged,
    ErrorBucket.tooLarge => l.errorTooLarge,
    ErrorBucket.unexpected => l.errorUnexpected,
  };
  return UserMessage(bucket, message, details: errorCategory(error));
}
