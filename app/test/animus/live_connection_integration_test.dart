import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/adapters/auth.dart';
import 'package:alkion/animus/adapters/auth_browser.dart';
import 'package:alkion/animus/adapters/http.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/connection.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:alkion/animus/ports.dart';
import 'package:alkion/animus/probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Opt-in real-provider/public-API check. The external fixture owns only fresh
/// synthetic accounts and administrative changes. This client consumes generic
/// public configuration and a private browser/control bridge; it has no database
/// or provider-administration credentials. No record body enters a receipt.
void main() {
  final input = Platform.environment['ANIMUS_LIVE_FIXTURE'];
  test(
    'real OIDC and public API connection acceptance',
    () async {
      final fixture = _Fixture(input!);
      final receipts = <String, String>{};
      final secrets = _MemorySecrets();
      final owners = <_Owner>[];
      _Owner owner(Map<String, String> values, {int generation = 1}) {
        final result = _Owner(fixture, values, secrets, generation);
        owners.add(result);
        return result;
      }

      void passed(String name, bool value) {
        receipts[name] = value ? 'PASS' : 'FAIL';
        if (!value) throw StateError('live acceptance: $name');
      }

      try {
        final primary = owner(fixture.primary);
        await primary.controller.connect();
        passed(
          'login_staged_without_read_or_retention',
          primary.controller.state ==
                  AnimusConnectionState.awaitingConfirmation &&
              primary.api.calls == 0 &&
              secrets.values.isEmpty &&
              primary.authAudit.codeExchanges == 1,
        );
        if (fixture.data['auth_only'] == true) return;
        final identity = primary.controller.identity!;
        await primary.controller.confirm();
        passed(
          'confirmed_direct_read',
          primary.controller.state == AnimusConnectionState.verified &&
              primary.api.statuses.last == 200 &&
              secrets.values.length == 1,
        );

        // Wait for this disposable provider's genuine short-lived credential;
        // neither client time nor JWT claims are altered by this test.
        final idleAuthRequests = primary.authAudit.requests;
        final idleApiCalls = primary.api.calls;
        await fixture.command('await_expiry');
        passed(
          'expiry_idle_makes_no_remote_request',
          primary.authAudit.requests == idleAuthRequests &&
              primary.api.calls == idleApiCalls,
        );
        await primary.controller.verify();
        passed(
          'expired_access_refreshed_once',
          primary.controller.state == AnimusConnectionState.verified &&
              primary.authAudit.refreshExchanges == 1,
        );

        await fixture.command('revoke_access');
        final beforeRefresh = primary.authAudit.refreshExchanges;
        final beforeCalls = primary.api.calls;
        await primary.controller.verify();
        passed(
          'revoked_access_bounded_refresh',
          primary.api.statuses.contains(401) &&
              primary.api.calls - beforeCalls <= 2 &&
              primary.authAudit.refreshExchanges - beforeRefresh == 1 &&
              (primary.controller.state == AnimusConnectionState.verified ||
                  primary.controller.state ==
                      AnimusConnectionState.unavailable),
        );

        await primary.controller.disconnect();
        final disconnectedCalls = primary.api.calls;
        await primary.controller.verify();
        passed(
          'disconnect_fences_read_and_removes_secret',
          primary.controller.state == AnimusConnectionState.disconnected &&
              primary.controller.identity == null &&
              primary.api.calls == disconnectedCalls &&
              secrets.values.isEmpty,
        );
        await primary.controller.connect();
        await primary.controller.confirm();
        passed(
          'reconnect_requires_confirmation_and_read',
          primary.controller.state == AnimusConnectionState.verified,
        );

        final revocable = owner(fixture.revocable);
        await revocable.controller.connect();
        await revocable.controller.confirm();
        passed(
          'revocable_client_baseline',
          revocable.controller.state == AnimusConnectionState.verified,
        );
        await fixture.command('revoke_grant');
        await revocable.controller.verify();
        passed(
          'revoked_grant_denied',
          revocable.controller.state == AnimusConnectionState.accessDenied &&
              revocable.api.statuses.last == 403,
        );
        await fixture.command('restore_grant');
        await revocable.controller.verify();
        passed(
          'restored_grant_read',
          revocable.controller.state == AnimusConnectionState.verified,
        );
        await fixture.command('revoke_reader');
        await revocable.controller.verify();
        passed(
          'revoked_reader_denied',
          revocable.controller.state == AnimusConnectionState.accessDenied &&
              revocable.api.statuses.last == 403,
        );
        // Replacement admission has a new identity: the previous configuration
        // remains denied, and fresh configuration needs account confirmation.
        final replacement = await fixture.command('restore_reader');
        await revocable.controller.verify();
        passed(
          'old_reader_stays_denied_after_replacement',
          revocable.controller.state == AnimusConnectionState.accessDenied,
        );
        final replaced = owner({
          ...fixture.revocable,
          'ALKION_ANIMUS_READ_ADMISSION':
              replacement['read_admission'] as String,
        });
        await replaced.controller.connect();
        await replaced.controller.confirm();
        passed(
          'replacement_reader_explicit_reconnect',
          replaced.controller.state == AnimusConnectionState.verified,
        );

        final wrongSpace = owner({
          ...fixture.primary,
          'ALKION_ANIMUS_DATA_SPACE_ID': fixture.wrongSpace,
        });
        await wrongSpace.controller.connect();
        await wrongSpace.controller.confirm();
        passed(
          'wrong_space_denied',
          wrongSpace.controller.state == AnimusConnectionState.accessDenied &&
              wrongSpace.api.statuses.last == 403,
        );
        await fixture.command('other_account');
        final other = owner(fixture.primary, generation: 2);
        await other.controller.connect();
        passed(
          'other_account_staged_without_inheritance',
          other.controller.state ==
                  AnimusConnectionState.awaitingConfirmation &&
              !other.controller.identity!.sameAccount(identity) &&
              other.api.calls == 0,
        );
        await other.controller.confirm();
        passed(
          'other_account_denied',
          other.controller.state == AnimusConnectionState.accessDenied &&
              other.api.statuses.last == 403,
        );
        await fixture.command('owner_account');

        await primary.controller.close();
        final generation = owner(fixture.primary, generation: 3);
        await generation.controller.restore();
        passed(
          'new_generation_restore_is_inert',
          generation.controller.state == AnimusConnectionState.disconnected &&
              generation.api.calls == 0 &&
              generation.authAudit.requests == 0,
        );

        final offline = owner({
          ...fixture.primary,
          'ALKION_ANIMUS_API_ORIGIN': fixture.offlineOrigin,
        }, generation: 4);
        await offline.controller.connect();
        await offline.controller.confirm();
        passed(
          'offline_read_distinct',
          offline.controller.state == AnimusConnectionState.unavailable &&
              offline.controller.issue == AnimusConnectionIssue.offline,
        );
        await offline.controller.close();
        final restarted = owner({
          ...fixture.primary,
          'ALKION_ANIMUS_API_ORIGIN': fixture.offlineOrigin,
        }, generation: 4);
        await restarted.controller.restore();
        passed(
          'offline_restart_remains_explicit_unavailable',
          restarted.controller.state == AnimusConnectionState.unavailable &&
              restarted.controller.issue == AnimusConnectionIssue.offline,
        );

        for (final fence in ['cancel', 'generation', 'close']) {
          await fixture.command('hold_callback');
          final pending = owner(fixture.primary, generation: 5);
          final work = pending.controller.connect();
          await fixture.command('await_callback');
          if (fence == 'cancel') {
            await pending.controller.cancel();
          } else {
            await pending.controller.close();
          }
          await fixture.command('release_callback');
          await work;
          await pending.controller.confirm();
          await pending.controller.verify();
          passed(
            '${fence}_fences_late_callback',
            pending.api.calls == 0 && pending.authAudit.codeExchanges == 0,
          );
          if (fence == 'generation') {
            final next = owner(fixture.primary, generation: 6);
            await next.controller.restore();
            passed(
              'replacement_generation_does_not_adopt_pending_login',
              next.controller.state == AnimusConnectionState.disconnected &&
                  next.api.calls == 0 &&
                  next.authAudit.requests == 0,
            );
          }
        }
      } finally {
        for (final owner in owners) {
          await owner.controller.close();
        }
        fixture.writeReport({
          'version': 1,
          'cases': receipts,
          'passed': receipts.values.where((value) => value == 'PASS').length,
          'failed': receipts.values.where((value) => value == 'FAIL').length,
          'production_oidc_sdk': true,
          'production_http_probe': true,
          'real_linux_callback_listener': true,
          'secret_store': 'memory_transport_test_only',
          'native_plugin_qualification': 'separate_checkpoint_required',
          'remote_record_retention': false,
          'local_store_opened': false,
          'diagnostics': [
            for (final owner in owners)
              {
                'state': owner.controller.state.name,
                'issue': owner.controller.issue?.name,
                'auth_requests': owner.authAudit.requests,
                'auth_statuses': owner.authAudit.statuses,
                'code_exchanges': owner.authAudit.codeExchanges,
                'refresh_exchanges': owner.authAudit.refreshExchanges,
                'browser_launches': owner.authAudit.browserLaunches,
                'api_calls': owner.api.calls,
                'api_statuses': owner.api.statuses,
              },
          ],
        });
      }
    },
    skip: input == null ? 'Set private ANIMUS_LIVE_FIXTURE to opt in.' : false,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

final class _Fixture {
  _Fixture(String path) : data = jsonDecode(File(path).readAsStringSync());
  final Map<String, dynamic> data;
  Map<String, String> get primary => Map<String, String>.from(data['primary']);
  Map<String, String> get revocable =>
      Map<String, String>.from(data['revocable']);
  String get wrongSpace => data['wrong_space'] as String;
  String get offlineOrigin => data['offline_origin'] as String;

  Future<Map<String, dynamic>> command(String action) =>
      request('command', {'action': action});

  Future<Map<String, dynamic>> request(
    String endpoint,
    Map<String, Object?> body,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(data['bridge_url'] as String).resolve('/$endpoint'),
      );
      final encoded = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = encoded.length;
      request.add(encoded);
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200 || raw.length > 65536) {
        throw StateError('live fixture unavailable');
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  void writeReport(Map<String, Object?> report) {
    File(data['report_path'] as String).writeAsStringSync(jsonEncode(report));
  }
}

final class _Owner {
  _Owner(
    _Fixture fixture,
    Map<String, String> values,
    _MemorySecrets secrets,
    int generation,
  ) {
    final config = AnimusConfig.fromEnvironment(
      values,
      platform: AnimusPlatform.linux,
    )!;
    final auth = OidcAnimusAuth(
      scope: AnimusScope(
        installationId: '00000000-0000-4000-8000-000000000001',
        profileId: '00000000-0000-4000-8000-000000000002',
        generation: generation,
        config: config,
      ),
      secrets: secrets,
      browser: SystemAnimusBrowser(
        platform: AnimusPlatform.linux,
        launch: (uri) async {
          authAudit.browserLaunches++;
          final response = await fixture.request('authorize', {
            'authorization_uri': uri.toString(),
          });
          return response['launched'] == true;
        },
      ),
      httpClientFactory: () => _AuditedAuthClient(authAudit),
    );
    controller = AnimusConnectionController(
      config: config,
      auth: auth,
      probe: AnimusProbe(config: config, http: api),
    );
  }
  final api = _AuditedHttp();
  final authAudit = _AuthAudit();
  late final AnimusConnectionController controller;
}

final class _MemorySecrets implements AnimusSecretStore {
  final values = <String, String>{};
  @override
  Future<void> checkAvailability(AnimusScope scope) async {}
  @override
  Future<String?> read(AnimusScope scope) async => values[scope.storageKey];
  @override
  Future<void> write(AnimusScope scope, String value) async {
    values[scope.storageKey] = value;
  }

  @override
  Future<void> delete(AnimusScope scope) async =>
      values.remove(scope.storageKey);
}

final class _AuthAudit {
  int requests = 0;
  final statuses = <int>[];
  int browserLaunches = 0;
  int codeExchanges = 0;
  int refreshExchanges = 0;
}

final class _AuditedAuthClient extends http.BaseClient {
  _AuditedAuthClient(this.audit);
  final _AuthAudit audit;
  final http.Client inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    audit.requests++;
    if (request is http.Request && request.method == 'POST') {
      final grant = request.bodyFields['grant_type'];
      if (grant == 'authorization_code') audit.codeExchanges++;
      if (grant == 'refresh_token') audit.refreshExchanges++;
    }
    final response = await inner.send(request);
    audit.statuses.add(response.statusCode);
    return response;
  }

  @override
  void close() => inner.close();
}

final class _AuditedHttp implements AnimusHttpPort {
  final inner = IoAnimusHttpPort();
  int calls = 0;
  final statuses = <int>[];
  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) async {
    calls++;
    final response = await inner.get(
      uri: uri,
      headers: headers,
      maxResponseBytes: maxResponseBytes,
      timeout: timeout,
    );
    statuses.add(response.statusCode);
    return response;
  }

  @override
  Future<void> cancel() => inner.cancel();
  @override
  Future<void> close() => inner.close();
}
