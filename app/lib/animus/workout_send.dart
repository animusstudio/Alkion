import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../store/local_store.dart';
import 'adapters/http.dart';
import 'adapters/auth.dart';
import 'connection.dart';
import 'contracts.dart';
import 'ports.dart';
import 'workout_send_models.dart';
import 'workout_translation.dart';
import 'workout_upload_repository.dart';

export 'workout_send_models.dart';

const _responseLimit = 8 * 1024 * 1024;
const _timeout = Duration(seconds: 20);

/// Manual, one-selection foreground sender. Construction and local inspection
/// perform no network, token restore or authentication. A request whose outcome
/// is unknown is retried only with its existing operation ID and exact bytes.
final class AnimusWorkoutSender extends ChangeNotifier
    implements AnimusWorkoutSendPort {
  AnimusWorkoutSender({
    required LocalDatabase database,
    required String installationId,
    required this.connection,
    AnimusUploadHttpPort? http,
  }) : _repository = WorkoutUploadRepository(database, installationId),
       _http = http ?? IoAnimusHttpPort();
  final AnimusConnectionController connection;
  final WorkoutUploadRepository _repository;
  final AnimusUploadHttpPort _http;
  final _transient = <String, AnimusWorkoutSelection>{};
  Future<void>? _running;
  bool _closed = false, _disposed = false;
  @override
  bool get busy => _running != null;

  void _notify() {
    if (!_disposed && !_closed) notifyListeners();
  }

  Map<String, dynamic> _binding() {
    final config = connection.config, identity = connection.identity;
    if (!connection.confirmed || config == null || identity == null) {
      throw const WorkoutUploadBlocked(AnimusWorkoutSendIssue.notConnected);
    }
    if (identity.issuer != config.issuer) {
      throw const WorkoutUploadBlocked(AnimusWorkoutSendIssue.differentScope);
    }
    return workoutBinding(
      _repository.installationId,
      _repository.db.token,
      config,
      identity,
    );
  }

  void _current(int epoch, AnimusIdentity identity) {
    if (_closed || !connection.foregroundCurrent(epoch, identity)) {
      throw const WorkoutUploadBlocked(AnimusWorkoutSendIssue.cancelled);
    }
  }

  AnimusWorkoutSelection _unsupported(
    String sessionId,
    AnimusWorkoutSendIssue issue,
  ) => AnimusWorkoutSelection(
    sessionId: sessionId,
    selectionId: '',
    exerciseCount: 0,
    setCount: 0,
    exerciseNames: const [],
    status: AnimusWorkoutSendStatus.unsupported,
    issue: issue,
  );

  @override
  Future<AnimusWorkoutSelection> select(String sessionId) async {
    if (busy) return _unsupported(sessionId, AnimusWorkoutSendIssue.busy);
    try {
      final binding = _binding(),
          epoch = connection.foregroundEpoch,
          identity = connection.identity!;
      final frozen = await _repository.select(
        sessionId,
        binding,
        () => _current(epoch, identity),
      );
      _current(epoch, identity);
      _transient.remove(sessionId);
      return await _repository.summary(frozen);
    } on Object catch (e) {
      return _unsupported(sessionId, _issue(e));
    }
  }

  @override
  Future<AnimusWorkoutSelection?> selectionFor(String sessionId) async {
    final cached = _transient[sessionId];
    if (cached != null && busy) return cached;
    FrozenWorkoutSelection? frozen;
    try {
      frozen = await _repository.load(sessionId);
      if (frozen == null) return cached;
      final summary = await _repository.summary(frozen);
      final binding = _binding();
      await _repository.check(binding, frozen);
      return cached ?? summary;
    } on Object catch (e) {
      return frozen?.summary(
            status: AnimusWorkoutSendStatus.needsReview,
            issue: _issue(e),
          ) ??
          cached?.withState(AnimusWorkoutSendStatus.needsReview, _issue(e)) ??
          _unsupported(sessionId, _issue(e));
    }
  }

  @override
  Future<void> send(AnimusWorkoutSelection selected) {
    if (_closed || busy || selected.selectionId.isEmpty) {
      return _running ?? Future.value();
    }
    final done = Completer<void>();
    _running = done.future;
    _transient[selected.sessionId] = selected.withState(
      AnimusWorkoutSendStatus.sending,
      null,
    );
    _notify();
    () async {
      FrozenWorkoutSelection? frozen;
      try {
        final binding = _binding(),
            epoch = connection.foregroundEpoch,
            identity = connection.identity!;
        void scopeCheck() => _current(epoch, identity);
        frozen = await _repository.load(selected.sessionId);
        if (frozen == null || frozen.id != selected.selectionId) {
          throw const WorkoutUploadBlocked(
            AnimusWorkoutSendIssue.differentScope,
          );
        }
        final selection = frozen;
        // New requests must have representable metadata before any dependency
        // write. An already-frozen uncertain request retains identical replay.
        if (await _repository.attempt(selection.operationId) == null) {
          try {
            nativeWorkoutMetadata(
              uploadMap(
                uploadMap(
                  uploadMap(selection.data['finish'])['input'],
                )['session'],
              ),
            );
          } on FormatException {
            throw const WorkoutUploadBlocked(
              AnimusWorkoutSendIssue.invalidValues,
            );
          }
        }
        final saved = await _repository.summary(selection);
        if (saved.status == AnimusWorkoutSendStatus.needsReview &&
            saved.issue == AnimusWorkoutSendIssue.invalidValues) {
          throw const WorkoutUploadBlocked(
            AnimusWorkoutSendIssue.invalidValues,
          );
        }
        await _repository.check(binding, selection);
        scopeCheck();
        final requests = _ForegroundRequests(
          this,
          selection,
          binding,
          epoch,
          identity,
        );
        // This authorized read happens before the very first dependency write,
        // including when retrying an existing selection after reconnecting.
        final info = await requests.get(['v1', 'system', 'info']);
        if (info.statusCode != 200) _httpStatus(info.statusCode);
        final capability = _json(info, 64 * 1024);
        final training = capability['training'];
        if (training is! Map ||
            training['implemented'] is! List ||
            !(training['implemented'] as List).contains(
              animusWorkoutCapability,
            ) ||
            training['max_command_bytes'] != animusWireLimit ||
            !_datasetsCompatible(training['datasets'])) {
          throw const WorkoutUploadBlocked(
            AnimusWorkoutSendIssue.capabilityMissing,
          );
        }
        final acknowledged = <String, Map<String, dynamic>>{};
        for (final definition in selection.definitions) {
          Map<String, dynamic>? previous;
          String? previousOperation;
          for (final step in (definition['chain'] as List).map(uploadMap)) {
            final action = uploadMap(step['action']);
            var attempt = await _repository.attempt(
              action['operation_id'] as String,
            );
            var ack = attempt == null
                ? null
                : await _repository.acknowledged(attempt);
            if (ack == null) {
              final command =
                  attempt?.command ??
                  {
                    'operation_id': action['operation_id'],
                    'target': uploadRef(
                      'exercise',
                      definition['target_id'] as String,
                    ),
                    'base_revision': previous?['revision'] ?? 0,
                    'semantic_version': 'training-definition-v1',
                    'dependencies': [
                      if (previousOperation != null) previousOperation,
                    ],
                    'related_bases': <Object?>[],
                    'definition': {
                      'action': previous == null ? 'create' : 'edit',
                      'definition': nativeDefinitionPatch(
                        uploadMap(uploadMap(action['input'])['fields']),
                        create: previous == null,
                      ),
                    },
                  };
              attempt ??= await _repository.freezeAttempt(
                selection,
                binding,
                command,
                scopeCheck,
              );
              ack = await _post(
                requests,
                selection,
                binding,
                attempt,
                scopeCheck,
              );
            } else {
              // A retained receipt is usable only in its original attachment.
              await _repository.freezeAttempt(
                selection,
                binding,
                attempt!.command,
                scopeCheck,
              );
            }
            previous = uploadMap(uploadMap(ack['record'])['definition']);
            previousOperation = action['operation_id'] as String;
          }
          acknowledged[definition['local_id'] as String] = {
            'definition': previous,
            'operation_id': previousOperation,
          };
        }
        var attempt = await _repository.attempt(selection.operationId);
        var ack = attempt == null
            ? null
            : await _repository.acknowledged(attempt);
        if (ack == null) {
          final command =
              attempt?.command ?? _workoutCommand(selection, acknowledged);
          attempt ??= await _repository.freezeAttempt(
            selection,
            binding,
            command,
            scopeCheck,
          );
          ack = await _post(requests, selection, binding, attempt, scopeCheck);
        } else {
          await _repository.freezeAttempt(
            selection,
            binding,
            attempt!.command,
            scopeCheck,
          );
        }
        // A read failure after an acknowledged remote commit does not erase it.
        try {
          final response = await requests.get([
            'v1',
            'data-spaces',
            connection.config!.dataSpaceId,
            'training',
            'workouts',
            selection.data['target_id'] as String,
          ]);
          if (response.statusCode != 200) _httpStatus(response.statusCode);
          final read = _json(response, _responseLimit);
          _validateRecord(read, attempt.command);
          await _repository.outcome(selection, binding, attempt, {
            'kind': 'read_back',
            'record': read,
          }, scopeCheck);
        } on Object {
          scopeCheck();
          _transient[selected.sessionId] = selection.summary(
            status: AnimusWorkoutSendStatus.sent,
            issue: AnimusWorkoutSendIssue.readBackFailed,
          );
        }
        scopeCheck();
        final summary = await _repository.summary(selection);
        _transient[selected.sessionId] = summary;
      } on Object catch (e) {
        final issue = _issue(e);
        AnimusWorkoutSelection summary = selected;
        if (frozen != null) {
          try {
            summary = await _repository.summary(frozen);
          } on Object {
            /* preserved evidence remains authoritative */
          }
        }
        _transient[selected.sessionId] = summary.withState(
          summary.status == AnimusWorkoutSendStatus.sent
              ? AnimusWorkoutSendStatus.sent
              : issue == AnimusWorkoutSendIssue.network ||
                    issue == AnimusWorkoutSendIssue.invalidResponse ||
                    issue == AnimusWorkoutSendIssue.localCommitUncertain ||
                    issue == AnimusWorkoutSendIssue.cancelled
              ? AnimusWorkoutSendStatus.uncertain
              : AnimusWorkoutSendStatus.needsReview,
          issue,
        );
      } finally {
        _running = null;
        _notify();
        done.complete();
      }
    }();
    return done.future;
  }

  Future<Map<String, dynamic>> _post(
    _ForegroundRequests requests,
    FrozenWorkoutSelection selection,
    Map<String, dynamic> binding,
    WorkoutUploadAttempt attempt,
    void Function() current,
  ) async {
    AnimusHttpResponse? received;
    try {
      final response = received = await requests.post(attempt.bytes);
      if (response.statusCode != 200) {
        if (![
          400,
          401,
          403,
          404,
          409,
          413,
          422,
        ].contains(response.statusCode)) {
          throw const WorkoutUploadBlocked(AnimusWorkoutSendIssue.network);
        }
        final issue = response.statusCode == 401 || response.statusCode == 403
            ? AnimusWorkoutSendIssue.accessDenied
            : response.statusCode == 400 && attempt.command['workout'] != null
            ? AnimusWorkoutSendIssue.invalidValues
            : AnimusWorkoutSendIssue.dependencyFailed;
        // HTTP rejection is retained separately from transport uncertainty.
        await _repository.outcome(selection, binding, attempt, {
          'kind': 'rejected',
          'issue': issue.name,
          'http_status': response.statusCode,
        }, current);
        throw WorkoutUploadBlocked(issue);
      }
      final body = _json(response, _responseLimit);
      if (body['record'] is! Map ||
          body['related'] is! List ||
          (body['related'] as List).isNotEmpty ||
          body['replayed'] is! bool ||
          body['position'] is! int ||
          (body['position'] as int) < 1) {
        throw const WorkoutUploadBlocked(
          AnimusWorkoutSendIssue.invalidResponse,
        );
      }
      _validateRecord(uploadMap(body['record']), attempt.command);
      final encoded = AnimusCommandBytes(attempt.command);
      final evidence = {
        'kind': 'acknowledged',
        'record': body['record'],
        'response_base64': base64Encode(response.body),
        'replayed': body['replayed'],
        'position': body['position'],
        'canonical_hash': encoded.canonicalHash,
        'canonical_bytes': encoded.canonical.length,
      };
      await _repository.outcome(selection, binding, attempt, evidence, current);
      current();
      return evidence;
    } on Object catch (e) {
      // The attempt was durable before I/O. Failure to commit this outcome leaves
      // that same attempt uncertain; no replacement identity can be allocated.
      if (e is! WorkoutUploadBlocked ||
          (e.issue != AnimusWorkoutSendIssue.accessDenied &&
              e.issue != AnimusWorkoutSendIssue.dependencyFailed &&
              e.issue != AnimusWorkoutSendIssue.invalidValues)) {
        try {
          await _repository.outcome(selection, binding, attempt, {
            'kind': 'uncertain',
            'issue': _issue(e).name,
            if (received != null) 'http_status': received.statusCode,
            if (received != null && received.body.length <= _responseLimit)
              'response_base64': base64Encode(received.body),
          }, current);
        } on Object {
          /* never mask the preserved original attempt */
        }
      }
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _http.close();
    await _running;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

final class _ForegroundRequests {
  _ForegroundRequests(
    this.owner,
    this.selection,
    this.binding,
    this.epoch,
    this.identity,
  );
  final AnimusWorkoutSender owner;
  final FrozenWorkoutSelection selection;
  final Map<String, dynamic> binding;
  final int epoch;
  final AnimusIdentity identity;
  bool _refreshed = false;
  Future<AnimusHttpResponse> get(List<String> path) => _request(path, null);
  Future<AnimusHttpResponse> post(List<int> body) => _request([
    'v1',
    'data-spaces',
    owner.connection.config!.dataSpaceId,
    'training',
    'actions',
  ], body);
  Future<AnimusHttpResponse> _request(
    List<String> path,
    List<int>? body,
  ) async {
    void current() => owner._current(epoch, identity);
    Future<AnimusHttpResponse> run(AnimusAuthSession session) async {
      await owner._repository.check(binding, selection);
      current();
      final config = owner.connection.config!;
      final uri = config.apiOrigin.replace(pathSegments: path);
      final headers = {
        'Authorization': 'Bearer ${session.accessToken}',
        'Accept': 'application/json',
        AnimusDefinitionReadContract.admissionHeader: config.readAdmission,
      };
      final result = body == null
          ? await owner._http.get(
              uri: uri,
              headers: headers,
              maxResponseBytes: path.length == 3 ? 64 * 1024 : _responseLimit,
              timeout: _timeout,
            )
          : await owner._http.post(
              uri: uri,
              headers: headers,
              body: body,
              maxResponseBytes: _responseLimit,
              timeout: _timeout,
            );
      current();
      await owner._repository.check(binding, selection);
      current();
      return result;
    }

    current();
    final refreshes = owner.connection.foregroundRefreshes;
    var session = await owner.connection.sessionForForeground(epoch);
    if (owner.connection.foregroundRefreshes != refreshes) _refreshed = true;
    current();
    var result = await run(session);
    if (result.statusCode == 401 && !_refreshed) {
      _refreshed = true;
      session = await owner.connection.sessionForForeground(
        epoch,
        refresh: true,
      );
      current();
      result = await run(session);
    }
    return result;
  }
}

bool _datasetsCompatible(Object? datasets) =>
    datasets is List &&
    ['definitions', 'workouts'].every(
      (name) => datasets.any(
        (d) =>
            d is Map &&
            d['name'] == name &&
            d['semantic_version'] ==
                (name == 'definitions'
                    ? 'training-definition-v1'
                    : 'training-workout-v1'),
      ),
    );
void _httpStatus(int status) => throw WorkoutUploadBlocked(
  status == 401 || status == 403
      ? AnimusWorkoutSendIssue.accessDenied
      : AnimusWorkoutSendIssue.network,
);
Map<String, dynamic> _json(AnimusHttpResponse response, int limit) {
  if (response.body.length > limit ||
      !(response.headers['content-type'] ?? '').toLowerCase().startsWith(
        'application/json',
      ) ||
      !['', 'identity'].contains(response.headers['content-encoding'] ?? '')) {
    throw const WorkoutUploadBlocked(AnimusWorkoutSendIssue.invalidResponse);
  }
  try {
    final text = utf8.decode(response.body);
    // Bound nesting before the decoder traverses an untrusted response.
    var depth = 0, quoted = false, escaped = false;
    for (final rune in text.runes) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (rune == 92) {
          escaped = true;
        } else if (rune == 34) {
          quoted = false;
        }
      } else if (rune == 34) {
        quoted = true;
      } else if (rune == 123 || rune == 91) {
        if (++depth > 48) throw const FormatException();
      } else if (rune == 125 || rune == 93) {
        depth--;
      }
    }
    return uploadMap(jsonDecode(text));
  } on Object {
    throw const WorkoutUploadBlocked(AnimusWorkoutSendIssue.invalidResponse);
  }
}

Map<String, dynamic> _workoutCommand(
  FrozenWorkoutSelection selection,
  Map<String, Map<String, dynamic>> acknowledged,
) {
  final finish = uploadMap(selection.data['finish']),
      input = uploadMap(finish['input']);
  final session = uploadMap(input['session']),
      time = uploadMap(input['finish_time_evidence']);
  final target = selection.data['target_id'] as String;
  final sets = (input['sets'] as List).map(uploadMap).toList();
  final blocks = <Map<String, dynamic>>[];
  for (final definition in selection.definitions) {
    final local = definition['local_id'] as String,
        remote = definition['target_id'] as String;
    final ref = uploadRef('exercise', remote);
    blocks.add({
      'id': uploadMap(selection.data['block_ids'])[local],
      'exercise': ref,
      'definition': acknowledged[local]!['definition'],
      'sets': [
        for (final set in sets.where((s) => s['exercise_id'] == local))
          {
            'done': true,
            'logged': true,
            'set': {
              'id': uploadValue(
                uploadMap(selection.data['set_ids'])[set['id']],
              ),
              'exercise_id': uploadValue(ref),
              'weight_kg': uploadValue(set['weight_kg']),
              'reps': uploadValue(set['reps']),
              'rir': uploadValue(set['rir']),
              'is_warmup': uploadValue(set['is_warmup'] == 1),
            },
          },
      ],
    });
  }
  return {
    'operation_id': finish['operation_id'],
    'target': uploadRef('workout', target),
    'base_revision': 0,
    'semantic_version': 'training-workout-v1',
    'dependencies': [
      for (final d in selection.definitions)
        acknowledged[d['local_id']]!['operation_id'],
    ],
    'related_bases': <Object?>[],
    'workout': {
      'action': 'finish',
      'finished_at': time['finished_at'],
      'workout': nativeWorkoutMetadata(session),
      'draft': {
        'session_id': target,
        'elapsed_seconds': time['elapsed_seconds'],
        'blocks': blocks,
      },
      'definition_bases': [
        for (final d in selection.definitions)
          {
            'target': uploadRef('exercise', d['target_id'] as String),
            'revision': uploadMap(
              acknowledged[d['local_id']]!['definition'],
            )['revision'],
          },
      ],
    },
  };
}

void _validateRecord(
  Map<String, dynamic> record,
  Map<String, dynamic> command,
) {
  Never bad() =>
      throw const WorkoutUploadBlocked(AnimusWorkoutSendIssue.invalidResponse);
  final target = uploadMap(command['target']), kind = target['kind'];
  final member = kind == 'exercise' ? 'definition' : 'workout';
  if (record['kind'] != kind ||
      record.keys.where((k) => k != 'kind').length != 1 ||
      record[member] is! Map) {
    bad();
  }
  final r = uploadMap(record[member]);
  if (!mapEquals(uploadMap(r['ref']), target) ||
      r['revision'] != (command['base_revision'] as int) + 1 ||
      r['deleted_at'] != null ||
      r['source_origin'] != 'native' ||
      r['field_attribution'] is! Map ||
      uploadMap(r['id'])['value'] != target['id']) {
    bad();
  }
  final op = command['operation_id'];
  final attrs = uploadMap(r['field_attribution']);
  final patch = uploadMap(uploadMap(command[member])[member]);
  for (final field in patch.keys) {
    final expected = uploadMap(patch[field]), actual = uploadMap(r[field]);
    if (actual['state'] != expected['state'] ||
        !deepUploadEqual(actual['value'], expected['value']) ||
        uploadMap(attrs[field])['operation_id'] != op) {
      bad();
    }
  }
  if (kind == 'workout') {
    final w = uploadMap(command['workout']), draft = uploadMap(w['draft']);
    if (uploadMap(attrs['finished_at'])['operation_id'] != op ||
        uploadMap(r['date'])['value'] !=
            (w['finished_at'] as String).substring(0, 10) ||
        uploadMap(r['duration_min'])['value'] !=
            ((draft['elapsed_seconds'] as int) + 30) ~/ 60 ||
        uploadMap(r['day_template_id'])['state'] != 'null') {
      bad();
    }
    final returnedTime = uploadMap(r['finished_at'])['value'];
    if (returnedTime is! String ||
        DateTime.tryParse(returnedTime) !=
            DateTime.tryParse(w['finished_at'] as String)) {
      bad();
    }
    final bases = (w['definition_bases'] as List).map(uploadMap).toList();
    final returnedBases = (r['reference_bases'] as List)
        .map(uploadMap)
        .toList();
    if (bases.length != returnedBases.length ||
        bases.any((b) => !returnedBases.any((a) => deepUploadEqual(a, b)))) {
      bad();
    }
    final expectedSets = <Map<String, dynamic>>[];
    final expectedBlocks = <Map<String, dynamic>>[];
    for (final raw in draft['blocks'] as List) {
      final block = uploadMap(raw);
      final sets = (block['sets'] as List)
          .map((s) => uploadMap(uploadMap(s)['set']))
          .toList();
      expectedSets.addAll(sets);
      expectedBlocks.add({
        'id': block['id'],
        'exercise': block['exercise'],
        'set_ids': [for (final s in sets) uploadMap(s['id'])['value']],
      });
    }
    if (!deepUploadEqual(expectedBlocks, r['blocks']) ||
        (r['sets'] as List).length != expectedSets.length) {
      bad();
    }
    for (var i = 0; i < expectedSets.length; i++) {
      final actual = uploadMap((r['sets'] as List)[i]),
          expected = expectedSets[i];
      if (uploadMap(actual['set_number'])['value'] != i + 1 ||
          !deepUploadEqual(uploadMap(actual['session_id'])['value'], target)) {
        bad();
      }
      for (final field in expected.keys) {
        if (!deepUploadEqual(
              uploadMap(actual[field])['value'],
              uploadMap(expected[field])['value'],
            ) ||
            uploadMap(actual[field])['state'] !=
                uploadMap(expected[field])['state']) {
          bad();
        }
      }
    }
  }
}

bool deepUploadEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && deepUploadEqual(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => i,
        ).every((i) => deepUploadEqual(a[i], b[i]));
  }
  return a == b;
}

AnimusWorkoutSendIssue _issue(Object e) {
  if (e is WorkoutUploadBlocked) return e.issue;
  if (e is AnimusAuthFailure) {
    return switch (e.kind) {
      AnimusAuthFailureKind.accountChanged =>
        AnimusWorkoutSendIssue.differentScope,
      AnimusAuthFailureKind.sessionExpired =>
        AnimusWorkoutSendIssue.notConnected,
      AnimusAuthFailureKind.cancelled => AnimusWorkoutSendIssue.cancelled,
      _ => AnimusWorkoutSendIssue.invalidResponse,
    };
  }
  if (e is AnimusHttpFailure) {
    return e.kind == AnimusHttpFailureKind.invalidResponse ||
            e.kind == AnimusHttpFailureKind.responseTooLarge
        ? AnimusWorkoutSendIssue.invalidResponse
        : AnimusWorkoutSendIssue.network;
  }
  if (e is StoreException &&
      [
        'stale_generation',
        'foreign_profile',
        'profile_fenced',
      ].contains(e.category)) {
    return AnimusWorkoutSendIssue.differentScope;
  }
  if (e is FormatException || e is TypeError) {
    return AnimusWorkoutSendIssue.invalidResponse;
  }
  return AnimusWorkoutSendIssue.localCommitUncertain;
}
