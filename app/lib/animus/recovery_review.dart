import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../store/local_store.dart';
import 'adapters/http.dart';
import 'connection.dart';
import 'config.dart';
import 'contracts.dart';
import 'ports.dart';
import 'probe.dart';
import 'recovery_protocol.dart';
import 'recovery_review_models.dart';
import 'remote_recovery_repository.dart';
import 'workout_send.dart';
import 'workout_upload_repository.dart';

export 'recovery_review_models.dart';

/// Explicit finite comparison, adoption and one exact reviewed request. Its
/// constructor and local inspection never authenticate or contact a server.
final class AnimusRecoveryReview extends ChangeNotifier
    implements AnimusRecoveryReviewPort {
  AnimusRecoveryReview({
    required LocalDatabase database,
    required String installationId,
    required this.connection,
    AnimusUploadHttpPort? http,
    AnimusWorkoutSendPort? sender,
  }) : _sender = sender,
       _repository = RemoteRecoveryRepository(database),
       _uploads = WorkoutUploadRepository(database, installationId),
       _http = http ?? IoAnimusHttpPort() {
    connection.addListener(_connectionChanged);
    _sender?.addListener(_senderChanged);
  }
  final AnimusConnectionController connection;
  final AnimusWorkoutSendPort? _sender;
  final RemoteRecoveryRepository _repository;
  final WorkoutUploadRepository _uploads;
  final AnimusUploadHttpPort _http;
  final _covered = <Future<void>>{};
  bool _busy = false,
      _closed = false,
      _disposed = false,
      _reviewedReply = false;
  Future<void>? _closing;
  RecoveryReviewSnapshot? _snapshot;
  String? _reviewedStage;
  RecoveryReviewIssue? _issue;
  int _loadEpoch = 0;
  @override
  bool get busy => _busy;
  @override
  RecoveryReviewSnapshot? get snapshot => _snapshot;
  @override
  RecoveryReviewIssue? get issue => _issue;
  @override
  bool get reviewedReply =>
      _reviewedReply &&
      _snapshot?.adopted == true &&
      _snapshot?.stage?.id == _reviewedStage;
  void _notify() {
    if (!_closed && !_disposed) notifyListeners();
  }

  void _senderChanged() {
    if (_sender?.busy == false && !_busy) unawaited(load());
  }

  void _connectionChanged() {
    if (!connection.confirmed || connection.identity == null) {
      ++_loadEpoch;
      _snapshot = null;
      _reviewedReply = false;
      _notify();
    } else if (!connection.busy && !_busy) {
      unawaited(load());
    }
  }

  RemoteRecoveryBinding _binding() {
    final config = connection.config, identity = connection.identity;
    if (!connection.confirmed ||
        config == null ||
        identity == null ||
        identity.issuer != config.issuer) {
      throw const AnimusRecoveryFailure();
    }
    return RemoteRecoveryBinding.fromWorkoutBinding(
      workoutBinding(
        _uploads.installationId,
        _uploads.db.token,
        config,
        identity,
      ),
    );
  }

  @override
  Future<void> load() async {
    final epoch = ++_loadEpoch;
    try {
      final binding = _binding(),
          result = await _repository.reviewSnapshot(_binding());
      if (_closed || epoch != _loadEpoch || binding.id != _binding().id) return;
      _snapshot = result;
    } on Object {
      if (!_closed && epoch == _loadEpoch) _snapshot = null;
    }
    _notify();
  }

  Future<void> _run(
    Future<void> Function(
      RemoteRecoveryBinding,
      AnimusAuthSession,
      void Function(),
    )
    work,
  ) async {
    if (_closed || _busy) return;
    _busy = true;
    _issue = null;
    _reviewedReply = false;
    _notify();
    try {
      final binding = _binding(),
          epoch = connection.foregroundEpoch,
          identity = connection.identity!;
      void current() {
        if (_closed ||
            !connection.foregroundCurrent(epoch, identity) ||
            _binding().id != binding.id) {
          throw const AnimusRecoveryFailure();
        }
      }

      final session = await connection.sessionForForeground(epoch);
      current();
      final pending = work(binding, session, current);
      late final Future<void> settled;
      settled = pending.then<void>(
        (_) => _covered.remove(settled),
        onError: (Object error, StackTrace stack) {
          _covered.remove(settled);
        },
      );
      _covered.add(settled);
      await pending;
      current();
    } on _ReviewDenied {
      _issue = RecoveryReviewIssue.accessDenied;
    } on StoreException catch (error) {
      _issue = error.category == 'remote_attachment_mismatch'
          ? RecoveryReviewIssue.connection
          : RecoveryReviewIssue.localRecovery;
    } on Object {
      _issue = RecoveryReviewIssue.unavailable;
    } finally {
      _busy = false;
      if (!_closed) await load();
      _notify();
    }
  }

  Map<String, String> _headers(
    AnimusAuthSession session, [
    String? generation,
  ]) => {
    'Authorization': 'Bearer ${session.accessToken}',
    'Accept': 'application/json',
    AnimusDefinitionReadContract.admissionHeader:
        connection.config!.readAdmission,
    if (generation != null) recoveryGenerationHeader: generation,
  };
  Future<AnimusHttpResponse> _get(
    AnimusAuthSession session,
    List<String> path, [
    String? generation,
  ]) => _http.get(
    uri: connection.config!.apiOrigin.replace(pathSegments: path),
    headers: _headers(session, generation),
    maxResponseBytes: path.length == 3 ? 64 * 1024 : 8 * 1024 * 1024,
    timeout: const Duration(seconds: 20),
  );
  Future<void> _stop(
    RemoteExchange exchange,
    AnimusHttpResponse? response, [
    String? stageId,
  ]) async {
    if (stageId != null) {
      try {
        await _repository.invalidateStage(stageId);
      } on Object {
        /* Preserve the prior stage. */
      }
    }
    try {
      await _repository.fence(exchange.attachmentId);
    } on Object {
      /* Pre-I/O intent remains the independent gate. */
    }
    if (response != null) {
      String? generation;
      try {
        generation = recoveryResponseGeneration(response);
      } on Object {
        /* Retain malformed G as unknown. */
      }
      try {
        await _repository.appendResponse(
          exchange,
          status: response.statusCode,
          generation: generation,
          body: response.body,
        );
      } on Object {
        /* Never write through a fenced local handle. */
      }
    }
    try {
      await _repository.capture(exchange.attachmentId);
    } on Object {
      /* Capture failure cannot reopen remote work. */
    }
  }

  String _discovery(AnimusHttpResponse response) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const _ReviewDenied();
    }
    final generation = requireRecoveryDiscovery(response);
    requireNativeWorkoutCapability(response);
    return generation;
  }

  void _read(
    AnimusHttpResponse response,
    RecoveryTarget target,
    String generation,
  ) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const _ReviewDenied();
    }
    if (recoveryResponseGeneration(response) != generation) {
      throw const AnimusRecoveryFailure();
    }
    final object = recoveryResponseObject(response);
    if (isRecoveryResponseError(object['error'])) {
      throw const AnimusRecoveryFailure();
    }
    if (response.statusCode == 404) {
      if (object['error'] != 'not_found') {
        throw const FormatException('Unclassified absence');
      }
      return;
    }
    if (response.statusCode != 200) throw const AnimusRecoveryFailure();
    final kind = target.dataset == 'definitions' ? 'exercise' : 'workout',
        member = target.dataset == 'definitions' ? 'definition' : 'workout';
    final body = object[member];
    if (object['kind'] != kind ||
        AnimusDefinitionReadContract.recordMembers.any(
          (known) => known != member && object.containsKey(known),
        ) ||
        body is! Map ||
        body['ref'] is! Map ||
        (body['ref'] as Map)['kind'] != kind ||
        (body['ref'] as Map)['id'] != target.id ||
        body['revision'] is! int ||
        (body['revision'] as int) < 1 ||
        body['field_attribution'] is! Map) {
      throw const FormatException('Invalid current record');
    }
    if (target.dataset == 'definitions' &&
            !validRecoveryDefinition(response, target.id) ||
        !validRecoverySharedMetadata(Map<String, Object?>.from(body))) {
      throw const FormatException('Invalid shared metadata');
    }
    if (target.dataset == 'workouts') {
      if (body['reference_bases'] is! List) {
        throw const FormatException('Missing definition closure');
      }
      for (final base in body['reference_bases'] as List) {
        if (base is! Map ||
            base['target'] is! Map ||
            (base['target'] as Map)['kind'] != 'exercise' ||
            !isCanonicalAnimusUuid(
              (base['target'] as Map)['id'] as String? ?? '',
            ) ||
            base['revision'] is! int ||
            (base['revision'] as int) < 1) {
          throw const FormatException('Invalid definition closure');
        }
      }
    }
  }

  @override
  Future<void> compare() => _run((binding, session, current) async {
    final state = await _repository.state(binding.id);
    if (state.state == 'capture_pending') await _repository.capture(binding.id);
    RemoteExchange? discovery;
    AnimusHttpResponse? response;
    RecoveryStage? stage;
    try {
      discovery = await _repository.beginReviewDiscovery(binding, current);
      current();
      response = await _get(session, ['v1', 'system', 'info']);
      current();
      final generation = _discovery(response);
      stage = await _repository.startStage(
        binding,
        discovery,
        generation: generation,
        probeId: connection.config!.probeRecordId,
        body: response.body,
        current: current,
      );
    } on Object {
      if (discovery != null) await _stop(discovery, response);
      rethrow;
    }
    final completed = <String>{};
    var totalBytes = 0;
    while (true) {
      final remaining = stage!.targets.where((v) => !completed.contains(v.key));
      if (remaining.isEmpty) break;
      final target = remaining.first;
      RemoteExchange? exchange;
      AnimusHttpResponse? received;
      try {
        exchange = await _repository.beginStageRead(stage.id, target, current);
        current();
        received = await _get(session, [
          'v1',
          'data-spaces',
          connection.config!.dataSpaceId,
          'training',
          target.dataset,
          target.id,
        ], stage.generation);
        current();
        _read(received, target, stage.generation);
        totalBytes += received.body.length;
        if (totalBytes > 64 * 1024 * 1024) throw const AnimusRecoveryFailure();
        stage = await _repository.finishStageRead(
          stage.id,
          exchange,
          target,
          status: received.statusCode,
          body: received.body,
          generation: stage.generation,
          current: current,
        );
        completed.add(target.key);
      } on Object {
        if (exchange != null) await _stop(exchange, received, stage!.id);
        rethrow;
      }
    }
    await _repository.verifyStage(stage.id, current);
  });
  @override
  Future<void> adopt(String stageId) => _run((binding, session, current) async {
    final snapshot = await _repository.reviewSnapshot(binding),
        stage = snapshot?.stage;
    if (stage == null || stage.id != stageId || !stage.verified) {
      throw const AnimusRecoveryFailure();
    }
    RemoteExchange? discovery;
    AnimusHttpResponse? response;
    try {
      discovery = await _repository.beginAdoptionDiscovery(stageId, current);
      current();
      response = await _get(session, ['v1', 'system', 'info']);
      current();
      final generation = _discovery(response);
      if (generation != stage.generation) throw const AnimusRecoveryFailure();
      await _repository.settleAdoptionDiscovery(
        stageId,
        discovery,
        generation,
        response.body,
        current,
      );
    } on Object {
      if (discovery != null) await _stop(discovery, response, stageId);
      rethrow;
    }
    // Recheck current admission for every dataset represented in the finite view.
    for (final dataset in stage.targets.map((v) => v.dataset).toSet()) {
      final target = stage.targets.firstWhere((v) => v.dataset == dataset);
      RemoteExchange? exchange;
      AnimusHttpResponse? received;
      try {
        exchange = await _repository.beginStageRead(
          stageId,
          target,
          current,
          adoption: true,
        );
        current();
        received = await _get(session, [
          'v1',
          'data-spaces',
          connection.config!.dataSpaceId,
          'training',
          target.dataset,
          target.id,
        ], stage.generation);
        current();
        _read(received, target, stage.generation);
        await _repository.finishStageRead(
          stageId,
          exchange,
          target,
          status: received.statusCode,
          body: received.body,
          generation: stage.generation,
          current: current,
          adoption: true,
        );
      } on Object {
        if (exchange != null) await _stop(exchange, received, stageId);
        rethrow;
      }
    }
    try {
      await _repository.adoptStage(stageId, stage.generation, current);
    } on Object {
      throw const StoreException('remote_adoption_uncertain');
    }
  });
  Future<WorkoutUploadAttempt?> _retryAttempt(
    String sessionId,
    RemoteRecoveryBinding binding,
  ) async {
    final selected = await _uploads.load(sessionId);
    if (selected == null ||
        RemoteRecoveryBinding.fromWorkoutBinding(selected.binding).id !=
            binding.id) {
      return null;
    }
    final operations = [
      for (final definition in selected.definitions)
        for (final raw in definition['chain'] as List)
          ((raw as Map)['action'] as Map)['operation_id'] as String,
      selected.operationId,
    ];
    WorkoutUploadAttempt? last;
    for (final op in operations) {
      final attempt = await _uploads.attempt(op);
      if (attempt == null) continue;
      last = attempt;
      if (await _uploads.acknowledged(attempt) == null) return attempt;
    }
    return last;
  }

  @override
  Future<bool> canRetry(String sessionId) async =>
      await prepareRetry(sessionId) != null;

  @override
  Future<ReviewedRetryScope?> prepareRetry(String sessionId) async {
    try {
      final binding = _binding(),
          snapshot = await _repository.reviewSnapshot(_binding());
      if (snapshot?.adopted != true || snapshot?.stage == null) return null;
      final selection = await _uploads.load(sessionId),
          attempt = await _retryAttempt(sessionId, binding);
      if (selection == null ||
          attempt == null ||
          !await _repository.operationBlocked(
            binding.id,
            attempt.operationId,
          )) {
        return null;
      }
      final origin = await _repository.operationOrigin(attempt.operationId);
      if (origin == null) return null;
      return ReviewedRetryScope(
        journalId: const Uuid().v4(),
        bindingId: binding.id,
        sessionId: sessionId,
        selectionId: selection.id,
        stageId: snapshot!.stage!.id,
        operationId: attempt.operationId,
        attemptId: attempt.id,
        requestHash: attempt.row['request_hash'] as String,
        origin: origin,
        generation: snapshot.stage!.generation,
        epoch: connection.foregroundEpoch,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> retryReviewed(ReviewedRetryScope scope) => _run((
    binding,
    session,
    current,
  ) async {
    final selection = await _uploads.load(scope.sessionId),
        attempt = await _retryAttempt(scope.sessionId, binding);
    if (scope.bindingId != binding.id ||
        scope.epoch != connection.foregroundEpoch ||
        selection?.id != scope.selectionId ||
        attempt == null ||
        attempt.operationId != scope.operationId ||
        attempt.id != scope.attemptId ||
        attempt.row['request_hash'] != scope.requestHash ||
        await _repository.operationOrigin(attempt.operationId) !=
            scope.origin) {
      throw const AnimusRecoveryFailure();
    }
    RemoteExchange? exchange;
    AnimusHttpResponse? response;
    try {
      exchange = await _repository.beginReviewedRetry(
        binding.id,
        scope.stageId,
        RemoteApiRequest.action(
          attempt.operationId,
          attempt.id,
          attempt.row['request_hash'] as String,
        ),
        current,
        journalId: scope.journalId,
      );
      current();
      if (exchange.generation != scope.generation ||
          exchange.operationGeneration != scope.origin) {
        throw const AnimusRecoveryFailure();
      }
      response = await _http.post(
        uri: connection.config!.apiOrigin.replace(
          pathSegments: [
            'v1',
            'data-spaces',
            connection.config!.dataSpaceId,
            'training',
            'actions',
          ],
        ),
        headers: {
          ..._headers(session, exchange.generation),
          operationGenerationHeader: exchange.operationGeneration!,
        },
        body: attempt.bytes,
        maxResponseBytes: 8 * 1024 * 1024,
        timeout: const Duration(seconds: 20),
      );
      current();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const _ReviewDenied();
      }
      final generation = recoveryResponseGeneration(response),
          object = recoveryResponseObject(response);
      if (generation != exchange.generation ||
          isRecoveryResponseError(object['error']) ||
          response.statusCode != 200 ||
          object['record'] is! Map ||
          object['related'] is! List ||
          (object['related'] as List).isNotEmpty ||
          object['replayed'] is! bool ||
          object['position'] is! int ||
          (object['position'] as int) < 1) {
        throw const AnimusRecoveryFailure();
      }
      validateReviewedWorkoutRecord(
        Map<String, dynamic>.from(object['record'] as Map),
        attempt.command,
      );
      await _repository.settleValidatedResponse(
        exchange,
        status: 200,
        generation: generation!,
        body: response.body,
      );
      current();
      // Retained as evidence for this fresh exchange; prior acknowledgement and
      // immutable comparison rows are never rewritten or treated as permission.
      _reviewedStage = scope.stageId;
      _reviewedReply = true;
    } on Object {
      if (exchange != null) await _stop(exchange, response);
      rethrow;
    }
  });
  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    ++_loadEpoch;
    connection.removeListener(_connectionChanged);
    _sender?.removeListener(_senderChanged);
    return _closing = () async {
      await _http.close();
      await Future.wait(_covered.toList());
    }();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

final class _ReviewDenied implements Exception {
  const _ReviewDenied();
}
