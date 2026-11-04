import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alkion/animus/workout_send_models.dart';
import 'package:alkion/animus/workout_upload_repository.dart';
import 'package:alkion/data/session_repository.dart';
import 'package:alkion/domain/evidence.dart';
import 'package:alkion/store/local_store.dart';
import 'package:alkion/transfer/full_v1.dart';
import 'package:alkion/transfer/history_transfer_service.dart';
import 'package:alkion/transfer/history_v1.dart';
import 'package:alkion/transfer/json_span_reader.dart';
import 'package:alkion/transfer/transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transfer_harness.dart';

const historyFixture = 'history-synthetic-v1.json';
const namespace = 'synthetic-history';
HistoryTransferService service(
  TransferHarness h, {
  TransferCheckpoint? checkpoint,
}) => HistoryTransferService(
  h.store,
  testProfileId: h.profile.profileId,
  checkpoint: checkpoint,
);

Matcher rejection(String category) =>
    isA<TransferRejection>().having((r) => r.category, 'category', category);

void main() {
  test(
    'nested history retains exact spans, numbers, calendar days and occurrence identity',
    () {
      final bytes = fixture(historyFixture);
      final d = validateHistoryV1(bytes);
      expect(d.counts, {'sessions': 3, 'exercise_blocks': 3, 'sets': 4});
      expect(d.versionLexeme, '1e0');
      expect(d.from, '2024-02-29');
      expect(d.to, '2024-03-01');
      expect(d.incompatibilities, isEmpty);
      expect(d.blocks.map((b) => b.externalId).toSet(), hasLength(3));
      expect(d.blocks.map((b) => b.values['name']).toSet(), {'Synthetic Row'});
      expect(d.sessions.map((s) => s.externalId).toSet(), hasLength(3));
      expect(
        d.sets.first.fields['weight_kg']!.lexeme,
        '9007199254740993.12500',
      );
      expect(d.sets.first.values['weight_kg'], '9007199254740993.12500');
      expect(d.sets[1].values['weight_kg'], '40.50');
      expect(d.sets[1].fields['weight_kg']!.lexeme, '4.050e1');
      expect(d.sets[2].values['weight_kg'], '-0.00');
      expect(d.sets[3].fields['weight_kg']!.state, ValueState.nullValue);
      expect(d.sets[1].values['rir'], 9);
      expect(d.sets.map((s) => s.values['set_number']), [1, 2, 3, 1]);
      for (final row in d.occurrences) {
        expect(row.originalBytes, bytes.sublist(row.start, row.end));
        expect(row.values.containsKey('created_at'), isFalse);
        expect(row.values.containsKey('finished_at'), isFalse);
      }
      expect(d.sets.first.unknownFields, ['future']);
      expect(d.envelope['unknown_root_members'], ['source_extra']);
      expect(
        () => validateFullV1(bytes),
        throwsA(rejection('history_kind_rejected')),
      );
    },
  );

  for (final mutation in <(String, String, String, String)>[
    (
      'format',
      '"format": "reps-export"',
      '"format": "other"',
      'format_unsupported',
    ),
    ('version', '"version": 1e0', '"version": "1"', 'version_unsupported'),
    ('kind', '"kind": "history"', '"kind": "full"', 'history_kind_required'),
    ('unit', '"unit": "kg"', '"unit": "lb"', 'history_unit_unsupported'),
    (
      'calendar',
      '"date": "2024-02-29"',
      '"date": "2024-02-30"',
      'history_calendar_day_invalid',
    ),
    (
      'instant',
      '"date": "2024-02-29"',
      '"date": "2024-02-29T00:00:00Z"',
      'history_calendar_day_invalid',
    ),
    (
      'range',
      '"from": "2024-02-29"',
      '"from": "2024-03-02"',
      'history_date_range_reversed',
    ),
    (
      'outside',
      '"date": "2024-02-29"',
      '"date": "2024-02-28"',
      'history_session_outside_date_range',
    ),
    (
      'duplicate',
      '"label": "Synthetic répétition"',
      '"label": "A", "la\\u0062el": "B"',
      'duplicate_key',
    ),
    (
      'sets',
      '"sets": [',
      '"sets": null, "evidence": [',
      'history_array_required',
    ),
  ]) {
    test(
      'invalid history ${mutation.$1} is staged and never selected',
      () async {
        final h = await TransferHarness.open('history-refusal');
        addTearDown(h.close);
        await seedPreexistingWork(h.store);
        final before = await h.store.inventory();
        final bytes = mutate(historyFixture, mutation.$2, mutation.$3);
        final result = await service(
          h,
        ).importArtifact(bytes, namespace: namespace);
        expect(result.status, ImportStatus.rejected);
        expect(result.category, mutation.$4);
        expect(await service(h).originalBytes(result.artifactId!), bytes);
        final after = await h.store.inventory();
        expect(
          pick(after, preservedWorkTables),
          pick(before, preservedWorkTables),
        );
        final inventoryBeforeRetry = inventoryDigest(after);
        final retry = await service(
          h,
        ).importArtifact(bytes, namespace: namespace);
        expect(retry.toJson(), result.toJson());
        expect(
          inventoryDigest(await h.store.inventory()),
          inventoryBeforeRetry,
        );
        await h.reopenTwice();
      },
    );
  }

  test(
    'unsupported scalar evidence blocks whole selection without zero/default fabrication',
    () async {
      for (final (from, to) in [
        ('"weight_kg": 9007199254740993.12500', '"weight_kg": ""'),
        ('"weight_kg": 9007199254740993.12500', '"weight_kg": 1e100001'),
        ('"reps": 8', '"reps": 8.0'),
        ('"duration_min": 53', '"duration_min": 9223372036854775808'),
        ('"warmup": false', '"warmup": 0'),
      ]) {
        final h = await TransferHarness.open('history-unsupported');
        try {
          final bytes = mutate(historyFixture, from, to);
          final preview = await service(
            h,
          ).previewArtifact(bytes, namespace: namespace);
          expect(preview.canImport, isFalse);
          expect(preview.outcome!.status, ImportStatus.incompatible);
          expect(preview.document!.incompatibilities, isNotEmpty);
          expect(await h.store.getAll('SELECT * FROM sessions'), isEmpty);
          expect(await service(h).originalBytes(preview.artifactId!), bytes);
        } finally {
          await h.close();
        }
      }
    },
  );

  test(
    'resource bounds and invalid UTF-8 retain only bounded staged evidence',
    () async {
      final h = await TransferHarness.open('history-bounds');
      addTearDown(h.close);
      final bytes = fixture(historyFixture);
      final unstaged = await HistoryTransferService(
        h.store,
        testProfileId: h.profile.profileId,
        maxRawBytes: 1,
      ).importArtifact(bytes, namespace: 'raw');
      expect(unstaged.status, ImportStatus.refusedUnstaged);
      expect(await h.store.getAll('SELECT * FROM source_artifacts'), isEmpty);
      final rowBound = await HistoryTransferService(
        h.store,
        testProfileId: h.profile.profileId,
        maxRows: 1,
      ).importArtifact(bytes, namespace: 'rows');
      expect(rowBound.category, 'resource_limit_rows');
      final parseBound = await HistoryTransferService(
        h.store,
        testProfileId: h.profile.profileId,
        limits: const ReaderLimits(maxInputBytes: 1),
      ).importArtifact(bytes, namespace: 'parse');
      expect(parseBound.category, 'resource_limit_input');
      final invalid = Uint8List.fromList([0xff, 0xc0, 0x80]);
      final badUtf8 = await service(
        h,
      ).importArtifact(invalid, namespace: 'utf8');
      expect(badUtf8.status, ImportStatus.rejected);
      expect(await service(h).originalBytes(badUtf8.artifactId!), invalid);
      expect(await h.store.getAll('SELECT * FROM sessions'), isEmpty);
    },
  );

  test(
    'preview selects nothing, promotion and retry preserve exact SQLite evidence',
    () async {
      final h = await TransferHarness.open('history-sqlite');
      addTearDown(h.close);
      await seedPreexistingWork(h.store);
      final before = await h.store.inventory();
      final bytes = fixture(historyFixture);
      final preview = await service(
        h,
      ).previewArtifact(bytes, namespace: namespace);
      expect(preview.canImport, isTrue);
      expect(preview.outcome, isNull);
      expect(await h.store.getAll('SELECT * FROM sessions'), isEmpty);
      expect(await service(h).originalBytes(preview.artifactId!), bytes);
      final result = await service(
        h,
      ).importArtifact(bytes, namespace: namespace);
      expect(result.status, ImportStatus.selected);
      final d = preview.document!;
      final sessionId = transferLocalId(
        h.store.profileId,
        namespace,
        'sessions',
        d.sessions.first.externalId,
      );
      final rows = await h.store.getAll(
        'SELECT * FROM sets ORDER BY set_number',
      );
      expect(rows, hasLength(4));
      final first = rows.firstWhere(
        (r) => r['weight_kg'] == '9007199254740993.12500',
      );
      expect(first['rir'], isNull);
      expect(first['is_pr'], 1);
      expect(first['is_top_set'], 1);
      expect(first['created_at'], isNull);
      final session = await h.store.get('SELECT * FROM sessions WHERE id=?', [
        sessionId,
      ]);
      expect(session['date'], '2024-02-29');
      expect(session['duration_min'], 53);
      expect(session['notes'], isNull);
      expect(session['finished_at'], isNull);
      final importedSets = await SessionRepository.local(
        h.store,
      ).setsForSession(sessionId);
      expect(importedSets, hasLength(3));
      expect(groupSetsIntoBlocks(importedSets), hasLength(2));
      expect(
        groupSetsIntoBlocks(importedSets).map((b) => b.exerciseId).toSet(),
        hasLength(2),
      );
      final projections = await h.store.getAll(
        'SELECT * FROM source_projections',
      );
      expect(projections, hasLength(10));
      final preserved = decodeBytesJson(
        projections.firstWhere(
          (r) =>
              decodeBytesJson(r['projection_bytes'])['external_id'] ==
              d.sets.first.externalId,
        )['projection_bytes'],
      );
      expect(
        (preserved['fields'] as Map)['weight_kg']['lexeme'],
        '9007199254740993.12500',
      );
      final after = await h.store.inventory();
      for (final table in ['operations', 'operation_attempts', 'local_state']) {
        expect(after[table], before[table]);
      }
      expect(
        (await service(h).importArtifact(bytes, namespace: namespace)).status,
        ImportStatus.alreadySelected,
      );
      expect(
        inventoryDigest(await h.store.inventory()),
        inventoryDigest(after),
      );
      expect(inventoryDigest(await h.reopenTwice()), inventoryDigest(after));
      final sender = WorkoutUploadRepository(h.store, h.profile.installationId);
      await expectLater(
        sender.select(sessionId, {
          'profile_id': h.store.profileId,
          'installation_id': h.profile.installationId,
          'generation': h.store.token.generation,
        }, () {}),
        throwsA(
          isA<WorkoutUploadBlocked>().having(
            (e) => e.issue,
            'issue',
            AnimusWorkoutSendIssue.unsupportedWorkout,
          ),
        ),
      );
      expect(
        inventoryDigest(await h.store.inventory()),
        inventoryDigest(after),
      );
    },
  );

  test(
    'confirmed preview uses staged bytes after the supplied file changes',
    () async {
      final h = await TransferHarness.open('history-preview-confirm');
      final other = await TransferHarness.open('history-preview-other');
      addTearDown(h.close);
      addTearDown(other.close);
      final bytes = fixture(historyFixture);
      final file = File('${h.root.path}/explicit-history.json');
      await file.writeAsBytes(bytes);
      final preview = await service(
        h,
      ).previewFile(file.path, namespace: namespace);
      await file.writeAsString('{"modified":"after preview"}');
      await expectLater(
        service(h).importPreview(preview, namespace: 'different'),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'history_preview_scope_mismatch',
          ),
        ),
      );
      await service(other).previewArtifact(bytes, namespace: namespace);
      await expectLater(
        service(other).importPreview(preview, namespace: namespace),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'history_preview_scope_mismatch',
          ),
        ),
      );
      final result = await service(
        h,
      ).importPreview(preview, namespace: namespace);
      expect(result.status, ImportStatus.selected);
      expect(await service(h).originalBytes(result.artifactId!), bytes);
      expect(await file.readAsString(), '{"modified":"after preview"}');
      expect(await h.store.getAll('SELECT * FROM sessions'), hasLength(3));
    },
  );

  test(
    'identical source sessions and repeated blocks remain distinct by occurrence',
    () {
      final source =
          jsonDecode(utf8.decode(fixture(historyFixture)))
              as Map<String, dynamic>;
      final first = (source['sessions'] as List).first;
      source['sessions'] = [first, first];
      final d = validateHistoryV1(utf8Bytes(jsonEncode(source)));
      expect(d.sessions.map((s) => s.externalId).toSet(), hasLength(2));
      expect(d.blocks.map((s) => s.externalId).toSet(), hasLength(4));
      expect(d.sets.map((s) => s.externalId).toSet(), hasLength(6));
    },
  );

  test(
    'different and overlapping files cannot replace the namespace; full/history stay separate',
    () async {
      final h = await TransferHarness.open('history-overlap');
      addTearDown(h.close);
      final bytes = fixture(historyFixture);
      await service(h).importArtifact(bytes, namespace: namespace);
      final before = await h.store.inventory();
      for (final other in [
        utf8Bytes('${utf8.decode(bytes)}\n'),
        mutate(historyFixture, 'Synthetic répétition', 'Different label'),
      ]) {
        final result = await service(
          h,
        ).importArtifact(other, namespace: namespace);
        expect(result.category, 'history_namespace_artifact_conflict');
        expect(
          pick(await h.store.inventory(), preservedWorkTables),
          pick(before, preservedWorkTables),
        );
      }
      final full = await TransferService(h.store).importArtifact(
        fixture('full-rich-synthetic-v1.json'),
        namespace: namespace,
      );
      expect(full.category, 'history_namespace_artifact_conflict');
      expect(
        pick(await h.store.inventory(), preservedWorkTables),
        pick(before, preservedWorkTables),
      );
      await TransferService(h.store).importArtifact(
        fixture('full-rich-synthetic-v1.json'),
        namespace: 'full',
      );
      expect(
        (await service(h).importArtifact(bytes, namespace: 'full')).category,
        'history_namespace_artifact_conflict',
      );
    },
  );

  test(
    'test profile import and removal leave another profile byte identical',
    () async {
      final first = await TransferHarness.open('history-profile-a');
      final second = await TransferHarness.open('history-profile-b');
      addTearDown(first.close);
      addTearDown(() async {
        if (await second.root.exists()) await second.close();
      });
      await seedPreexistingWork(first.store);
      await first.store.close();
      final protected = File(
        await first.profile.databasePath(
          expectedProfileId: first.profile.profileId,
        ),
      );
      final beforeBytes = await protected.readAsBytes();
      await service(
        second,
      ).importArtifact(fixture(historyFixture), namespace: namespace);
      expect(await protected.readAsBytes(), beforeBytes);
      final b = await second.store.getAll('SELECT id FROM sessions');
      await second.close();
      expect(await protected.readAsBytes(), beforeBytes);
      await first.reopenTwice();
      await service(
        first,
      ).importArtifact(fixture(historyFixture), namespace: namespace);
      final a = await first.store.getAll('SELECT id FROM sessions');
      expect(
        a
            .map((r) => r['id'])
            .toSet()
            .intersection(b.map((r) => r['id']).toSet()),
        isEmpty,
      );
      await expectLater(
        HistoryTransferService(
          first.store,
          testProfileId: second.store.profileId,
        ).importArtifact(fixture(historyFixture), namespace: namespace),
        throwsA(
          isA<StoreException>().having(
            (e) => e.category,
            'category',
            'history_test_profile_required',
          ),
        ),
      );
    },
  );

  for (final phase in [
    'staging-statements-complete',
    'staged',
    'promotion-statements-complete',
    'promoted',
  ]) {
    test(
      'interruption at $phase reopens coherently and retries the same identity',
      () async {
        final h = await TransferHarness.open('history-retry');
        addTearDown(h.close);
        final bytes = fixture(historyFixture);
        await expectLater(
          service(
            h,
            checkpoint: (current) async {
              if (current == phase) throw StateError('synthetic interruption');
            },
          ).importArtifact(bytes, namespace: namespace),
          throwsStateError,
        );
        await h.reopenTwice();
        final selected = await h.store.getAll(
          'SELECT * FROM import_generations WHERE selected=1',
        );
        final sessions = await h.store.getAll('SELECT * FROM sessions');
        expect(sessions.length, selected.isEmpty ? 0 : 3);
        final result = await service(
          h,
        ).importArtifact(bytes, namespace: namespace);
        expect(
          result.status,
          phase == 'promoted'
              ? ImportStatus.alreadySelected
              : ImportStatus.selected,
        );
        expect(await h.store.getAll('SELECT * FROM sessions'), hasLength(3));
        final inventory = await h.reopenTwice();
        expect(
          (await service(h).importArtifact(bytes, namespace: namespace)).status,
          ImportStatus.alreadySelected,
        );
        expect(
          inventoryDigest(await h.store.inventory()),
          inventoryDigest(inventory),
        );
      },
    );
  }
}
