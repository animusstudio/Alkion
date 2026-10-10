import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:powersync/powersync.dart';

import '../auth/auth_store.dart';
import '../capture/capture_transport.dart';
import '../capture/source_write_gate.dart';

/// Bridges PowerSync to the Go API.
///
/// - [fetchCredentials] mints a short-lived PowerSync token via
///   POST /auth/powersync-token (Bearer = ACCESS token). The response's
///   `endpoint` is POWERSYNC_URL (dev: http://localhost:8090) and `token` is an
///   RS256 JWT (aud workout-tracker-powersync, 5m). The SDK caches it and only
///   calls this again near expiry.
/// - [uploadData] drains the local CRUD queue and POSTs it to /sync/upload
///   using the ACCESS token (NOT the PowerSync token).
///
/// UPLOAD CONTRACT: the server always returns 2xx for bad/ownership-rejected
/// data (a thrown error or 4xx here would PERMANENTLY block the upload queue).
/// We therefore only rethrow on transient failures (network / 5xx) so the SDK
/// retries the same batch; on 2xx we complete the transaction.
///
/// DATA CAPTURE: every upload is one admitted operation, from reading the
/// next batch through its `complete()` (or failure), so a capture can await
/// it and never sees a half-finished one. While a capture has transport
/// admission closed, new uploads and credential fetches are refused (thrown
/// as transient errors, so nothing is dropped) and no token is refreshed.
class WorkoutConnector extends PowerSyncBackendConnector {
  WorkoutConnector(this.auth,
      {http.Client? client, TransportAdmission? admission})
      : _http = client ?? http.Client(),
        _admission = admission ?? TransportAdmission.instance;

  final AuthStore auth;
  final http.Client _http;
  final TransportAdmission _admission;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    _admission.ensureOpen('sync.credentials');
    final access = await auth.ensureAccessToken();
    if (access == null) return null; // logged out -> SDK stays disconnected

    var res = await _postPowerSyncToken(access);
    if (res.statusCode == 401) {
      // Access token expired: rotate once and retry (never while a capture
      // has transport admission closed).
      _admission.ensureOpen('sync.credentials_refresh');
      final fresh = await auth.refresh();
      if (fresh == null) return null;
      res = await _postPowerSyncToken(fresh);
    }
    if (res.statusCode != 200) {
      throw Exception('powersync-token failed (${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return PowerSyncCredentials(
      endpoint: body['endpoint'] as String,
      token: body['token'] as String,
    );
  }

  Future<http.Response> _postPowerSyncToken(String accessToken) {
    return _http.post(
      Uri.parse('$apiBaseUrl/auth/powersync-token'),
      headers: {'authorization': 'Bearer $accessToken'},
    );
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    await _admission.runUpload((attempt) => runSourceWrite(
          'sync.upload',
          (_) async {
            final tx = await database.getNextCrudTransaction();
            if (tx == null) return;
            attempt.batch(
                tx.transactionId, [for (final op in tx.crud) op.clientId]);
            // Throws on transient (network / 5xx / 401) -> tx is NOT
            // completed and the SDK retries the same batch. Returns normally
            // on 2xx (or an unexpected 4xx, treated as accepted) so we then
            // clear the queue.
            await uploadBatch(tx.crud, attempt: attempt);
            await tx.complete();
            attempt.completed();
          },
        ));
  }

  /// Visible for testing: POST one batch of CRUD ops to /sync/upload with the
  /// ACCESS token. Throws ONLY on transient failures (the server always returns
  /// 2xx for bad data; a throw here would permanently block the upload queue).
  /// [attempt] records when the request went out and what was answered.
  Future<void> uploadBatch(List<CrudEntry> crud,
      {UploadAttempt? attempt}) async {
    // While a capture has transport admission closed an admitted upload
    // still finishes, but never refreshes a token.
    final access = _admission.isOpen
        ? await auth.ensureAccessToken()
        : (auth.sessionExpired.value ? null : auth.accessToken);
    if (access == null) {
      // No way to authenticate right now; throw so the SDK retries later
      // (transient from the queue's perspective — nothing is dropped).
      throw Exception('no access token for upload');
    }
    attempt?.requestSent();
    final res = await _http.post(
      Uri.parse('$apiBaseUrl/sync/upload'),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $access',
      },
      body: jsonEncode({'batch': buildUploadBatch(crud)}),
    );
    attempt?.responseReceived(res.statusCode);
    if (res.statusCode == 401) {
      // Access token expired mid-upload: refresh and let the SDK retry.
      if (_admission.isOpen) await auth.refresh();
      throw Exception('upload unauthorized; refreshed, will retry');
    }
    if (res.statusCode >= 500) {
      // Transient server error: do not complete -> SDK retries the same batch.
      throw Exception('upload transient error (${res.statusCode})');
    }
    // Any 2xx (including silently-skipped bad ops) => accepted; the caller
    // completes the transaction so these ops leave the queue.
  }

  /// Visible for testing: pure CrudEntry -> wire shape. `op.toJson()` yields the
  /// uppercase "PUT"/"PATCH"/"DELETE" the Go handler switches on; the table name
  /// is sent under `table` (the handler also accepts `type`). `opData` is null
  /// for DELETE and only the changed columns for PATCH.
  static List<Map<String, dynamic>> buildUploadBatch(List<CrudEntry> crud) {
    return crud
        .map((op) => {
              'op': op.op.toJson(),
              'table': op.table,
              'id': op.id,
              'data': op.opData ?? <String, dynamic>{},
            })
        .toList();
  }
}
