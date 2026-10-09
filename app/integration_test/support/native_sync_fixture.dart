// A disposable PowerSync sync service for native quiescence qualification.
//
// The fixture runs the REAL SDK and native core against a loopback HTTP
// server that speaks the sync-stream protocol (NDJSON `checkpoint`, `data`,
// `checkpoint_complete` lines) with synthetic rows and a synthetic token.
// Nothing about the SDK, its sync isolate or the core is replaced: every line
// the test releases is applied by the core through `powersync_control(...)`
// inside a write transaction on the shared pool writer, exactly as with a
// real service.
//
// Pausing the apply continuation: [NativeSyncFixture.pauseNextApply] leases
// the shared pool writer from the app isolate (`database.writeLock`, the same
// single writer every isolate of the process shares) and only then releases
// the staged `checkpoint_complete` line. The sync isolate receives the line
// and its `powersync_control('line_text', ...)` write transaction waits for
// that writer, so the core's apply step cannot start until
// [NativeSyncFixture.releaseApply].
//
// The pool exposes no waiter count, so the pause cannot be observed from
// outside before it ends. [NativeSyncFixture.waitUntilApplyPaused] therefore
// only waits until the line was flushed to the client socket plus a settle
// period, with the row still unapplied. It is not a positive observation.
// The test proves the pause from the method's own completions: the real
// `disconnect()` stays pending while the writer is held, and when it returns
// the row is already applied. The sync isolate discards lines it receives
// after its abort, so that row was received, and its apply pending, before
// the disconnect began.
//
// Because this pause holds the same writer the method's writer barrier
// waits for, "the observation has not completed" is not evidence by itself;
// the test watches the disconnect completion directly.
//
// A foreign SQLite write lock (`BEGIN IMMEDIATE` on a separate connection)
// is NOT a pause: the core's transaction then fails with SQLITE_BUSY and the
// line is dropped. It is not used.
//
// Every directory is a fresh temporary directory; all values are synthetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:powersync/powersync.dart';
import 'package:sqlite_async/sqlite_async.dart' show AbortException;
import 'package:workout_tracker/capture/capture_profile.dart';
import 'package:workout_tracker/sync/schema.dart';

const _bucket = 'synthetic-bucket';
const _syntheticToken = 'synthetic-token-not-a-credential';

/// Opens a fresh synthetic database that qualifies as exactly [profile],
/// with its own loopback sync service. Close it with [NativeSyncFixture.close].
Future<NativeSyncFixture> openNativeSyncFixture(
  QualifiedProfile profile, {
  bool queue = false,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'reps-native-sync-fixture',
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final database = PowerSyncDatabase(
    schema: schema,
    path: '${directory.path}/workout-tracker.db',
  );
  await database.initialize();
  final fixture = NativeSyncFixture._(
    directory,
    server,
    database,
    '${directory.path}/workout-tracker.db',
  );
  server.listen(fixture._handle);

  if (queue) {
    // Local writes waiting to upload. The connector never acknowledges them,
    // so they must survive every observation unchanged.
    await database.execute(
      "INSERT INTO exercises (id, name, slug) VALUES ('local-ex-1', 'Local one', 'local-one')",
    );
    await database.execute(
      "INSERT INTO exercises (id, name, slug) VALUES ('local-ex-2', 'Local two', 'local-two')",
    );
  }

  final qualified = await qualifyCaptureProfile(database, profile.runtime);
  if (qualified.evidenceDigest != profile.evidenceDigest ||
      qualified.profileId != profile.profileId) {
    await fixture.close();
    throw StateError('fixture database does not qualify as the given profile');
  }
  return fixture;
}

/// A row the synthetic service sends in a checkpoint.
class SyntheticRow {
  const SyntheticRow(this.id, this.name);

  final String id;
  final String name;
}

class NativeSyncFixture {
  NativeSyncFixture._(
    this.directory,
    this._server,
    this.database,
    this.databasePath,
  );

  final Directory directory;
  final HttpServer _server;
  final PowerSyncDatabase database;
  final String databasePath;

  /// Sync-stream requests received, i.e. connection attempts by the SDK.
  int streamRequests = 0;

  /// `uploadData` calls the SDK made; none is ever acknowledged.
  int uploadCalls = 0;

  int _lastOpId = 0;
  int? _stagedOpId;
  StreamController<String>? _lines;
  Completer<void> _streamOpened = Completer<void>();
  Completer<void>? _uploadGate;
  Completer<void>? _applyLock;
  Future<void>? _applyLockReleased;
  int _flushedLines = 0;
  bool _closed = false;

  String get endpoint => 'http://${_server.address.host}:${_server.port}';

  /// Connects the SDK to the synthetic service; completes once its sync
  /// stream request has arrived.
  Future<void> connect() async {
    _streamOpened = Completer<void>();
    await database.connect(
      connector: _SyntheticConnector(this),
      options: const SyncOptions(retryDelay: Duration(milliseconds: 200)),
    );
    await _streamOpened.future.timeout(const Duration(seconds: 20));
  }

  /// Sends a whole checkpoint for [rows] and waits until the core applied it.
  Future<void> deliverCheckpoint(List<SyntheticRow> rows) async {
    await stageCheckpoint(rows);
    _send({
      'checkpoint_complete': {'last_op_id': '$_stagedOpId'},
    });
    _stagedOpId = null;
    await _until(
      () async => await _visible(rows.last.id),
      'checkpoint was not applied',
    );
    await settle();
  }

  /// Sends a checkpoint and its data lines but not `checkpoint_complete`;
  /// waits until the core has stored the operations (not yet applied them).
  Future<void> stageCheckpoint(List<SyntheticRow> rows) async {
    final first = _lastOpId + 1;
    _lastOpId += rows.length;
    _stagedOpId = _lastOpId;
    _send({
      'checkpoint': {
        'last_op_id': '$_lastOpId',
        'write_checkpoint': null,
        'buckets': [
          {'bucket': _bucket, 'checksum': 0, 'priority': 3, 'count': _lastOpId},
        ],
      },
    });
    _send({
      'data': {
        'bucket': _bucket,
        'has_more': false,
        'after': null,
        'next_after': '$_lastOpId',
        'data': [
          for (var i = 0; i < rows.length; i++)
            {
              'op_id': '${first + i}',
              'op': 'PUT',
              'object_type': 'exercises',
              'object_id': rows[i].id,
              'checksum': 0,
              'subkey': null,
              'data': jsonEncode({'name': rows[i].name, 'slug': rows[i].id}),
            },
        ],
      },
    });
    await _until(() async {
      final row = await database.get(
        'SELECT COUNT(*) AS n FROM ps_oplog WHERE op_id = ?',
        [_lastOpId],
      );
      return (row['n'] as int) == 1;
    }, 'staged operations were not stored');
    await settle();
  }

  /// Lets non-line events the SDK queued (upload completion, status) run.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  /// Leases the shared pool writer from the app isolate, then releases the
  /// staged `checkpoint_complete`: the core's apply of the staged rows is the
  /// sync isolate's next native continuation and it cannot begin.
  Future<void> pauseNextApply() async {
    final staged = _stagedOpId;
    if (staged == null) {
      throw StateError('stage a checkpoint before pausing its apply');
    }
    if (_applyLock != null) throw StateError('apply already paused');
    final release = _applyLock = Completer<void>();
    final leased = Completer<void>();
    _applyLockReleased = database.writeLock((_) async {
      leased.complete();
      await release.future;
    });
    await leased.future;
    _pausedLine = _flushedLines + 1;
    _send({
      'checkpoint_complete': {'last_op_id': '$staged'},
    });
    _stagedOpId = null;
  }

  int? _pausedLine;

  /// Completes once the released line was flushed to the SDK's socket and
  /// the sync isolate had time to receive it, with the rows in
  /// [unappliedIds] still not applied. Not a positive observation of the
  /// queued apply (see the file comment).
  Future<void> waitUntilApplyPaused({
    List<String> unappliedIds = const [],
  }) async {
    final line = _pausedLine;
    if (_applyLock == null || line == null) {
      throw StateError('apply is not paused');
    }
    await _until(
      () async => _flushedLines >= line,
      'the paused line was never flushed to the client',
    );
    await settle();
    for (final id in unappliedIds) {
      if (await _visible(id)) {
        throw StateError('row $id was applied while the apply was paused');
      }
    }
  }

  /// Returns the shared writer; the paused apply then runs.
  Future<void> releaseApply() async {
    final lock = _applyLock;
    if (lock == null) return;
    _applyLock = null;
    _pausedLine = null;
    lock.complete();
    await _applyLockReleased;
  }

  /// Whether the shared pool writer can be leased right now from the app
  /// isolate. While the sync isolate holds it, it cannot.
  Future<bool> writerAvailable() async {
    try {
      await database.writeLock(
        (_) async {},
        lockTimeout: const Duration(milliseconds: 150),
      );
      return true;
    } on AbortException {
      return false;
    }
  }

  /// Makes the next `uploadData` call block until [releaseUploads].
  void holdUploads() => _uploadGate ??= Completer<void>();

  void releaseUploads() {
    final gate = _uploadGate;
    _uploadGate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// Whether a row with [id] is visible in the public `exercises` view.
  Future<bool> visible(String id) => _visible(id);

  Future<bool> _visible(String id) async {
    final row = await database.getOptional(
      'SELECT id FROM exercises WHERE id = ?',
      [id],
    );
    return row != null;
  }

  /// The upload queue, as ordered raw rows.
  Future<List<Map<String, Object?>>> queue() async => [
    for (final r in await database.getAll(
      'SELECT id, tx_id, data FROM ps_crud ORDER BY id',
    ))
      Map.of(r),
  ];

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    releaseUploads();
    await releaseApply();
    await _lines?.close();
    if (!database.closed) await database.close();
    await _server.close(force: true);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  void _send(Object line) {
    final lines = _lines;
    if (lines == null) throw StateError('no open sync stream');
    lines.add('${jsonEncode(line)}\n');
  }

  Future<void> _handle(HttpRequest request) async {
    final auth = request.headers.value('authorization');
    if (auth != 'Token $_syntheticToken') {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (request.uri.path == '/sync/stream' && request.method == 'POST') {
      await request.drain<void>();
      streamRequests++;
      await _lines?.close();
      final lines = _lines = StreamController<String>();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'application',
          'x-ndjson',
          charset: 'utf-8',
        )
        ..bufferOutput = false;
      if (!_streamOpened.isCompleted) _streamOpened.complete();
      try {
        await for (final line in lines.stream) {
          request.response.add(utf8.encode(line));
          await request.response.flush();
          _flushedLines++;
        }
        await request.response.close();
      } catch (_) {
        // The SDK aborted the request.
      }
      return;
    }
    if (request.uri.path == '/write-checkpoint2.json') {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'data': {'write_checkpoint': '0'},
          }),
        );
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _until(
    Future<bool> Function() condition,
    String failure, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException(failure);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

class _SyntheticConnector extends PowerSyncBackendConnector {
  _SyntheticConnector(this._fixture);

  final NativeSyncFixture _fixture;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async =>
      PowerSyncCredentials(endpoint: _fixture.endpoint, token: _syntheticToken);

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    _fixture.uploadCalls++;
    final gate = _fixture._uploadGate;
    if (gate != null) await gate.future;
    // Never acknowledged: the queue must stay exactly as it was.
    throw const HttpException('synthetic service does not accept uploads');
  }
}
