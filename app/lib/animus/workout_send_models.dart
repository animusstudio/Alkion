import 'package:flutter/foundation.dart';

enum AnimusWorkoutSendStatus {
  ready,
  sending,
  sent,
  uncertain,
  needsReview,
  unsupported,
}

enum AnimusWorkoutSendIssue {
  notConnected,
  differentScope,
  missingTimeEvidence,
  unsupportedWorkout,
  unsupportedDefinition,
  invalidValues,
  capabilityMissing,
  recoveryBlocked,
  accessDenied,
  dependencyFailed,
  network,
  invalidResponse,
  localCommitUncertain,
  readBackFailed,
  cancelled,
  requestTooLarge,
  busy,
}

@immutable
final class AnimusWorkoutSelection {
  const AnimusWorkoutSelection({
    required this.sessionId,
    required this.selectionId,
    required this.exerciseCount,
    required this.setCount,
    required this.exerciseNames,
    required this.status,
    this.issue,
    this.workoutLabel = '',
    this.savedDay = '',
    this.readBackVerified = false,
  });
  final String sessionId, selectionId, workoutLabel, savedDay;
  final int exerciseCount, setCount;
  final List<String> exerciseNames;
  final AnimusWorkoutSendStatus status;
  final AnimusWorkoutSendIssue? issue;
  final bool readBackVerified;
  bool get canRetry =>
      selectionId.isNotEmpty &&
      (status == AnimusWorkoutSendStatus.ready ||
          status == AnimusWorkoutSendStatus.uncertain ||
          status == AnimusWorkoutSendStatus.needsReview ||
          status == AnimusWorkoutSendStatus.sent && !readBackVerified);
  AnimusWorkoutSelection withState(
    AnimusWorkoutSendStatus value,
    AnimusWorkoutSendIssue? reason,
  ) => AnimusWorkoutSelection(
    sessionId: sessionId,
    selectionId: selectionId,
    exerciseCount: exerciseCount,
    setCount: setCount,
    exerciseNames: exerciseNames,
    status: value,
    issue: reason,
    workoutLabel: workoutLabel,
    savedDay: savedDay,
    readBackVerified: readBackVerified,
  );
}

abstract interface class AnimusWorkoutSendPort implements Listenable {
  bool get busy;
  Future<AnimusWorkoutSelection> select(String sessionId);
  Future<AnimusWorkoutSelection?> selectionFor(String sessionId);
  Future<void> send(AnimusWorkoutSelection selection);
  Future<void> close();
}

final class WorkoutUploadBlocked implements Exception {
  const WorkoutUploadBlocked(this.issue);
  final AnimusWorkoutSendIssue issue;
  @override
  String toString() => 'Animus workout upload blocked: ${issue.name}';
}
