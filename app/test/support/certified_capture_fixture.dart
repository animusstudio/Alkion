// A disposable, account-free installation that produces a real
// CertifiedCapture through the capture coordinator, for export and screen
// tests.
//
// The source is a real (synthetic) PowerSync database, a malformed draft
// file and preferences in a temporary directory laid out like the
// application-support directory. The gate is test/support/gate_model.dart
// and the durable file primitives are test/support/fake_capture_files.dart:
// Dart models of the native protocol, so nothing here qualifies native
// locking or durability. No sign-in exists and nothing is connected.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:powersync/powersync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_startup.dart';
import 'package:workout_tracker/capture/capture_transport.dart';
import 'package:workout_tracker/capture/session_capture_hooks.dart';
import 'package:workout_tracker/capture/source_write_gate.dart';
import 'package:workout_tracker/capture/startup_inventory.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/sync/schema.dart';

import 'fake_capture_files.dart';
import 'fake_stores.dart';
import 'gate_model.dart';

const certifiedFixtureUser = '00000000-0000-4000-8000-000000000001';
const _exercise = '00000000-0000-4000-8000-0000000000e1';

/// Bytes of a half-written draft: malformed, so ordinary startup would
/// delete it. A capture keeps it exactly.
final malformedDraftBytes =
    utf8.encode('{"sessionId":null,"startedAt":"2026-10-10T09');

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// Every entry under [dir] (links not followed) with its SHA-256.
Map<String, String> treeDigest(Directory dir) => {
      for (final e in dir.listSync(recursive: true, followLinks: false))
        p.relative(e.path, from: dir.path): switch (e) {
          File f => sha256Of(f.readAsBytesSync()),
          Link l => 'link:${l.targetSync()}',
          _ => 'dir',
        },
    };

class CertifiedCaptureFixture {
  CertifiedCaptureFixture._(this.source, this.name);

  final Directory source;
  final String name;
  late final CaptureLocations locations = CaptureLocations(source);
  late final GateModel model;
  late final FakeCaptureFiles fakeFiles;
  late final SourceWriteGate gate;
  late final PowerSyncDatabase database;
  late final SessionManager manager;
  late final SessionCaptureHooks hooks;

  static var _serial = 0;

  static Future<CertifiedCaptureFixture> create() async {
    CaptureCoordinator.forgetProcessStateForTesting();
    TransportAdmission.instance.resetForTesting();
    SessionWriteLedger.instance.resetForTesting();
    UnsavedEditors.instance.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'unit': 'kg',
      'identity.current_user_id': certifiedFixtureUser,
      'identity.onboarding_complete': true,
      'settings.sync_enabled': false,
    });
    final dir = await Directory.systemTemp.createTemp('reps-certified');
    final f = CertifiedCaptureFixture._(dir, 'certified-${++_serial}');
    f.model = GateModel(f.name);
    f.fakeFiles = FakeCaptureFiles(f.name);
    f.gate = f.model.gate(f.locations.gate);
    appSourceGate = f.gate;
    f.database = PowerSyncDatabase(
        schema: schema, path: p.join(dir.path, 'workout-tracker.db'));
    await f.database.initialize();
    await f._seed();
    File(p.join(dir.path, DraftStore.fileName))
        .writeAsBytesSync(malformedDraftBytes, flush: true);
    f.manager = SessionManager(finishedStore: FakeFinishedSessionStore());
    f.hooks = SessionCaptureHooks(
      manager: f.manager,
      preservation: RawPreservation(f.locations.preparation,
          base: dir, files: f.fakeFiles.files),
    );
    return f;
  }

  Future<void> _seed() async {
    await database.writeTransaction((tx) async {
      await tx.execute(
          'INSERT INTO "ps_data__exercises" (id, data) VALUES (?, ?)', [
        _exercise,
        jsonEncode({
          'name': 'Bench Press', 'slug': 'bench-press', 'muscle_group': 'chest',
          'is_template': 0, 'created_by': certifiedFixtureUser,
          'created_at': '2026-01-01T00:00:00Z', 'equip': 'barbell',
          'compound': 1, 'base_weight_kg': '20.00', 'plate_step_kg': '2.50',
        }),
      ]);
    });
    await database.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO sessions (id, user_id, date, split_label, created_at, '
        'duration_min) VALUES (?, ?, ?, ?, ?, ?)',
        ['d1000000-0000-4000-8000-000000000001', certifiedFixtureUser,
          '2026-10-01', 'Custom', '2026-10-01T10:00:00.000Z', 45],
      );
    });
  }

  CaptureCoordinator coordinator({bool sources = true}) => CaptureCoordinator(
        locations: locations,
        gate: gate,
        files: fakeFiles.files,
        sources: !sources
            ? null
            : CaptureSourceBindings(
                database: database,
                hooks: hooks,
                transportFor: (profile) => CaptureTransport.forProfile(
                  database: database,
                  profile: profile,
                  reconnect: () async {},
                ),
                packageInfo: () async => PackageInfo(
                  appName: 'Reps',
                  packageName: 'io.github.psychonaut0.reps',
                  version: '0.18.1',
                  buildNumber: '37',
                ),
              ),
        drainTimeout: const Duration(seconds: 5),
      );

  /// A published, re-verified capture of the synthetic source.
  Future<CertifiedCapture> certify({CaptureMode mode = CaptureMode.rehearsal}) =>
      coordinator().capture(mode: mode);

  var _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    appSourceGate = null;
    manager.dispose();
    await database.close();
    model.detach();
    fakeFiles.detach();
    CaptureCoordinator.forgetProcessStateForTesting();
    TransportAdmission.instance.resetForTesting();
    SessionWriteLedger.instance.resetForTesting();
    UnsavedEditors.instance.resetForTesting();
    if (await source.exists()) await source.delete(recursive: true);
  }
}
