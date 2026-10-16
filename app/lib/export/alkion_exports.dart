import 'dart:convert';
import 'dart:typed_data';

import '../data/models.dart' show hasQualifiedCalendarDay;
import '../domain/evidence.dart';
import '../store/local_store.dart';
import '../store/schema.dart';
import '../transfer/full_v1.dart';
import '../transfer/json_span_reader.dart';
import 'exact_json.dart';

/// Versioned Alkion export formats. None of them is called `reps-export/1`
/// silently; the compatibility transfer file states its limits in-band.
const domainExportFormat = 'alkion-domain-export';
const historyExportFormat = 'alkion-history-export';
const compatExportFormat = 'alkion-reps-compat-export/1';
const exportFormatVersion = 1;

/// Shared domain/preference state included in the domain export. Draft,
/// timer and finished-recovery state is recovery evidence for manual backup.
const _exportedLocalState = {
  'semanticSetting',
  'goalInitialization',
  'orderResolution',
  'catalogSelection',
  'onboarding',
};

Object? _value(Object? v) => switch (v) {
  final List<int> bytes => Uint8List.fromList(bytes),
  _ => v,
};

Map<String, Object?> _row(Map<String, dynamic> row) => {
  for (final e in row.entries) e.key: _value(e.value),
};

/// Full-domain export from ONE read snapshot: exact projections including
/// tombstones, immutable revisions, source revisions/projections/mappings,
/// corrections, derived results and correspondence, with explicit coverage.
Future<Map<String, Object?>> buildDomainExport(
  LocalRead tx, {
  required String exportedAt,
}) async {
  OperationInstant(exportedAt);
  Future<List<Map<String, Object?>>> all(String table, String order) async => [
    for (final row in await tx.getAll(
      'SELECT * FROM $table WHERE profile_id=? ORDER BY $order',
      [tx.profileId],
    ))
      _row(row)..remove('profile_id'),
  ];
  final version = await tx.get('PRAGMA user_version');
  return {
    'format': domainExportFormat,
    'version': exportFormatVersion,
    'exported_at': exportedAt,
    'snapshot': {
      'coherence': 'single_read_transaction',
      'profile_id': tx.profileId,
      'generation': tx.token.generation,
      'schema_user_version': version.values.single,
    },
    'domain': {for (final table in domainTables) table: await all(table, 'id')},
    'record_revisions': await all(
      'record_revisions',
      'kind,record_id,revision',
    ),
    'corrections': await all('corrections', 'correction_id'),
    'derived_results': await all('derived_results', 'result_id'),
    'origin_mappings': await all(
      'origin_mappings',
      'namespace,source_kind,external_id',
    ),
    'source_revisions': await all('source_revisions', 'source_revision_id'),
    'source_projections': await all(
      'source_projections',
      'source_revision_id,projection_version',
    ),
    'source_artifacts': [
      for (final row in await tx.getAll(
        'SELECT artifact_id,digest,LENGTH(raw_bytes) AS byte_length,parser_version,format,disposition,ingested_at FROM source_artifacts WHERE profile_id=? ORDER BY artifact_id',
        [tx.profileId],
      ))
        _row(row),
    ],
    'import_generations': await all(
      'import_generations',
      'namespace,import_id',
    ),
    'correspondence': await all(
      'correspondence',
      'namespace,source_kind,external_id',
    ),
    'catalog_pins': await all('catalog_pins', 'namespace,pin_id'),
    'local_state': [
      for (final row in await all('local_state', 'state_kind,state_key'))
        if (_exportedLocalState.contains(row['state_kind'])) row,
    ],
    'coverage': {
      'values': 'exact stored TEXT/INTEGER/BLOB; BLOB as blob_base64',
      'tombstones': 'included with deleted=1',
      'excluded': {
        'source_artifacts.raw_bytes': 'use the original-byte export',
        'operations,operation_dependencies,operation_attempts,attempt_outcomes':
            'outbox and attempt evidence belongs to manual backup',
        'reviews,review_decisions,import_journal,restore_journal':
            'private recovery evidence belongs to manual backup',
        'local_state draft/finishedRecovery/timer':
            'recovery state belongs to manual backup',
        'replica_rows,replica_checkpoints': 'replicas are not exported',
        'credentials': 'never stored or exported',
      },
      'backup': 'not a verified backup; manual backup/restore is separate',
    },
  };
}

/// Display sharing: no IDs, no recovery evidence, exact load text or an
/// explicit unavailable state. Not importable as identity-preserving input.
Future<Map<String, Object?>?> buildHistoryExport(
  LocalRead tx, {
  required String from,
  required String to,
  required String exportedAt,
}) async {
  CalendarDay(from);
  CalendarDay(to);
  OperationInstant(exportedAt);
  final sessions = await tx.getAll(
    'SELECT * FROM sessions WHERE profile_id=? AND deleted=0 ORDER BY date,created_at,id',
    [tx.profileId],
  );
  var undated = 0;
  final inRange = <Map<String, dynamic>>[];
  for (final s in sessions) {
    final date = s['date'];
    if (!hasQualifiedCalendarDay(date is String ? date : null)) {
      undated++;
    } else if ((date as String).compareTo(from) >= 0 &&
        date.compareTo(to) <= 0) {
      inRange.add(s);
    }
  }
  if (inRange.isEmpty) return null;
  final exercises = {
    for (final r in await tx.getAll(
      'SELECT id,name,muscle_group FROM exercises WHERE profile_id=?',
      [tx.profileId],
    ))
      r['id'] as String: r,
  };
  var unknownLoads = 0, uncertainOrders = 0;
  Map<String, Object?> state(Object? v, bool valid) => {
    'value': valid ? v : null,
    'state': v == null
        ? 'unavailable'
        : valid
        ? 'valid'
        : 'invalid',
  };
  final out = <Map<String, Object?>>[];
  for (final s in inRange) {
    final sets = await tx.getAll(
      'SELECT * FROM sets WHERE profile_id=? AND deleted=0 AND session_id=? ORDER BY id',
      [tx.profileId, s['id']],
    );
    final qualified = sets.every((r) => r['set_number'] is int);
    // Equal ordinals are tied: the order is a deterministic id tie-break, not
    // recovered fact, so the session is flagged order_uncertain.
    final tied =
        qualified &&
        sets.map((r) => r['set_number']).toSet().length != sets.length;
    final ordered = qualified && !tied;
    if (!ordered) uncertainOrders++;
    final groups = <String, List<Map<String, dynamic>>>{};
    // Total, deterministic order: set_number when every ordinal is an
    // integer, then id; rows are read ORDER BY id otherwise.
    final sorted = [...sets]
      ..sort((a, b) {
        if (qualified) {
          final byNumber = (a['set_number'] as int).compareTo(
            b['set_number'] as int,
          );
          if (byNumber != 0) return byNumber;
        }
        return (a['id'] as String).compareTo(b['id'] as String);
      });
    for (final r in sorted) {
      (groups[r['exercise_id'] as String] ??= []).add(r);
    }
    out.add({
      'date': s['date'],
      'label': s['split_label'],
      'duration_min': state(s['duration_min'], s['duration_min'] is int),
      'order_uncertain': !ordered,
      'exercises': [
        for (final e in groups.entries)
          {
            'name': exercises[e.key]?['name'],
            'muscle_group': exercises[e.key]?['muscle_group'],
            'sets': [
              for (final r in e.value)
                () {
                  final w = DecimalEvidence.fromRow(r, 'weight_kg');
                  final validLoad = w.state == ValueState.valid;
                  if (!validLoad) unknownLoads++;
                  return <String, Object?>{
                    'weight_kg': {
                      'value': validLoad ? w.raw : null,
                      'state': w.state.name,
                    },
                    'reps': state(r['reps'], r['reps'] is int),
                    'rir': state(r['rir'], r['rir'] is int),
                    'warmup': state(
                      r['is_warmup'] is int
                          ? r['is_warmup'] != 0
                          : r['is_warmup'],
                      r['is_warmup'] is int,
                    ),
                    'captured_top_set': state(
                      r['is_top_set'] is int
                          ? r['is_top_set'] != 0
                          : r['is_top_set'],
                      r['is_top_set'] is int,
                    ),
                    'captured_pr': state(
                      r['is_pr'] is int ? r['is_pr'] != 0 : r['is_pr'],
                      r['is_pr'] is int,
                    ),
                  };
                }(),
            ],
          },
      ],
    });
  }
  return {
    'format': historyExportFormat,
    'version': exportFormatVersion,
    'kind': 'history-share',
    'importable': false,
    'exported_at': exportedAt,
    'unit': 'kg',
    'date_range': {'from': from, 'to': to},
    'sessions': out,
    'coverage': {
      'sessions_without_qualified_date_excluded': undated,
      'sets_with_unavailable_load': unknownLoads,
      'sessions_with_uncertain_order': uncertainOrders,
      'excluded':
          'identifiers, source evidence, drafts, outbox, attempts, reviews and recovery state',
      'load_fallback': 'none; unavailable loads are never shown as zero',
    },
  };
}

/// Legacy-compatible `reps-export` v1 full file with in-band limits. Current
/// non-deleted projections only, under Alkion local IDs.
Future<Map<String, Object?>> buildCompatTransferExport(
  LocalRead tx, {
  required String exportedAt,
}) async {
  OperationInstant(exportedAt);
  final data = <String, List<Map<String, Object?>>>{};
  final exported = <String, Set<String>>{};
  var cascaded = 0, cleared = 0;
  for (final policy in fullV1Tables) {
    final rows = await tx.getAll(
      'SELECT * FROM ${policy.table} WHERE profile_id=? AND deleted=0 ORDER BY id',
      [tx.profileId],
    );
    final ids = exported[policy.table] = {};
    final list = data[policy.table] = [];
    for (final row in rows) {
      final out = <String, Object?>{'id': row['id']};
      var keep = true;
      for (final e in policy.fields.entries) {
        if (e.key == 'user_id' || e.key == 'created_by') continue;
        var v = row[e.key];
        if (e.value.cls == FieldClass.reference &&
            !(exported[e.value.target]?.contains(v) ?? false)) {
          keep = false;
        }
        if (e.value.cls == FieldClass.optionalReference &&
            v != null &&
            !(exported[e.value.target]?.contains(v) ?? false)) {
          v = null;
          cleared++;
        }
        out[e.key] = switch (v) {
          final String text when e.value.cls == FieldClass.intTolerant =>
            _lexemeOrString(text),
          final List<int> _ => throw const StoreException(
            'compat_export_unrepresentable_value',
          ),
          _ => v,
        };
      }
      if (!keep) {
        cascaded++;
        continue;
      }
      ids.add(row['id'] as String);
      list.add(out);
    }
  }
  final settings = <String, Object?>{};
  for (final key in ['settings', 'units']) {
    final row = await tx.localState(LocalStateKind.semanticSetting, key);
    if (row == null) continue;
    final payload = Map<String, dynamic>.from(
      jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
          as Map,
    );
    for (final e in payload.entries) {
      switch (e.key) {
        case 'unit' || 'mode' || 'profile_name' || 'locale':
          settings[e.key] = e.value;
        case 'rest_compound_seconds' || 'rest_isolation_seconds':
          settings[e.key] = e.value;
        case 'accent' when e.value is int:
          settings['accent'] =
              '#${(e.value as int).toRadixString(16).padLeft(8, '0').toUpperCase()}';
      }
    }
  }
  return {
    'format': 'reps-export',
    'version': 1,
    'kind': 'full',
    'exported_at': exportedAt,
    'settings': settings,
    'data': data,
    'alkion_compatibility': {
      'format': compatExportFormat,
      'limits': [
        'ids_are_alkion_local_ids_not_original_source_ids',
        'tombstones_revisions_corrections_and_overlays_are_not_represented',
        'user_id_and_created_by_are_stripped',
        'source_number_tokens_are_exported_as_decimal_text_projections',
        'invalid_source_tokens_are_exported_as_their_exact_lexemes',
        'non_integral_numbers_in_integer_columns_are_exported_as_quoted_strings',
        'use_the_original_byte_export_for_exact_source_artifacts',
        'not_a_backup',
      ],
      'rows_excluded_by_deleted_reference': cascaded,
      'optional_references_cleared': cleared,
    },
  };
}

/// An invalid INTEGER-column value preserved as its exact source lexeme is
/// re-emitted as that token; any other text stays a JSON string.
Object _lexemeOrString(String text) {
  try {
    final node = readJsonSpans(Uint8List.fromList(utf8.encode(text)));
    if (node.kind != JsonKind.number) return RawJson(text);
  } on TransferRejection {
    // Not a preserved lexeme.
  }
  return text;
}

/// Encodes an export document exactly.
Uint8List exportBytes(Map<String, Object?> document) =>
    encodeExactJson(document);
