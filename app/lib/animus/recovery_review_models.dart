import 'package:flutter/foundation.dart';

import 'recovery_stage_models.dart';
export 'recovery_stage_models.dart';

enum RecoveryReviewIssue {
  connection,
  accessDenied,
  unavailable,
  changed,
  localRecovery,
  unknownHistory,
}

abstract interface class AnimusRecoveryReviewPort implements Listenable {
  bool get busy;
  RecoveryReviewSnapshot? get snapshot;
  RecoveryReviewIssue? get issue;
  bool get reviewedReply;
  Future<void> load();
  Future<void> compare();
  Future<void> adopt(String stageId);
  Future<bool> canRetry(String sessionId);
  Future<ReviewedRetryScope?> prepareRetry(String sessionId);
  Future<void> retryReviewed(ReviewedRetryScope scope);
  Future<void> close();
}
