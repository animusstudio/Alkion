// Pure storage/value models: safe for the plain-Dart recovery tools.
enum RecoveryComparison {
  available,
  unchanged,
  changed,
  acknowledgedMissing,
  uncertainMissing,
}

final class RecoveryTarget {
  const RecoveryTarget(this.dataset, this.id, this.expected);
  final String dataset, id;
  final List<Map<String, dynamic>> expected;
  String get key => '$dataset/$id';
  Map<String, Object?> toJson() => {
    'dataset': dataset,
    'id': id,
    'expected': expected,
  };
  factory RecoveryTarget.fromJson(Map value) => RecoveryTarget(
    value['dataset'] as String,
    value['id'] as String,
    (value['expected'] as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList(),
  );
}

final class RecoveryStage {
  const RecoveryStage(
    this.id,
    this.attachmentId,
    this.generation,
    this.state,
    this.inventory,
    this.comparisons,
  );
  final String id, attachmentId, generation, state;
  final Map<String, dynamic> inventory;
  final Map<String, RecoveryComparison> comparisons;
  List<RecoveryTarget> get targets => (inventory['targets'] as List)
      .map((v) => RecoveryTarget.fromJson(v as Map))
      .toList();
  bool get verified => state == 'verified';
  bool get manualDisposition => inventory['manual_disposition'] == true;
  int count(RecoveryComparison value) =>
      comparisons.values.where((v) => v == value).length;
}

final class RecoveryReviewSnapshot {
  const RecoveryReviewSnapshot({
    required this.required,
    required this.adopted,
    required this.manualDisposition,
    this.canAdopt = false,
    this.stage,
  });
  final bool required, adopted, manualDisposition, canAdopt;
  final RecoveryStage? stage;
}

/// One user-confirmed frozen request, never an allow-old switch. Reusing the
/// journal ID is rejected durably even after a successful response or restart.
final class ReviewedRetryScope {
  const ReviewedRetryScope({
    required this.journalId,
    required this.bindingId,
    required this.sessionId,
    required this.selectionId,
    required this.stageId,
    required this.operationId,
    required this.attemptId,
    required this.requestHash,
    required this.origin,
    required this.generation,
    required this.epoch,
  });
  final String journalId,
      bindingId,
      sessionId,
      selectionId,
      stageId,
      operationId,
      attemptId,
      requestHash,
      origin,
      generation;
  final int epoch;
}
