import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../domain/evidence.dart';
import '../recovery/backup.dart';
import '../store/local_store.dart';
import 'strict_json.dart';
import 'recovery_stage_models.dart';

const unknownOperationGeneration = '00000000-0000-0000-0000-000000000000';
const _uuid = Uuid();
final _generation = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _hash = RegExp(r'^[0-9a-f]{64}$');
String _digest(List<int> bytes) => sha256.convert(bytes).toString();
String _now() => OperationInstant.now().text;
Never _deny([String category = 'remote_recovery_required']) =>
    throw StoreException(category);
bool _validGeneration(String value, {bool unknown = false}) =>
    _generation.hasMatch(value) &&
    (unknown || value != unknownOperationGeneration);
Map<String, dynamic> _decode(Object? value) => Map<String, dynamic>.from(
  jsonDecode(utf8.decode((value as List).cast<int>())) as Map,
);

/// The existing nonsecret workout binding, with no arbitrary extra properties.
/// This is deliberately not an auth/session/header serialization surface.
final class RemoteRecoveryBinding {
  RemoteRecoveryBinding.fromWorkoutBinding(Map<String, dynamic> value) {
    const fields = {
      'format',
      'translation',
      'installation_id',
      'profile_id',
      'generation',
      'issuer',
      'subject',
      'api_origin',
      'client_id',
      'data_space_id',
    };
    if (value.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(value.keys.toSet()).isNotEmpty ||
        value['format'] != 'alkion-native-workout-binding/1' ||
        value['generation'] is! int ||
        (value['generation'] as int) < 1 ||
        fields
            .where((k) => k != 'generation')
            .any(
              (k) =>
                  value[k] is! String ||
                  (value[k] as String).isEmpty ||
                  (value[k] as String).length > 2048,
            )) {
      throw const FormatException('Invalid nonsecret remote binding');
    }
    for (final key in ['api_origin', 'issuer']) {
      final text = value[key] as String,
          uri = Uri.tryParse(value[key] as String);
      if (uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.toString() != text ||
          (key == 'api_origin' && uri.path != '' && uri.path != '/')) {
        throw const FormatException('Invalid nonsecret remote locator');
      }
    }
    bytes = localBytes(value);
    id = _digest(bytes);
    profileId = value['profile_id'] as String;
    localGeneration = value['generation'] as int;
  }
  late final Uint8List bytes;
  late final String id, profileId;
  late final int localGeneration;
}

enum RemoteApiPath { discovery, directRead, action, operationStatus }

/// An API path kind and original IDs only: never a URL, header map or token.
final class RemoteApiRequest {
  const RemoteApiRequest.discovery()
    : path = RemoteApiPath.discovery,
      dataset = null,
      targetId = null,
      operationId = null,
      attemptId = null,
      requestHash = null;
  const RemoteApiRequest.read(this.dataset, this.targetId)
    : path = RemoteApiPath.directRead,
      operationId = null,
      attemptId = null,
      requestHash = null;
  const RemoteApiRequest.action(
    this.operationId,
    this.attemptId,
    this.requestHash,
  ) : path = RemoteApiPath.action,
      dataset = null,
      targetId = null;
  const RemoteApiRequest.status(this.operationId)
    : path = RemoteApiPath.operationStatus,
      dataset = null,
      targetId = null,
      attemptId = null,
      requestHash = null;
  final RemoteApiPath path;
  final String? dataset, targetId, operationId, attemptId, requestHash;

  void _validate() {
    if (path == RemoteApiPath.directRead &&
        (!const ['definitions', 'workouts'].contains(dataset) ||
            !_validGeneration(targetId ?? ''))) {
      _deny('invalid_remote_request');
    }
    if ((path == RemoteApiPath.action ||
            path == RemoteApiPath.operationStatus) &&
        !_validGeneration(operationId ?? '')) {
      _deny('invalid_remote_request');
    }
    if (path == RemoteApiPath.action &&
        (!_validGeneration(attemptId ?? '') ||
            !_hash.hasMatch(requestHash ?? ''))) {
      _deny('invalid_remote_request');
    }
  }
}

final class RemoteExchange {
  const RemoteExchange._(
    this.id,
    this.attachmentId,
    this.generation,
    this.operationGeneration,
  );
  final String id, attachmentId;
  final String? generation, operationGeneration;
}

final class RemoteRecoveryState {
  const RemoteRecoveryState(
    this.attachmentId,
    this.generation,
    this.state,
    this.revision,
    this.archiveId,
  );
  final String attachmentId, state;
  final String? generation;
  final int revision;
  final String? archiveId;
  bool get ready => state == 'ready';
}

final class RemoteRecoveryArchive {
  RemoteRecoveryArchive._(Map<String, dynamic> row)
    : id = row['archive_id'] as String,
      coveredBytes = Uint8List.fromList(
        (row['covered_bytes'] as List).cast<int>(),
      ),
      manifestBytes = Uint8List.fromList(
        (row['manifest_bytes'] as List).cast<int>(),
      ),
      coveredHash = row['covered_hash'] as String,
      manifestHash = row['manifest_hash'] as String {
    if (_digest(coveredBytes) != coveredHash ||
        _digest(manifestBytes) != manifestHash) {
      _deny('remote_archive_corrupt');
    }
  }
  final String id, coveredHash, manifestHash;
  final Uint8List coveredBytes, manifestBytes;
}

/// Storage only. Nothing here discovers a server, refreshes credentials or sends.
/// All effects use the existing serialized callback-scoped SQLite ownership.
final class RemoteRecoveryRepository {
  RemoteRecoveryRepository(this.db) : _owner = _uuid.v4();
  final LocalDatabase db;
  final String _owner;

  Future<Map<String, dynamic>> _attachment(LocalRead tx, String id) async {
    final row = await tx.getOptional(
      'SELECT * FROM animus_remote_attachments WHERE profile_id=? AND attachment_id=?',
      [tx.profileId, id],
    );
    if (row == null ||
        _digest((row['binding_bytes'] as List).cast<int>()) !=
            row['binding_hash']) {
      _deny('remote_attachment_mismatch');
    }
    return row;
  }

  Future<RemoteRecoveryState> _state(LocalRead tx, String id) async {
    final row = await _attachment(tx, id);
    final pending = await tx.getOptional(
      "SELECT 1 FROM animus_exchange_intents WHERE profile_id=? AND attachment_id=? AND state='pending' LIMIT 1",
      [tx.profileId, id],
    );
    final oldLocalGeneration =
        _decode(row['binding_bytes'])['generation'] != tx.token.generation;
    return RemoteRecoveryState(
      id,
      row['recovery_generation'] as String?,
      row['state'] == 'ready' && (pending != null || oldLocalGeneration)
          ? 'capture_pending'
          : row['state'] == 'ready' && row['recovery_generation'] == null
          ? 'unbound'
          : row['state'] as String,
      row['revision'] as int,
      row['archive_id'] as String?,
    );
  }

  Future<RemoteRecoveryState> state(String id) =>
      db.readTransaction((tx) => _state(tx, id), expected: db.token);

  Future<RemoteRecoveryState> requireReady(String id) =>
      db.readTransaction((tx) => _ready(tx, id), expected: db.token);

  Future<RemoteRecoveryState> _ready(LocalRead tx, String id) async {
    final result = await _state(tx, id);
    if (!result.ready) _deny();
    return result;
  }

  /// Journal discovery before G is known. Changed bindings never attach silently.
  Future<RemoteExchange> beginDiscovery(RemoteRecoveryBinding binding) async {
    if (binding.profileId != db.profileId ||
        binding.localGeneration != db.token.generation) {
      _deny('remote_attachment_mismatch');
    }
    await db.writeTransaction((tx) async {
      final metadata = await tx.get(
        'SELECT installation_id FROM profile_state WHERE singleton=1',
      );
      if (_decode(binding.bytes)['installation_id'] !=
          metadata['installation_id']) {
        _deny('remote_attachment_mismatch');
      }
      final existing = await tx.getAll(
        'SELECT * FROM animus_remote_attachments WHERE profile_id=?',
        [tx.profileId],
      );
      if (existing.isEmpty) {
        await tx.execute(
          "INSERT INTO animus_remote_attachments VALUES(?,?,?,?,?,'ready',1,NULL,?)",
          [tx.profileId, binding.id, binding.bytes, binding.id, null, _now()],
        );
      } else if (existing.length != 1 ||
          existing.single['attachment_id'] != binding.id) {
        _deny('remote_attachment_mismatch');
      }
    }, expected: db.token);
    return beginExchange(binding.id, const RemoteApiRequest.discovery());
  }

  Future<bool> _retainedRemoteWork(LocalRead tx) async =>
      await tx.getOptional(
        "SELECT 1 FROM operation_attempts UNION ALL SELECT 1 FROM animus_operation_origins UNION ALL SELECT 1 FROM replica_rows UNION ALL SELECT 1 FROM replica_checkpoints UNION ALL SELECT 1 FROM restore_journal UNION ALL SELECT 1 FROM profile_state WHERE generation>1 UNION ALL SELECT 1 FROM local_state WHERE state_kind='semanticSetting' AND (state_key='animus.native-workout.attachment/1' OR state_key LIKE 'animus.native-workout.selection/1/%') LIMIT 1",
      ) !=
      null;

  /// The first validated discovery can bind only a fresh remote attachment.
  /// Legacy remote evidence requires archive plus C-T3's explicit adoption.
  Future<void> settleInitialDiscovery(
    RemoteExchange exchange, {
    required String generation,
    required List<int> body,
  }) async {
    if (!_validGeneration(generation) || body.length > 64 * 1024) {
      _deny('invalid_remote_response');
    }
    final value = decodeStrictAnimusJson(utf8.decode(body), maxDepth: 48);
    final recovery = value is Map ? value['recovery'] : null;
    if (recovery is! Map ||
        recovery['protocol_version'] is! int ||
        recovery['protocol_version'] != 1 ||
        recovery['required'] != true ||
        recovery['profile'] != 'native-workout-v1' ||
        recovery['state'] != 'open' ||
        recovery['generation'] != generation) {
      _deny('invalid_remote_response');
    }
    final bound = await db.writeTransaction((tx) async {
      final intent = await _exchange(tx, exchange);
      final attachment = await _attachment(tx, exchange.attachmentId);
      if (exchange.generation != null ||
          intent['path_kind'] != 'discovery' ||
          intent['owner_id'] != _owner ||
          intent['state'] != 'pending' ||
          attachment['state'] != 'ready' ||
          attachment['revision'] != intent['attachment_revision'] ||
          attachment['recovery_generation'] != null) {
        _deny();
      }
      if (await _retainedRemoteWork(tx)) return false;
      await _append(tx, exchange, 200, generation, body);
      await tx.execute(
        "UPDATE animus_exchange_intents SET state='settled' WHERE profile_id=? AND exchange_id=?",
        [tx.profileId, exchange.id],
      );
      await tx.execute(
        'UPDATE animus_remote_attachments SET recovery_generation=?,revision=revision+1 WHERE profile_id=? AND attachment_id=?',
        [generation, tx.profileId, exchange.attachmentId],
      );
      return true;
    }, expected: db.token);
    if (!bound) {
      await fence(exchange.attachmentId);
      await appendResponse(
        exchange,
        status: 200,
        generation: generation,
        body: body,
      );
      _deny();
    }
  }

  /// Origin is assigned once; old prepared work stays unknown across attachments/G.
  Future<String?> operationOrigin(String operationId) => db.readTransaction(
    (tx) async =>
        (await tx.getOptional(
              "SELECT operation_generation FROM animus_operation_origins WHERE profile_id=? AND family='workouts' AND operation_id=?",
              [tx.profileId, operationId],
            ))?['operation_generation']
            as String?,
    expected: db.token,
  );

  /// Same transaction as new selected allocations; retries keep their old O.
  Future<void> prepareOriginsTx(
    LocalTransaction tx,
    String attachmentId,
    Iterable<String> operations, {
    required String? generation,
    bool legacyDevelopment = false,
  }) async {
    if (tx.profileId != db.profileId ||
        tx.token.generation != db.token.generation) {
      _deny('remote_attachment_mismatch');
    }
    final current = await _state(tx, attachmentId);
    if (current.generation != generation ||
        !(current.ready ||
            legacyDevelopment &&
                current.state == 'unbound' &&
                generation == null)) {
      _deny();
    }
    for (final operationId in operations.toSet()) {
      if (!_validGeneration(operationId)) _deny('invalid_remote_request');
      final prior = await tx.getOptional(
        "SELECT * FROM animus_operation_origins WHERE profile_id=? AND family='workouts' AND operation_id=?",
        [tx.profileId, operationId],
      );
      if (prior != null) {
        if (prior['attachment_id'] != null &&
            prior['attachment_id'] != attachmentId) {
          _deny('remote_attachment_mismatch');
        }
        continue;
      }
      final attempted = await tx.getOptional(
        "SELECT 1 FROM operation_attempts WHERE profile_id=? AND family='workouts' AND operation_id=?",
        [tx.profileId, operationId],
      );
      await tx.execute(
        "INSERT INTO animus_operation_origins VALUES(?,'workouts',?,?,?,?)",
        [
          tx.profileId,
          operationId,
          attachmentId,
          attempted != null || generation == null
              ? unknownOperationGeneration
              : generation,
          _now(),
        ],
      );
    }
  }

  /// Denied credentials disclose no scoped G. Legacy requires an explicit
  /// validated required:false descriptor and can never downgrade a known G.
  Future<void> settleUnscopedResponse(
    RemoteExchange exchange, {
    required int status,
    required List<int> body,
    bool legacyDevelopment = false,
  }) async {
    if (body.length > 8 * 1024 * 1024) _deny('invalid_remote_response');
    final value = body.isEmpty
        ? null
        : decodeStrictAnimusJson(utf8.decode(body), maxDepth: 48);
    if (value is Map &&
        const {
          'recovery_required',
          'operation_recovery_required',
          'recovery_unavailable',
        }.contains(value['error'])) {
      _deny();
    }
    await db.writeTransaction((tx) async {
      final intent = await _exchange(tx, exchange),
          attachment = await _attachment(tx, exchange.attachmentId);
      if (intent['owner_id'] != _owner ||
          intent['state'] != 'pending' ||
          attachment['state'] != 'ready' ||
          attachment['revision'] != intent['attachment_revision'] ||
          !(status == 401 ||
              status == 403 ||
              legacyDevelopment &&
                  exchange.generation == null &&
                  attachment['recovery_generation'] == null)) {
        _deny();
      }
      if (legacyDevelopment &&
          await tx.getOptional(
                'SELECT 1 FROM restore_journal UNION ALL SELECT 1 FROM profile_state WHERE generation>1 LIMIT 1',
              ) !=
              null) {
        _deny();
      }
      await _append(tx, exchange, status, null, body);
      await tx.execute(
        "UPDATE animus_exchange_intents SET state='settled' WHERE profile_id=? AND exchange_id=?",
        [tx.profileId, exchange.id],
      );
    }, expected: db.token);
  }

  Future<String> prepareOrigin(
    String attachmentId,
    String operationId,
  ) => db.writeTransaction((tx) async {
    final current = await _ready(tx, attachmentId);
    final prior = await tx.getOptional(
      "SELECT * FROM animus_operation_origins WHERE profile_id=? AND family='workouts' AND operation_id=?",
      [tx.profileId, operationId],
    );
    if (prior != null) {
      if (prior['attachment_id'] != null &&
          prior['attachment_id'] != attachmentId) {
        _deny('remote_attachment_mismatch');
      }
      return prior['operation_generation'] as String;
    }
    final operation = await tx.getOptional(
      "SELECT 1 FROM operations WHERE profile_id=? AND family='workouts' AND operation_id=?",
      [tx.profileId, operationId],
    );
    if (operation == null || !_validGeneration(operationId)) {
      _deny('invalid_remote_request');
    }
    final attempted = await tx.getOptional(
      "SELECT 1 FROM operation_attempts WHERE profile_id=? AND family='workouts' AND operation_id=?",
      [tx.profileId, operationId],
    );
    final origin = attempted == null
        ? current.generation!
        : unknownOperationGeneration;
    await tx.execute(
      "INSERT INTO animus_operation_origins VALUES(?,'workouts',?,?,?,?)",
      [tx.profileId, operationId, attachmentId, origin, _now()],
    );
    return origin;
  }, expected: db.token);

  Future<RemoteExchange> beginExchange(
    String attachmentId,
    RemoteApiRequest request, {
    bool legacyDevelopment = false,
  }) {
    request._validate();
    return db.writeTransaction((tx) async {
      final current = await _state(tx, attachmentId);
      if (!current.ready &&
          !(current.state == 'unbound' &&
              (request.path == RemoteApiPath.discovery || legacyDevelopment))) {
        _deny();
      }
      String? origin;
      if (request.operationId != null) {
        final row = await tx.getOptional(
          "SELECT * FROM animus_operation_origins WHERE profile_id=? AND family='workouts' AND operation_id=?",
          [tx.profileId, request.operationId],
        );
        if (row == null ||
            (row['attachment_id'] != null &&
                row['attachment_id'] != attachmentId)) {
          _deny('remote_origin_missing');
        }
        origin = row['operation_generation'] as String;
        if (!_validGeneration(origin, unknown: true)) {
          _deny('remote_origin_missing');
        }
      }
      if (request.path == RemoteApiPath.action) {
        if (((await _active(tx, attachmentId))?['blocked_operations']
                    as List? ??
                [])
            .contains(request.operationId)) {
          _deny('remote_review_required');
        }
        final attempt = await tx.getOptional(
          "SELECT request_hash,request_bytes,binding_bytes FROM operation_attempts WHERE profile_id=? AND family='workouts' AND operation_id=? AND attempt_id=?",
          [tx.profileId, request.operationId, request.attemptId],
        );
        final attachment = await _attachment(tx, attachmentId);
        if (attempt == null ||
            attempt['request_hash'] != request.requestHash ||
            _digest((attempt['request_bytes'] as List).cast<int>()) !=
                request.requestHash ||
            _digest(localBytes(_decode(attempt['binding_bytes']))) !=
                attachment['binding_hash']) {
          _deny('remote_attempt_mismatch');
        }
      }
      final id = _uuid.v4();
      await tx.execute(
        "INSERT INTO animus_exchange_intents VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',NULL,?)",
        [
          tx.profileId,
          id,
          attachmentId,
          _owner,
          request.path.name,
          request.path == RemoteApiPath.action ? 'POST' : 'GET',
          current.generation,
          origin,
          request.operationId == null ? null : 'workouts',
          request.operationId,
          request.attemptId,
          request.dataset,
          request.targetId,
          request.requestHash,
          current.revision,
          _now(),
        ],
      );
      return RemoteExchange._(id, attachmentId, current.generation, origin);
    }, expected: db.token);
  }

  Future<Map<String, dynamic>> _exchange(
    LocalRead tx,
    RemoteExchange exchange,
  ) async {
    final row = await tx.getOptional(
      'SELECT * FROM animus_exchange_intents WHERE profile_id=? AND exchange_id=?',
      [tx.profileId, exchange.id],
    );
    if (row == null ||
        row['attachment_id'] != exchange.attachmentId ||
        row['request_generation'] != exchange.generation ||
        row['operation_generation'] != exchange.operationGeneration) {
      _deny('remote_attempt_mismatch');
    }
    return row;
  }

  /// A separate committed small fence. Pending intent alone survives its failure.
  Future<void> fence(String attachmentId) => db.writeTransaction((tx) async {
    final current = await _state(tx, attachmentId);
    if (current.state == 'recovery_required') {
      final pending = await tx.getOptional(
        "SELECT 1 FROM animus_exchange_intents WHERE profile_id=? AND attachment_id=? AND state='pending'",
        [tx.profileId, attachmentId],
      );
      if (pending == null) return;
      await tx.execute(
        "UPDATE animus_remote_attachments SET state='capture_pending',revision=revision+1 WHERE profile_id=? AND attachment_id=?",
        [tx.profileId, attachmentId],
      );
      return;
    }
    if (current.state != 'capture_pending') {
      _deny('remote_capture_without_intent');
    }
    final row = await _attachment(tx, attachmentId);
    if (row['state'] != 'capture_pending') {
      await tx.execute(
        "UPDATE animus_remote_attachments SET state='capture_pending',revision=revision+1 WHERE profile_id=? AND attachment_id=?",
        [tx.profileId, attachmentId],
      );
    }
  }, expected: db.token);

  Future<void> _append(
    LocalTransaction tx,
    RemoteExchange exchange,
    int status,
    String? generation,
    List<int> body,
  ) async {
    await _exchange(tx, exchange);
    if (status < 100 ||
        status > 599 ||
        body.length > 8 * 1024 * 1024 ||
        (generation != null && !_validGeneration(generation))) {
      _deny('invalid_remote_response');
    }
    await tx
        .execute('INSERT INTO animus_response_evidence VALUES(?,?,?,?,?,?,?)', [
          tx.profileId,
          _uuid.v4(),
          exchange.id,
          generation,
          status,
          Uint8List.fromList(body),
          _now(),
        ]);
  }

  /// Safe late-evidence append deliberately does not require the live owner/epoch.
  Future<void> appendResponse(
    RemoteExchange exchange, {
    required int status,
    required String? generation,
    required List<int> body,
  }) => db.writeTransaction(
    (tx) => _append(tx, exchange, status, generation, body),
    expected: db.token,
  );

  /// Caller validates the public DTO first. Storage still rejects recovery errors/G.
  Future<void> settleValidatedResponse(
    RemoteExchange exchange, {
    required int status,
    required String generation,
    required List<int> body,
  }) async {
    if (body.length > 8 * 1024 * 1024 || !_validGeneration(generation)) {
      _deny('invalid_remote_response');
    }
    String? error;
    try {
      final value = body.isEmpty
          ? null
          : decodeStrictAnimusJson(utf8.decode(body), maxDepth: 48);
      if (value is Map && value['error'] is String) {
        error = value['error'] as String;
      }
    } on FormatException {
      _deny('invalid_remote_response');
    }
    if (generation != exchange.generation ||
        const [
          'recovery_required',
          'operation_recovery_required',
          'recovery_unavailable',
        ].contains(error)) {
      await fence(exchange.attachmentId);
      await appendResponse(
        exchange,
        status: status,
        generation: generation,
        body: body,
      );
      _deny();
    }
    await db.writeTransaction((tx) async {
      final row = await _exchange(tx, exchange);
      final attachment = await _attachment(tx, exchange.attachmentId);
      if (row['owner_id'] != _owner ||
          row['state'] != 'pending' ||
          attachment['state'] != 'ready' ||
          attachment['revision'] != row['attachment_revision'] ||
          attachment['recovery_generation'] != generation) {
        _deny();
      }
      await _append(tx, exchange, status, generation, body);
      await tx.execute(
        "UPDATE animus_exchange_intents SET state='settled' WHERE profile_id=? AND exchange_id=?",
        [tx.profileId, exchange.id],
      );
    }, expected: db.token);
  }

  Future<RemoteRecoveryArchive> archive(String archiveId) => db.readTransaction(
    (tx) async => RemoteRecoveryArchive._(
      await tx.get(
        'SELECT * FROM animus_recovery_archives WHERE profile_id=? AND archive_id=?',
        [tx.profileId, archiveId],
      ),
    ),
    expected: db.token,
  );

  /// Fence commits before any fallible copy; publication/completion is atomic.
  Future<RemoteRecoveryArchive> capture(
    String attachmentId, {
    int maxBytes = 256 * 1024 * 1024,
    RecoveryCheckpoint? checkpoint,
  }) async {
    await fence(attachmentId);
    await checkpoint?.call('remote-fence-committed');
    return db.writeTransaction((tx) async {
      final current = await _state(tx, attachmentId);
      if (current.state == 'recovery_required' && current.archiveId != null) {
        return RemoteRecoveryArchive._(
          await tx.get(
            'SELECT * FROM animus_recovery_archives WHERE profile_id=? AND archive_id=?',
            [tx.profileId, current.archiveId],
          ),
        );
      }
      if (current.state != 'capture_pending') _deny();
      final prior = await tx.getAll(
        'SELECT archive_id,covered_hash,manifest_hash FROM animus_recovery_archives WHERE profile_id=? ORDER BY archive_id',
        [tx.profileId],
      );
      final covered = await readCoveredState(
        (sql) => tx.getAll(sql),
        excluding: const {'animus_recovery_archives'},
      );
      final bytes = localBytes({
        'format': 'alkion-animus-covered-state/1',
        'tables': covered.tables,
        'keys': covered.keys,
        'prior_archives': prior,
      });
      final manifest = localBytes({
        'format': 'alkion-animus-recovery-manifest/1',
        'attachment_id': attachmentId,
        'recovery_generation': current.generation,
        'profile_id': tx.profileId,
        'local_generation': tx.token.generation,
        'inventory': covered.manifestInventory(),
        'prior_archives': prior,
      });
      if (maxBytes < 1 || bytes.length + manifest.length > maxBytes) {
        _deny('remote_archive_resource_limit');
      }
      await checkpoint?.call('remote-covered-state-read');
      final id = _uuid.v4();
      await tx.execute(
        'INSERT INTO animus_recovery_archives VALUES(?,?,?,?,?,?,?,?,?)',
        [
          tx.profileId,
          id,
          attachmentId,
          current.generation,
          bytes,
          manifest,
          _digest(bytes),
          _digest(manifest),
          _now(),
        ],
      );
      final result = RemoteRecoveryArchive._(
        await tx.get(
          'SELECT * FROM animus_recovery_archives WHERE profile_id=? AND archive_id=?',
          [tx.profileId, id],
        ),
      );
      await tx.execute(
        "UPDATE animus_exchange_intents SET state='archived',archive_id=? WHERE profile_id=? AND attachment_id=? AND state='pending'",
        [id, tx.profileId, attachmentId],
      );
      await tx.execute(
        "UPDATE animus_remote_attachments SET state='recovery_required',archive_id=?,revision=revision+1 WHERE profile_id=? AND attachment_id=?",
        [id, tx.profileId, attachmentId],
      );
      await checkpoint?.call('remote-archive-before-commit');
      return result;
    }, expected: db.token);
  }

  String _activeKey(String attachmentId) =>
      'animus.recovery.active-stage/1/$attachmentId';

  Future<Map<String, dynamic>?> _active(
    LocalRead tx,
    String attachmentId,
  ) async {
    final row = await tx.localState(
      LocalStateKind.semanticSetting,
      _activeKey(attachmentId),
    );
    return row == null ? null : _decode(row['payload_bytes']);
  }

  Future<bool> _unknownLocalHistory(
    LocalRead tx,
    Map<String, dynamic> attachment,
  ) async =>
      attachment['recovery_generation'] == null &&
      await tx.getOptional(
            'SELECT 1 FROM restore_journal UNION ALL SELECT 1 FROM profile_state WHERE generation>1 LIMIT 1',
          ) !=
          null;

  Future<Map<String, dynamic>> _reviewAttachment(
    LocalRead tx,
    RemoteRecoveryBinding binding,
  ) async {
    if (binding.profileId != tx.profileId ||
        binding.localGeneration != tx.token.generation) {
      _deny('remote_attachment_mismatch');
    }
    final row = await _attachment(tx, binding.id);
    if (row['state'] != 'recovery_required' ||
        row['archive_id'] == null ||
        await tx.getOptional(
              "SELECT 1 FROM animus_exchange_intents WHERE profile_id=? AND attachment_id=? AND state='pending'",
              [tx.profileId, binding.id],
            ) !=
            null) {
      _deny();
    }
    RemoteRecoveryArchive._(
      await tx.get(
        'SELECT * FROM animus_recovery_archives WHERE profile_id=? AND archive_id=?',
        [tx.profileId, row['archive_id']],
      ),
    );
    return row;
  }

  RecoveryStage _stageValue(Map<String, dynamic> row) {
    final inventory = _decode(row['inventory_bytes']);
    return RecoveryStage(
      row['stage_id'] as String,
      row['attachment_id'] as String,
      row['recovery_generation'] as String,
      row['state'] as String,
      inventory,
      {
        for (final entry in (inventory['comparisons'] as Map? ?? {}).entries)
          entry.key as String: RecoveryComparison.values.byName(
            entry.value as String,
          ),
      },
    );
  }

  Future<RecoveryStage> _stage(LocalRead tx, String id) async => _stageValue(
    await tx.get(
      'SELECT * FROM animus_recovery_stages WHERE profile_id=? AND stage_id=?',
      [tx.profileId, id],
    ),
  );

  Future<Map<String, dynamic>> _stageLease(
    LocalRead tx,
    RecoveryStage stage, {
    bool verified = false,
  }) async {
    final attachment = await _attachment(tx, stage.attachmentId);
    if (attachment['state'] != 'recovery_required' ||
        attachment['revision'] != stage.inventory['attachment_revision'] ||
        attachment['archive_id'] != stage.inventory['archive_id'] ||
        (!verified && stage.inventory['owner'] != _owner) ||
        (verified ? stage.state != 'verified' : stage.state != 'staging')) {
      _deny('remote_stage_stale');
    }
    return attachment;
  }

  Future<RecoveryReviewSnapshot?> reviewSnapshot(
    RemoteRecoveryBinding binding,
  ) => db.readTransaction((tx) async {
    final row = await tx.getOptional(
      'SELECT * FROM animus_remote_attachments WHERE profile_id=? AND attachment_id=?',
      [tx.profileId, binding.id],
    );
    if (row == null) {
      if (await tx.getOptional(
            'SELECT 1 FROM animus_remote_attachments WHERE profile_id=?',
            [tx.profileId],
          ) !=
          null) {
        _deny('remote_attachment_mismatch');
      }
      return null;
    }
    final current = await _state(tx, binding.id),
        active = await _active(tx, binding.id);
    final latest = await tx.getOptional(
      'SELECT * FROM animus_recovery_stages WHERE profile_id=? AND attachment_id=? ORDER BY rowid DESC LIMIT 1',
      [tx.profileId, binding.id],
    );
    final stage = latest == null ? null : _stageValue(latest);
    return RecoveryReviewSnapshot(
      required: !current.ready,
      adopted: active?['stage_id'] == stage?.id && current.ready,
      manualDisposition:
          await _unknownLocalHistory(tx, row) ||
          (active?['blocked_local_records'] as List? ?? []).isNotEmpty,
      canAdopt:
          stage?.verified == true &&
          current.state == 'recovery_required' &&
          stage!.inventory['attachment_revision'] == current.revision &&
          stage.inventory['archive_id'] == current.archiveId,
      stage: stage,
    );
  }, expected: db.token);

  Future<RemoteExchange> beginReviewDiscovery(
    RemoteRecoveryBinding binding,
    void Function() current,
  ) => db.writeTransaction((tx) async {
    current();
    final row = await _reviewAttachment(tx, binding);
    final result = await _insertReviewExchange(
      tx,
      binding.id,
      row['revision'] as int,
      row['recovery_generation'] as String?,
      const RemoteApiRequest.discovery(),
    );
    current();
    return result;
  }, expected: db.token);

  Future<RemoteExchange> _insertReviewExchange(
    LocalTransaction tx,
    String attachmentId,
    int revision,
    String? generation,
    RemoteApiRequest request, {
    String? journalId,
  }) async {
    request._validate();
    String? origin;
    if (request.operationId != null) {
      final row = await tx.getOptional(
        "SELECT * FROM animus_operation_origins WHERE profile_id=? AND family='workouts' AND operation_id=?",
        [tx.profileId, request.operationId],
      );
      if (row == null ||
          row['attachment_id'] != null &&
              row['attachment_id'] != attachmentId) {
        _deny('remote_origin_missing');
      }
      origin = row['operation_generation'] as String;
      if (!_validGeneration(origin, unknown: true)) {
        _deny('remote_origin_missing');
      }
    }
    final id = journalId ?? _uuid.v4();
    if (!_validGeneration(id)) _deny('invalid_remote_request');
    await tx.execute(
      "INSERT INTO animus_exchange_intents VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',NULL,?)",
      [
        tx.profileId,
        id,
        attachmentId,
        _owner,
        request.path.name,
        request.path == RemoteApiPath.action ? 'POST' : 'GET',
        generation,
        origin,
        request.operationId == null ? null : 'workouts',
        request.operationId,
        request.attemptId,
        request.dataset,
        request.targetId,
        request.requestHash,
        revision,
        _now(),
      ],
    );
    return RemoteExchange._(id, attachmentId, generation, origin);
  }

  Future<Map<String, dynamic>> _reviewInventory(
    LocalRead tx,
    String attachmentId,
    String probeId,
  ) async {
    final targets = <String, RecoveryTarget>{};
    void add(String dataset, String id, [Map<String, dynamic>? expected]) {
      if (!const ['definitions', 'workouts'].contains(dataset) ||
          !_validGeneration(id)) {
        _deny('remote_inventory_invalid');
      }
      final key = '$dataset/$id', prior = targets[key];
      final snapshots = [...?prior?.expected];
      if (expected != null &&
          !snapshots.any(
            (v) => _digest(localBytes(v)) == _digest(localBytes(expected)),
          )) {
        snapshots.add(expected);
      }
      targets[key] = RecoveryTarget(dataset, id, snapshots);
      if (targets.length > 512) _deny('remote_stage_resource_limit');
    }

    void record(Map<String, dynamic> value) {
      final kind = value['kind'],
          body = value[kind == 'exercise' ? 'definition' : 'workout'];
      if (body is! Map || body['ref'] is! Map) {
        _deny('remote_inventory_invalid');
      }
      add(
        kind == 'exercise' ? 'definitions' : 'workouts',
        (body['ref'] as Map)['id'] as String,
        value,
      );
      if (kind == 'workout') {
        for (final base in body['reference_bases'] as List? ?? []) {
          add('definitions', ((base as Map)['target'] as Map)['id'] as String);
        }
      }
    }

    add('definitions', probeId);
    for (final row in await tx.getAll(
      "SELECT * FROM local_state WHERE profile_id=? AND state_kind='semanticSetting' AND state_key LIKE 'animus.native-workout.selection/1/%'",
      [tx.profileId],
    )) {
      final selected = _decode(row['payload_bytes']);
      if (_digest(localBytes(selected['binding'])) != attachmentId) {
        _deny('remote_attachment_mismatch');
      }
      add('workouts', selected['target_id'] as String);
      for (final def in selected['definitions'] as List) {
        add('definitions', (def as Map)['target_id'] as String);
      }
    }
    final allocations = await tx.localState(
      LocalStateKind.semanticSetting,
      'animus.native-workout.attachment/1',
    );
    if (allocations != null) {
      final value = _decode(allocations['payload_bytes']);
      if (_digest(localBytes(value['binding'])) != attachmentId) {
        _deny('remote_attachment_mismatch');
      }
      for (final id in (value['exercises'] as Map).values) {
        add('definitions', id as String);
      }
    }
    for (final row in await tx.getAll(
      "SELECT a.request_bytes,a.binding_bytes,o.outcome_bytes FROM operation_attempts a LEFT JOIN attempt_outcomes o ON o.profile_id=a.profile_id AND o.family=a.family AND o.operation_id=a.operation_id AND o.attempt_id=a.attempt_id WHERE a.profile_id=? AND a.family='workouts'",
      [tx.profileId],
    )) {
      if (_digest(localBytes(_decode(row['binding_bytes']))) != attachmentId) {
        _deny('remote_attachment_mismatch');
      }
      final command = _decode(row['request_bytes']),
          target = command['target'] as Map;
      add(
        target['kind'] == 'exercise' ? 'definitions' : 'workouts',
        target['id'] as String,
      );
      final workout = command['workout'];
      if (workout is Map) {
        for (final base in workout['definition_bases'] as List? ?? []) {
          add('definitions', ((base as Map)['target'] as Map)['id'] as String);
        }
      }
      if (row['outcome_bytes'] != null) {
        final out = _decode(row['outcome_bytes']);
        if (const ['acknowledged', 'read_back'].contains(out['kind']) &&
            out['record'] is Map) {
          record(Map<String, dynamic>.from(out['record'] as Map));
        }
      }
    }
    final attachment = await _attachment(tx, attachmentId),
        active = await _active(tx, attachmentId);
    final unknown = await _unknownLocalHistory(tx, attachment);
    final blockedRecords = <String>{
      for (final v in active?['blocked_local_records'] as List? ?? [])
        v as String,
    };
    if (unknown) {
      for (final table in const {
        'sessions': 'workout',
        'exercises': 'exercise',
      }.entries) {
        for (final row in await tx.getAll(
          'SELECT id FROM ${table.key} WHERE profile_id=?',
          [tx.profileId],
        )) {
          blockedRecords.add('${table.value}/${row['id']}');
        }
      }
    }
    final blockedOps = <String>{
      for (final v in active?['blocked_operations'] as List? ?? []) v as String,
    };
    for (final row in await tx.getAll(
      "SELECT operation_id FROM animus_operation_origins WHERE profile_id=? AND (attachment_id=? OR attachment_id IS NULL)",
      [tx.profileId, attachmentId],
    )) {
      blockedOps.add(row['operation_id'] as String);
    }
    final sorted = targets.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return {
      'format': 'alkion-animus-finite-stage/1',
      'coverage': 'incomplete-known-targets',
      'targets': sorted.map((v) => v.toJson()).toList(),
      'blocked_operations': blockedOps.toList()..sort(),
      'blocked_local_records': blockedRecords.toList()..sort(),
      'manual_disposition': blockedRecords.isNotEmpty,
    };
  }

  Future<RecoveryStage> startStage(
    RemoteRecoveryBinding binding,
    RemoteExchange discovery, {
    required String generation,
    required String probeId,
    required List<int> body,
    required void Function() current,
  }) => db.writeTransaction((tx) async {
    current();
    final intent = await _exchange(tx, discovery),
        attachment = await _attachment(tx, binding.id);
    if (discovery.attachmentId != binding.id ||
        !_validGeneration(generation) ||
        intent['path_kind'] != 'discovery' ||
        intent['owner_id'] != _owner ||
        intent['state'] != 'pending' ||
        attachment['state'] != 'recovery_required' ||
        attachment['revision'] != intent['attachment_revision']) {
      _deny();
    }
    RemoteRecoveryArchive._(
      await tx.get(
        'SELECT * FROM animus_recovery_archives WHERE profile_id=? AND archive_id=?',
        [tx.profileId, attachment['archive_id']],
      ),
    );
    final inventory = await _reviewInventory(tx, binding.id, probeId);
    final id = _uuid.v4(), revision = (attachment['revision'] as int) + 1;
    inventory.addAll({
      'owner': _owner,
      'attachment_revision': revision,
      'archive_id': attachment['archive_id'],
      'binding_hash': binding.id,
    });
    await _append(tx, discovery, 200, generation, body);
    await tx.execute(
      "UPDATE animus_exchange_intents SET state='settled' WHERE profile_id=? AND exchange_id=?",
      [tx.profileId, discovery.id],
    );
    await tx.execute(
      "UPDATE animus_recovery_stages SET state='invalid' WHERE profile_id=? AND attachment_id=? AND state='staging'",
      [tx.profileId, binding.id],
    );
    if (localBytes(inventory).length > 64 * 1024 * 1024) {
      _deny('remote_stage_resource_limit');
    }
    await tx.execute(
      "INSERT INTO animus_recovery_stages VALUES(?,?,?,?,?,'staging',?)",
      [tx.profileId, id, binding.id, generation, localBytes(inventory), _now()],
    );
    await tx.execute(
      'UPDATE animus_remote_attachments SET revision=? WHERE profile_id=? AND attachment_id=?',
      [revision, tx.profileId, binding.id],
    );
    current();
    return _stage(tx, id);
  }, expected: db.token);

  Future<RemoteExchange> beginStageRead(
    String stageId,
    RecoveryTarget target,
    void Function() current, {
    bool adoption = false,
  }) => db.writeTransaction((tx) async {
    current();
    final stage = await _stage(tx, stageId);
    await _stageLease(tx, stage, verified: adoption);
    if (!stage.targets.any((v) => v.key == target.key)) {
      _deny('remote_inventory_invalid');
    }
    final result = await _insertReviewExchange(
      tx,
      stage.attachmentId,
      stage.inventory['attachment_revision'] as int,
      stage.generation,
      RemoteApiRequest.read(target.dataset, target.id),
    );
    current();
    return result;
  }, expected: db.token);

  Future<RecoveryStage> finishStageRead(
    String stageId,
    RemoteExchange exchange,
    RecoveryTarget target, {
    required int status,
    required List<int> body,
    required String generation,
    required void Function() current,
    bool adoption = false,
  }) => db.writeTransaction((tx) async {
    current();
    final stage = await _stage(tx, stageId);
    await _stageLease(tx, stage, verified: adoption);
    final intent = await _exchange(tx, exchange);
    if (intent['state'] != 'pending' ||
        intent['owner_id'] != _owner ||
        exchange.attachmentId != stage.attachmentId ||
        intent['attachment_revision'] !=
            stage.inventory['attachment_revision'] ||
        intent['path_kind'] != 'directRead' ||
        intent['dataset'] != target.dataset ||
        intent['target_id'] != target.id ||
        generation != stage.generation ||
        exchange.generation != generation ||
        !const [200, 404].contains(status)) {
      _deny('invalid_remote_response');
    }
    await _append(tx, exchange, status, generation, body);
    if (!adoption) {
      await tx.execute(
        'INSERT INTO animus_recovery_stage_rows VALUES(?,?,?,?,?,?)',
        [
          tx.profileId,
          stage.id,
          target.dataset,
          target.id,
          status == 200 ? 'available' : 'missing',
          Uint8List.fromList(body),
        ],
      );
      if (status == 200 && target.dataset == 'workouts') {
        final record = decodeStrictAnimusJson(utf8.decode(body)) as Map;
        final workout = record['workout'] as Map;
        final targets = stage.targets;
        for (final base in workout['reference_bases'] as List? ?? []) {
          final id = ((base as Map)['target'] as Map)['id'] as String;
          if (!_validGeneration(id)) _deny('remote_inventory_invalid');
          if (!targets.any((t) => t.dataset == 'definitions' && t.id == id)) {
            targets.add(RecoveryTarget('definitions', id, const []));
          }
        }
        if (targets.length > 512) _deny('remote_stage_resource_limit');
        stage.inventory['targets'] = targets.map((v) => v.toJson()).toList();
        await tx.execute(
          'UPDATE animus_recovery_stages SET inventory_bytes=? WHERE profile_id=? AND stage_id=? AND state=\'staging\'',
          [localBytes(stage.inventory), tx.profileId, stage.id],
        );
      }
    }
    await tx.execute(
      "UPDATE animus_exchange_intents SET state='settled' WHERE profile_id=? AND exchange_id=?",
      [tx.profileId, exchange.id],
    );
    current();
    return _stage(tx, stage.id);
  }, expected: db.token);

  Future<RecoveryStage> verifyStage(
    String stageId,
    void Function() current,
  ) => db.writeTransaction((tx) async {
    current();
    final stage = await _stage(tx, stageId);
    await _stageLease(tx, stage);
    final rows = await tx.getAll(
      'SELECT * FROM animus_recovery_stage_rows WHERE profile_id=? AND stage_id=?',
      [tx.profileId, stage.id],
    );
    if (rows.length != stage.targets.length ||
        await tx.getOptional(
              "SELECT 1 FROM animus_exchange_intents WHERE profile_id=? AND attachment_id=? AND state='pending'",
              [tx.profileId, stage.attachmentId],
            ) !=
            null) {
      _deny('remote_stage_incomplete');
    }
    final comparisons = <String, String>{};
    for (final target in stage.targets) {
      final row = rows
          .where(
            (v) =>
                v['dataset'] == target.dataset && v['target_id'] == target.id,
          )
          .single;
      if (!const ['available', 'missing'].contains(row['availability'])) {
        _deny('remote_stage_incomplete');
      }
      final bytes = (row['record_bytes'] as List).cast<int>();
      final same =
          row['availability'] == 'available' &&
          target.expected.any(
            (v) =>
                _digest(localBytes(v)) ==
                _digest(localBytes(decodeStrictAnimusJson(utf8.decode(bytes)))),
          );
      comparisons[target.key] =
          (row['availability'] == 'missing'
                  ? target.expected.isEmpty
                        ? RecoveryComparison.uncertainMissing
                        : RecoveryComparison.acknowledgedMissing
                  : target.expected.isEmpty
                  ? RecoveryComparison.available
                  : same
                  ? RecoveryComparison.unchanged
                  : RecoveryComparison.changed)
              .name;
    }
    stage.inventory['comparisons'] = comparisons;
    await tx.execute(
      "UPDATE animus_recovery_stages SET inventory_bytes=?,state='verified' WHERE profile_id=? AND stage_id=? AND state='staging'",
      [localBytes(stage.inventory), tx.profileId, stage.id],
    );
    current();
    return _stage(tx, stage.id);
  }, expected: db.token);

  Future<void> invalidateStage(String stageId) => db.writeTransaction((
    tx,
  ) async {
    await tx.execute(
      "UPDATE animus_recovery_stages SET state='invalid' WHERE profile_id=? AND stage_id=? AND state='staging'",
      [tx.profileId, stageId],
    );
  }, expected: db.token);

  Future<void> adoptStage(
    String stageId,
    String generation,
    void Function() current,
  ) => db.writeTransaction((tx) async {
    current();
    final stage = await _stage(tx, stageId),
        attachment = await _stageLease(
          tx,
          await _stage(tx, stageId),
          verified: true,
        );
    if (generation != stage.generation ||
        stage.inventory['coverage'] != 'incomplete-known-targets' ||
        await tx.getOptional(
              "SELECT 1 FROM animus_exchange_intents WHERE profile_id=? AND attachment_id=? AND state='pending'",
              [tx.profileId, stage.attachmentId],
            ) !=
            null) {
      _deny('remote_stage_incomplete');
    }
    RemoteRecoveryArchive._(
      await tx.get(
        'SELECT * FROM animus_recovery_archives WHERE profile_id=? AND archive_id=?',
        [tx.profileId, attachment['archive_id']],
      ),
    );
    final prior = await tx.localState(
      LocalStateKind.semanticSetting,
      _activeKey(stage.attachmentId),
    );
    await tx.putLocalState(
      LocalStateKind.semanticSetting,
      _activeKey(stage.attachmentId),
      localBytes({
        'format': 'alkion-animus-active-stage/1',
        'stage_id': stage.id,
        'generation': generation,
        'archive_id': attachment['archive_id'],
        'coverage': stage.inventory['coverage'],
        'blocked_operations': stage.inventory['blocked_operations'],
        'blocked_local_records': stage.inventory['blocked_local_records'],
        'adopted_at': _now(),
      }),
      expectedRevision: prior?['revision'] as int? ?? 0,
    );
    await tx.execute(
      "UPDATE animus_remote_attachments SET recovery_generation=?,state='ready',revision=revision+1 WHERE profile_id=? AND attachment_id=?",
      [generation, tx.profileId, stage.attachmentId],
    );
    current();
  }, expected: db.token);

  Future<RemoteExchange> beginAdoptionDiscovery(
    String stageId,
    void Function() current,
  ) => db.writeTransaction((tx) async {
    current();
    final stage = await _stage(tx, stageId);
    await _stageLease(tx, stage, verified: true);
    final result = await _insertReviewExchange(
      tx,
      stage.attachmentId,
      stage.inventory['attachment_revision'] as int,
      stage.generation,
      const RemoteApiRequest.discovery(),
    );
    current();
    return result;
  }, expected: db.token);

  Future<void> settleAdoptionDiscovery(
    String stageId,
    RemoteExchange exchange,
    String generation,
    List<int> body,
    void Function() current,
  ) => db.writeTransaction((tx) async {
    current();
    final stage = await _stage(tx, stageId);
    await _stageLease(tx, stage, verified: true);
    final intent = await _exchange(tx, exchange);
    if (generation != stage.generation ||
        exchange.attachmentId != stage.attachmentId ||
        exchange.generation != stage.generation ||
        intent['attachment_revision'] !=
            stage.inventory['attachment_revision'] ||
        intent['path_kind'] != 'discovery' ||
        intent['state'] != 'pending' ||
        intent['owner_id'] != _owner) {
      _deny('remote_stage_stale');
    }
    await _append(tx, exchange, 200, generation, body);
    await tx.execute(
      "UPDATE animus_exchange_intents SET state='settled' WHERE profile_id=? AND exchange_id=?",
      [tx.profileId, exchange.id],
    );
    current();
  }, expected: db.token);

  Future<bool> operationBlocked(String attachmentId, String operationId) =>
      db.readTransaction(
        (tx) async =>
            ((await _active(tx, attachmentId))?['blocked_operations']
                        as List? ??
                    [])
                .contains(operationId),
        expected: db.token,
      );

  Future<RemoteExchange> beginReviewedRetry(
    String attachmentId,
    String stageId,
    RemoteApiRequest request,
    void Function() current, {
    required String journalId,
  }) => db.writeTransaction((tx) async {
    current();
    final state = await _ready(tx, attachmentId),
        active = await _active(tx, attachmentId);
    if (request.path != RemoteApiPath.action ||
        active?['stage_id'] != stageId ||
        active?['generation'] != state.generation ||
        !(active?['blocked_operations'] as List? ?? []).contains(
          request.operationId,
        )) {
      _deny('remote_review_scope_mismatch');
    }
    final attempt = await tx.getOptional(
      "SELECT * FROM operation_attempts WHERE profile_id=? AND family='workouts' AND operation_id=? AND attempt_id=?",
      [tx.profileId, request.operationId, request.attemptId],
    );
    if (attempt == null ||
        attempt['request_hash'] != request.requestHash ||
        _digest((attempt['request_bytes'] as List).cast<int>()) !=
            request.requestHash ||
        _digest(localBytes(_decode(attempt['binding_bytes']))) !=
            attachmentId) {
      _deny('remote_attempt_mismatch');
    }
    final result = await _insertReviewExchange(
      tx,
      attachmentId,
      state.revision,
      state.generation,
      request,
      journalId: journalId,
    );
    current();
    return result;
  }, expected: db.token);
}
