import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/export/exclusive_publish.dart';
import 'package:alkion/files/private_directory.dart';
import 'package:alkion/identity/alkion_identity.dart';
import 'package:alkion/identity/alkion_profile.dart';
import 'package:alkion/identity/directory_durability.dart';
import 'package:alkion/main.dart' show checkedAlkionSupportRoot;
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/notification_action.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/store/schema.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../tool/alkion_store_recovery.dart' show workflowDraft;
import 'android_lifecycle_test.dart' as lifecycle;

const capabilityFormat = 'alkion-android-capability-checkpoint/1';
const _cases = ['denied', 'revoked', 'exact', 'inexact'];
const _mutable = {'draft/active', 'timer/active', 'timer/notification-action'};

void _require(bool value, String reason) {
  if (!value) throw StateError('capability_$reason');
}

/// Compile-bound predecessor provenance. Version codes come from the guarded
/// campaign's consumed floor, never from logical stage labels.
final class CapabilityStep {
  const CapabilityStep({
    required this.run,
    required this.source,
    required this.priorSource,
    required this.variant,
    required this.caseId,
    required this.phase,
    required this.version,
    required this.priorVersion,
    required this.consumedFloor,
    required this.profileId,
    required this.generation,
    required this.priorReportDigest,
    required this.priorStateDigest,
  });

  final String run, source, priorSource, variant, caseId, phase, profileId;
  final String priorReportDigest, priorStateDigest;
  final int version, priorVersion, consumedFloor, generation;

  void validate() {
    _require(
      RegExp(r'^[a-f0-9]{32}$').hasMatch(run) &&
          [source, priorSource].every(RegExp(r'^[a-f0-9]{40}$').hasMatch) &&
          [
            priorReportDigest,
            priorStateDigest,
          ].every(RegExp(r'^[a-f0-9]{64}$').hasMatch) &&
          variant == AlkionIdentity.current.name &&
          _cases.contains(caseId) &&
          const ['prepare', 'preserve', 'logged'].contains(phase) &&
          (phase != 'logged' || const ['denied', 'revoked'].contains(caseId)) &&
          priorVersion > 0 &&
          consumedFloor >= priorVersion &&
          version > consumedFloor &&
          version <= 2099999999 &&
          RegExp(r'^[a-f0-9-]{36}$').hasMatch(profileId) &&
          generation > 0,
      'explicit_step_inputs_required',
    );
  }

  Map<String, dynamic> get identity => {
    'format': capabilityFormat,
    'run_id': run,
    'source_commit': source,
    'prior_source_commit': priorSource,
    'application_id': AlkionIdentity.applicationId,
    'variant': variant,
    'case_id': caseId,
    'phase': phase,
    'version_code': version,
    'prior_version_code': priorVersion,
    'consumed_version_floor': consumedFloor,
    'profile_id': profileId,
    'generation': generation,
    'prior_report_sha256': priorReportDigest,
    'prior_state_digest': priorStateDigest,
  };

  void requirePredecessor(String raw, Map<String, dynamic> snapshot) {
    validate();
    _require(
      utf8.encode(raw).length <= 1048576 &&
          sha256.convert(utf8.encode(raw)).toString() == priorReportDigest &&
          lifecycle.updateDigest(snapshot) == priorStateDigest &&
          snapshot['application_id'] == AlkionIdentity.applicationId &&
          snapshot['profile_id'] == profileId &&
          snapshot['generation'] == generation,
      'predecessor_digest_or_identity_changed',
    );
    final prior = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    _require(
      prior['run_id'] == run && prior['source_commit'] == priorSource,
      'predecessor_run_or_source_changed',
    );
    if (prior['format'] == 'alkion-android-run/1') {
      _require(
        caseId == 'denied' &&
            phase == 'prepare' &&
            prior['phase'] == 'lifecycle-initial' &&
            prior['overall'] == 'IN_PROGRESS' &&
            prior['initial_lifecycle_phase'] == 'PASS' &&
            prior['error'] == null &&
            prior['installed'][AlkionIdentity.applicationId]['version_code'] ==
                priorVersion,
        'accepted_initial_lifecycle_required',
      );
      for (final package in AlkionVariant.values.map(
        (value) => value.applicationId,
      )) {
        final value = prior['lifecycle'][package];
        final finish = value['finish'];
        _require(
          value['initial_lifecycle'] == 'PASS' &&
              finish['format'] == 'alkion-android-lifecycle-checkpoint/1' &&
              finish['phase'] == 'finish' &&
              finish['run_id'] == run &&
              finish['application_id'] == package &&
              finish['closed'] == true &&
              finish['complete'] == true &&
              finish['result'] == 'PASS',
          'both_lifecycle_variants_required',
        );
      }
      final finish = prior['lifecycle'][AlkionIdentity.applicationId]['finish'];
      _require(
        finish['state_digest'] == priorStateDigest &&
            finish['profile_id'] == profileId &&
            finish['generation'] == generation,
        'lifecycle_snapshot_binding_changed',
      );
      return;
    }
    _require(
      prior['format'] == capabilityFormat &&
          prior['application_id'] == AlkionIdentity.applicationId &&
          prior['variant'] == variant &&
          prior['profile_id'] == profileId &&
          prior['generation'] == generation &&
          prior['version_code'] == priorVersion &&
          prior['state_digest'] == priorStateDigest &&
          prior['closed'] == true &&
          prior['complete'] == true &&
          prior['result'] == 'PASS' &&
          lifecycle.updateDigest(
                Map<String, dynamic>.from(prior['snapshot'] as Map),
              ) ==
              priorStateDigest,
      'successful_capability_predecessor_required',
    );
    if (phase == 'prepare') {
      final index = _cases.indexOf(caseId);
      _require(
        index > 0 &&
            prior['case_id'] == _cases[index - 1] &&
            prior['phase'] == (caseId == 'inexact' ? 'preserve' : 'logged'),
        'case_order_changed',
      );
    } else {
      _require(
        prior['case_id'] == caseId &&
            prior['phase'] == (phase == 'logged' ? 'preserve' : 'prepare'),
        'checkpoint_order_changed',
      );
    }
  }
}

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
Map<String, dynamic> _row(
  Map<String, dynamic> state,
  String kind, [
  String key = 'active',
]) => lifecycle.lifecycleRow(state, kind, key);
Map<String, dynamic> _payload(Map<String, dynamic> row) =>
    lifecycle.lifecyclePayload(row);
int _revision(
  Map<String, dynamic> state,
  String kind, [
  String key = 'active',
]) {
  final rows = (state['inventory']['local_state'] as List).where(
    (dynamic row) => row['state_kind'] == kind && row['state_key'] == key,
  );
  return rows.isEmpty ? 0 : rows.single['revision'] as int;
}

void _requireUnchangedOutsideFixture(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) {
  lifecycle.requireLifecyclePreservation(before, after);
  for (final table in preservedTables.where(
    (table) => table != 'local_state',
  )) {
    _require(
      lifecycle.updateDigest({'rows': before['inventory'][table]}) ==
          lifecycle.updateDigest({'rows': after['inventory'][table]}),
      'changed_$table',
    );
  }
  final old = before['inventory']['local_state'] as List;
  final current = after['inventory']['local_state'] as List;
  _require(current.length == old.length, 'local_state_key_set_changed');
  for (final dynamic row in old) {
    final key = '${row['state_kind']}/${row['state_key']}';
    if (_mutable.contains(key)) continue;
    final dynamic observed = current.singleWhere(
      (dynamic value) =>
          value['state_kind'] == row['state_kind'] &&
          value['state_key'] == row['state_key'],
    );
    _require(
      lifecycle.updateDigest({'row': row}) ==
          lifecycle.updateDigest({'row': observed}),
      'changed_other_local_state',
    );
  }
}

void _requireRow(
  Map<String, dynamic> state,
  String kind,
  String key,
  int revision,
  Map<String, dynamic> payload,
  DateTime notBefore,
  DateTime notAfter,
) {
  final row = _row(state, kind, key);
  final timestamp = DateTime.tryParse(row['updated_at'] as String);
  _require(
    row.length == 8 &&
        row['profile_id'] == state['profile_id'] &&
        row['generation'] == state['generation'] &&
        row['revision'] == revision &&
        row['status'] == (key == notificationActionKey ? 'issued' : 'active') &&
        timestamp != null &&
        timestamp.isUtc &&
        !timestamp.isBefore(notBefore) &&
        !timestamp.isAfter(notAfter) &&
        base64Encode((row['payload_bytes'] as List).cast<int>()) ==
            base64Encode(localBytes(payload)),
    'unexpected_${kind}_$key',
  );
}

void _requireAction(
  Map<String, dynamic> before,
  Map<String, dynamic> current,
  DateTime from,
  DateTime until,
) {
  final row = _row(current, 'timer', notificationActionKey);
  final payload = _payload(row);
  final action = NotificationAction.decode(jsonEncode(payload['action']));
  final draft = _payload(_row(current, 'draft'));
  _require(
    payload.length == 1 &&
        action != null &&
        action.applicationId == current['application_id'] &&
        action.profileId == current['profile_id'] &&
        action.generation == current['generation'] &&
        action.draftId == draft['draftId'] &&
        action.restStart == draft['restStart'] &&
        action.timerRevision == _row(current, 'timer')['revision'] &&
        RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(action.token) &&
        action.token !=
            _payload(
              _row(before, 'timer', notificationActionKey),
            )['action']['token'],
    'issued_action_binding_changed',
  );
  _requireRow(
    current,
    'timer',
    notificationActionKey,
    _revision(before, 'timer', notificationActionKey) + 1,
    payload,
    from,
    until,
  );
}

SessionDraft _fixtureDraft(
  CapabilityStep step,
  Map<String, dynamic> previous,
  DateTime now,
) {
  final prefix = 'capability-${step.run}-${step.caseId}';
  final data = Map<String, dynamic>.from(workflowDraft());
  final block = (data['blocks'] as List).single as Map;
  final exercise = (previous['inventory']['exercises'] as List).single as Map;
  _require(
    exercise['default_rest_seconds'] == null ||
        exercise['default_rest_seconds'] == 600,
    'fixture_exercise_rest_changed',
  );
  block['exerciseId'] = exercise['id'];
  for (final dynamic set in [
    ...block['warmupSets'] as List,
    ...block['workingSets'] as List,
  ]) {
    set['id'] = '$prefix-${set['id']}';
  }
  data.addAll({
    'draftId': prefix,
    'name':
        'Synthetic capability ${step.run} ${step.caseId} ${AlkionIdentity.applicationId}',
    'startedAt': now.toIso8601String(),
    'restStart': now.toIso8601String(),
    'restTotal': 600,
    'focusedSetId': '$prefix-workflow-planned',
  });
  return SessionDraft.fromJson(data);
}

/// The only writer in this entry: an explicit, retained synthetic fixture delta.
Future<Map<String, dynamic>> _prepare(
  Directory root,
  CapabilityStep step,
  Map<String, dynamic> before,
) async {
  final settings = _payload(_row(before, 'semanticSetting', 'settings'));
  _require(
    settings['locale'] == 'en' && settings['rest_compound_seconds'] == 600,
    'accepted_fixture_settings_required',
  );
  final started = DateTime.now().toUtc();
  final draft = _fixtureDraft(step, before, started);
  final profile = (await AlkionProfile.existing(supportRoot: root))!;
  final store = await LocalStore.open(
    profile: profile,
    expectedProfileId: step.profileId,
    schema: workflowSchemaRegistry(),
  );
  try {
    final drafts = DraftStore.local(store);
    await drafts.load();
    await drafts.save(draft);
    _require(
      await drafts.notificationAction() != null,
      'fixture_action_missing',
    );
  } finally {
    await store.close();
  }
  final after = await lifecycle.captureUpdateState(root);
  final completed = DateTime.now().toUtc();
  _requireUnchangedOutsideFixture(before, after);
  _requireRow(
    after,
    'draft',
    'active',
    _revision(before, 'draft') + 1,
    draft.toJson(),
    started,
    completed,
  );
  _requireRow(
    after,
    'timer',
    'active',
    _revision(before, 'timer') + 1,
    Map<String, dynamic>.from(draft.timerJson),
    started,
    completed,
  );
  _requireAction(before, after, started, completed);
  return after;
}

void _requireLiveRest(Map<String, dynamic> state) {
  final draft = _payload(_row(state, 'draft'));
  final timer = _payload(_row(state, 'timer'));
  final start = DateTime.tryParse(draft['restStart'] as String? ?? '');
  _require(
    start != null &&
        draft['restTotal'] == 600 &&
        timer['restStart'] == draft['restStart'] &&
        timer['restTotal'] == 600 &&
        DateTime.now().isBefore(start.add(const Duration(seconds: 600))),
    'rest_deadline_no_longer_live',
  );
}

void _requireLogged(
  Map<String, dynamic> before,
  Map<String, dynamic> current,
  DateTime from,
) {
  _requireUnchangedOutsideFixture(before, current);
  final until = DateTime.now().toUtc();
  final expected = _copy(_payload(_row(before, 'draft')));
  final observed = _payload(_row(current, 'draft'));
  final oldStart = DateTime.parse(expected['restStart'] as String);
  final start = DateTime.tryParse(observed['restStart'] as String? ?? '');
  _require(
    start != null &&
        start.isAfter(oldStart) &&
        !start.isBefore(from) &&
        !start.isAfter(until),
    'logging_rest_reset_not_bound',
  );
  final block = (expected['blocks'] as List).single as Map;
  final planned = (block['workingSets'] as List).last as Map;
  _require(
    planned['done'] == false && expected['focusedSetId'] == planned['id'],
    'logging_fixture_changed',
  );
  planned['done'] = true;
  expected.addAll({
    'focusedSetId': null,
    'rirPromptSetId': planned['id'],
    'restStart': observed['restStart'],
    'restTotal': 600,
    'restEndedAt': null,
  });
  // Normal owner/lifecycle flushes can settle several queued saves. Count and
  // report them, but prove the exact final payload and paired timer revision;
  // a save count does not establish the number of user logging actions.
  final delta = _revision(current, 'draft') - _revision(before, 'draft');
  _require(
    delta >= 1 &&
        _revision(current, 'timer') - _revision(before, 'timer') == delta,
    'logging_revision_count_changed',
  );
  _requireRow(
    current,
    'draft',
    'active',
    _revision(before, 'draft') + delta,
    expected,
    from,
    until,
  );
  final timer = _copy(_payload(_row(before, 'timer')))
    ..addAll({
      'restStart': observed['restStart'],
      'restTotal': 600,
      'restEndedAt': null,
    });
  _requireRow(
    current,
    'timer',
    'active',
    _revision(before, 'timer') + delta,
    timer,
    from,
    until,
  );
  _requireAction(before, current, from, until);
  _requireLiveRest(current);
}

/// Closed SQL oracle only. No OS permission, alarm or notification result is
/// inferred here; later serial-scoped host routing supplies that separate proof.
Future<Map<String, dynamic>> capabilityCheckpoint(
  Directory root,
  CapabilityStep step,
  String priorReport,
  Map<String, dynamic> priorSnapshot,
) async {
  step.requirePredecessor(priorReport, priorSnapshot);
  final before = await lifecycle.captureUpdateState(root);
  late Map<String, dynamic> current;
  if (step.phase == 'prepare') {
    _require(
      lifecycle.updateDigest(before) == step.priorStateDigest,
      'preflight_state_changed_before_writer',
    );
    current = await _prepare(root, step, before);
  } else if (step.phase == 'preserve') {
    _require(
      lifecycle.updateDigest(before) == step.priorStateDigest,
      'deadline_or_committed_state_changed',
    );
    _requireLiveRest(before);
    current = before;
  } else {
    final prior = jsonDecode(priorReport) as Map;
    _requireLogged(
      priorSnapshot,
      before,
      DateTime.parse(prior['checkpoint_time'] as String),
    );
    current = before;
  }
  final delta = <String, dynamic>{};
  for (final key in _mutable) {
    final parts = key.split('/');
    final old = _row(priorSnapshot, parts[0], parts[1]);
    final next = _row(current, parts[0], parts[1]);
    if (lifecycle.updateDigest(old) != lifecycle.updateDigest(next)) {
      delta[key] = {
        'before_sha256': lifecycle.updateDigest(old),
        'after_sha256': lifecycle.updateDigest(next),
        'revision_delta': (next['revision'] as int) - (old['revision'] as int),
      };
    }
  }
  return {
    ...step.identity,
    'complete': true,
    'closed': true,
    'result': 'PASS',
    'scope': 'closed synthetic SQL fixture/checkpoint only',
    'native_proof': 'UNRUN: host routing is separate',
    'installation_id': current['installation_id'],
    'state_digest': lifecycle.updateDigest(current),
    'checkpoint_time': DateTime.now().toUtc().toIso8601String(),
    'fixture_delta': step.phase == 'prepare' ? delta : <String, dynamic>{},
    'observed_delta': step.phase == 'prepare' ? <String, dynamic>{} : delta,
    'snapshot': current,
  };
}

/// A freshly claimed output directory and exclusive publication retain failed
/// partial reports and cannot replace an earlier terminal receipt.
Future<void> publishCapabilityReport(
  Directory directory,
  Map<String, dynamic> report,
) async {
  final partial = File(p.join(directory.path, 'report.partial'));
  final terminal = p.join(directory.path, 'report.json');
  _require(
    await FileSystemEntity.type(partial.path, followLinks: false) ==
            FileSystemEntityType.notFound &&
        await FileSystemEntity.type(terminal, followLinks: false) ==
            FileSystemEntityType.notFound,
    'report_already_present',
  );
  await partial.writeAsString('${jsonEncode(report)}\n', flush: true);
  _require(linkExclusive(partial.path, terminal), 'report_already_present');
  flushDirectory(directory.path);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Directory? output;
  final report = <String, dynamic>{
    'format': capabilityFormat,
    'complete': false,
    'closed': false,
  };
  unawaited(
    binding.allTestsPassed.future.then((passed) async {
      final directory = output;
      if (directory == null) return;
      report.addAll({
        'complete': true,
        'result': passed && report['closed'] == true ? 'PASS' : 'FAIL',
        'failures': binding.failureMethodsDetails
            .map((value) => value.toString())
            .toList(),
      });
      await publishCapabilityReport(directory, report);
    }),
  );
  testWidgets(
    'closed synthetic capability fixture/checkpoint',
    (tester) async {
      await tester.runAsync(() async {
        _require(Platform.isAndroid, 'android_entry_required');
        int number(String value) => int.tryParse(value) ?? -1;
        final current = CapabilityStep(
          run: const String.fromEnvironment('ALKION_PROOF_RUN'),
          source: const String.fromEnvironment('ALKION_PROOF_SOURCE'),
          priorSource: const String.fromEnvironment('ALKION_PRIOR_SOURCE'),
          variant: const String.fromEnvironment('ALKION_PROOF_VARIANT'),
          caseId: const String.fromEnvironment('ALKION_CAPABILITY_CASE'),
          phase: const String.fromEnvironment('ALKION_CAPABILITY_PHASE'),
          version: number(const String.fromEnvironment('ALKION_PROOF_VERSION')),
          priorVersion: number(
            const String.fromEnvironment('ALKION_PRIOR_VERSION'),
          ),
          consumedFloor: number(
            const String.fromEnvironment('ALKION_CONSUMED_VERSION_FLOOR'),
          ),
          profileId: const String.fromEnvironment('ALKION_PROOF_PROFILE'),
          generation: number(
            const String.fromEnvironment('ALKION_PROOF_GENERATION'),
          ),
          priorReportDigest: const String.fromEnvironment(
            'ALKION_PRIOR_REPORT_SHA256',
          ),
          priorStateDigest: const String.fromEnvironment(
            'ALKION_PRIOR_STATE_SHA256',
          ),
        );
        current.validate();
        report.addAll(current.identity);
        final root = await checkedAlkionSupportRoot();
        final directory = Directory(
          p.join(
            root.parent.path,
            'android-capability',
            current.run,
            current.caseId,
            'v${current.version}',
          ),
        );
        refuseDirectoryLinks(directory.path);
        _require(await directory.exists(), 'staged_input_directory_required');
        output = claimPrivateDirectory(p.join(directory.path, 'output'));
        Future<String> read(String name) async {
          final file = File(p.join(directory.path, name));
          _require(
            await FileSystemEntity.type(file.path, followLinks: false) ==
                    FileSystemEntityType.file &&
                await file.length() <= 1048576,
            'input_missing_linked_or_large',
          );
          return file.readAsString();
        }

        final predecessor = await read('prior-report.json');
        final snapshot = Map<String, dynamic>.from(
          jsonDecode(await read('prior-snapshot.json')) as Map,
        );
        report.addAll(
          await capabilityCheckpoint(root, current, predecessor, snapshot),
        );
        report['complete'] = false;
      });
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
