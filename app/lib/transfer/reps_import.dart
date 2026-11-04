import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/evidence.dart';
import '../history_test/history_mapping.dart';
import '../store/local_store.dart';
import 'full_v1.dart';
import 'history_transfer_service.dart';
import 'history_v1.dart';
import 'imported_settings.dart';
import 'json_span_reader.dart';
import 'transfer_service.dart';

const repsImportNamespace = 'reps-import';

/// A capture in the explicitly opened app profile. The reader's document is
/// preview information; confirmation always validates the durable original.
final class RepsImportPreview {
  const RepsImportPreview({
    required this.profileId,
    required this.namespace,
    required this.digest,
    required this.kind,
    this.document,
    this.mappingSource,
    this.outcome,
    this.importId,
    this.artifactId,
    this.counts = const {},
    this.calendarRange,
    this.fullPreview,
    this.historyPreview,
  });
  final String profileId, namespace, digest, kind;
  final Object? document;
  final RepsMappingSource? mappingSource;
  final ImportOutcome? outcome;
  final String? importId, artifactId, calendarRange;
  final Map<String, int> counts;
  final FullPreview? fullPreview;
  final HistoryPreview? historyPreview;
  String get datasetLabel => switch (kind) {
    'full' => 'Reps full export',
    'history' => 'Reps history export',
    _ => 'Reps export',
  };
  bool get canImport =>
      document != null &&
      (outcome == null || outcome!.status == ImportStatus.alreadySelected);
  bool get hasImportedSettings => kind == 'full' && document != null;
  List<String> get issues => [
    if (outcome?.category != null) outcome!.category!,
    if (document case final FullV1Document full) ...[
      for (final field in full.incompatibilities)
        '${field.table}.${field.field}: ${field.reason}',
      for (final key in full.unknownSettings) 'retained_setting:$key',
      for (final key in full.unknownDatasets) 'retained_dataset:$key',
      for (final key in full.unknownRootMembers) 'retained_root_member:$key',
    ],
    if (document case final HistoryV1Document history)
      for (final field in history.incompatibilities)
        '${field.table}.${field.field}: ${field.reason}',
  ];
}

/// Manual import into the current profile; creates no profile or workspace.
/// Reader-specific validation, source identities and promotion stay in their
/// existing adapters. Native rows and finish/send intents are never authored.
final class RepsImportService {
  RepsImportService(
    this.db, {
    required this.profileId,
    this.maxRawBytes = defaultMaxRawBytes,
  });
  final LocalDatabase db;
  final String profileId;
  final int maxRawBytes;

  void _target(String namespace) {
    checkNamespace(namespace);
    if (profileId.isEmpty || profileId != db.profileId) {
      throw const StoreException('reps_import_profile_required');
    }
  }

  RepsImportPreview _refused(String namespace, String category) =>
      RepsImportPreview(
        profileId: profileId,
        namespace: namespace,
        digest: '',
        kind: 'unknown',
        outcome: ImportOutcome(
          ImportStatus.refusedUnstaged,
          category: category,
        ),
      );

  Future<RepsImportPreview> previewFile(
    String path, {
    String namespace = repsImportNamespace,
  }) async {
    _target(namespace);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return _refused(namespace, 'artifact_not_regular_file');
    }
    final file = File(path), length = await File(path).length();
    if (length > maxRawBytes) {
      return _refused(namespace, 'resource_limit_raw_staging');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != length || await file.length() != length) {
      return _refused(namespace, 'artifact_changed_during_read');
    }
    return previewArtifact(bytes, namespace: namespace);
  }

  Future<RepsImportPreview> previewArtifact(
    Uint8List input, {
    String namespace = repsImportNamespace,
  }) async {
    _target(namespace);
    if (input.length > maxRawBytes) {
      return _refused(namespace, 'resource_limit_raw_staging');
    }
    final bytes = Uint8List.fromList(input);
    final digest = sha256.convert(bytes).toString();
    // Dispatch also reads untrusted JSON. Capture before inspecting the kind;
    // each existing reader retains its own immutable artifact and journal.
    await db.writeTransaction(
      (tx) => tx.putArtifact(
        id: 'reps-art-$digest',
        bytes: bytes,
        digest: digest,
        parserVersion: 'reps-import-dispatch/1',
        format: stagedFormat,
        disposition: stagedDisposition,
        observationTime: localBytes({
          'observed_at': OperationInstant.now().text,
          'clock': 'own-utc',
        }),
      ),
    );
    var kind = 'unknown';
    try {
      final root = readJsonSpans(bytes);
      if (root['kind']?.kind == JsonKind.string) {
        kind = root['kind']!.text!;
      }
    } on TransferRejection {
      // The full adapter records the authoritative structural rejection.
    }
    if (kind == 'history') {
      final preview = await HistoryTransferService(
        db,
        profileId: profileId,
        maxRawBytes: maxRawBytes,
      ).previewArtifact(bytes, namespace: namespace);
      final document = preview.document;
      final conflict = await _kindConflict(kind);
      return RepsImportPreview(
        profileId: profileId,
        namespace: namespace,
        digest: digest,
        kind: kind,
        document: document,
        mappingSource: document == null
            ? null
            : RepsMappingSource(
                digest: digest,
                names: document.blocks.map((b) => b.values['name'] as String),
              ),
        outcome: preview.outcome ?? conflict,
        importId: preview.importId,
        artifactId: preview.artifactId,
        counts: document?.counts ?? const {},
        calendarRange: document == null
            ? null
            : '${document.from} – ${document.to}',
        historyPreview: preview,
      );
    }
    final preview = await TransferService(
      db,
      maxRawBytes: maxRawBytes,
    ).previewArtifact(bytes, namespace: namespace);
    final document = preview.document;
    final conflict = await _kindConflict(kind);
    final dates = <String>[
      for (final row in document?.rows['sessions'] ?? <SourceRow>[])
        if (row.fields['date']?.projected case final String date)
          if (TimeEvidence.fromRow({'date': date}, 'date').kind ==
              TimeKind.calendarDay)
            date,
    ]..sort();
    return RepsImportPreview(
      profileId: profileId,
      namespace: namespace,
      digest: digest,
      kind: kind,
      document: document,
      mappingSource: document == null
          ? null
          : RepsMappingSource(
              digest: digest,
              names: (document.rows['exercises'] ?? [])
                  .map((e) => e.fields['name']?.projected)
                  .whereType<String>(),
            ),
      outcome: preview.outcome ?? conflict,
      importId: preview.importId,
      artifactId: preview.artifactId,
      counts: document == null
          ? const {}
          : Map.unmodifiable({
              for (final entry in document.rows.entries)
                entry.key: entry.value.length,
              'settings':
                  document.settings.values
                      .where((s) => s.state != ValueState.missing)
                      .length +
                  document.unknownSettings.length,
            }),
      calendarRange: dates.isEmpty ? null : '${dates.first} – ${dates.last}',
      fullPreview: preview,
    );
  }

  Future<ImportOutcome?> _kindConflict(String kind) async {
    final rows = await db.getAll(
      'SELECT manifest_bytes FROM import_generations WHERE profile_id=? AND selected=1',
      [profileId],
    );
    final history = kind == 'history';
    for (final row in rows) {
      final format = decodeBytesJson(row['manifest_bytes'])['format'];
      if (history && format == 'alkion-import-manifest/1' ||
          !history && format == historyV1ManifestVersion) {
        return const ImportOutcome(
          ImportStatus.incompatible,
          category: 'reps_import_kind_conflict',
          detail: {
            'reason':
                'Full and history exports cannot be combined without overlap reconciliation.',
          },
        );
      }
    }
    return null;
  }

  Future<ImportOutcome> importPreview(RepsImportPreview preview) async {
    _target(preview.namespace);
    if (preview.profileId != profileId) {
      throw const StoreException('reps_preview_scope_mismatch');
    }
    if (!preview.canImport) {
      return preview.outcome ??
          (throw const StoreException('reps_preview_missing'));
    }
    final conflict = await _kindConflict(preview.kind);
    if (conflict != null) return conflict;
    if (preview.kind == 'history' && preview.historyPreview != null) {
      return HistoryTransferService(
        db,
        profileId: profileId,
      ).importPreview(preview.historyPreview!, namespace: preview.namespace);
    }
    if (preview.kind == 'full' && preview.fullPreview != null) {
      return TransferService(
        db,
      ).importPreview(preview.fullPreview!, namespace: preview.namespace);
    }
    throw const StoreException('reps_preview_missing');
  }

  Future<int> selectMappings(
    RepsImportPreview preview,
    HistoryMappingReview review,
  ) {
    _target(preview.namespace);
    if (preview.profileId != profileId ||
        review.sourceDigest != preview.digest) {
      throw const StoreException('reps_preview_scope_mismatch');
    }
    return HistoryMappingStore(db).select(review, namespace: preview.namespace);
  }

  Future<Map<String, String>> applySettings(RepsImportPreview preview) {
    _target(preview.namespace);
    if (preview.profileId != profileId || !preview.hasImportedSettings) {
      throw const StoreException('reps_preview_scope_mismatch');
    }
    return applyImportedSettings(
      db,
      namespace: preview.namespace,
      importId: preview.importId!,
    );
  }
}
