import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../files/android_documents.dart';
import '../files/document_access.dart';
import '../history_test/history_mapping.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../transfer/reps_import.dart';
import '../transfer/reps_import_strings.dart';
import '../transfer/transfer_service.dart';
import '../widgets/fit_label.dart';

/// Ordinary import into the currently open profile. Choosing or previewing a
/// file never selects its source records; only the explicit import does.
class RepsImportScreen extends StatefulWidget {
  const RepsImportScreen({
    super.key,
    required this.database,
    required this.onImport,
    this.catalog,
    this.documents,
  });
  final LocalDatabase database;
  final CatalogBundle? catalog;
  final DocumentAccess? documents;
  final Future<void> Function(
    RepsImportPreview,
    HistoryMappingReview, {
    required bool applySettings,
  })
  onImport;
  @override
  State<RepsImportScreen> createState() => _RepsImportScreenState();
}

class _RepsImportScreenState extends State<RepsImportScreen> {
  final _path = TextEditingController();
  late final _documents = widget.documents ?? platformDocumentAccess();
  late final _service = RepsImportService(
    widget.database,
    profileId: widget.database.profileId,
  );
  RepsImportPreview? _preview;
  HistoryMappingReview? _review;
  String? _error, _filename, _chosenLabel;
  bool _busy = false,
      _selected = false,
      _mappingError = false,
      _applySettings = false;
  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = RepsImportStrings.of(context).failure(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _choose(int maxBytes) async {
    if (_documents == null) {
      return _path.text.trim().isEmpty ? null : _path.text.trim();
    }
    final chosen = await _documents.open(
      maxBytes: maxBytes,
      mimeTypes: const [
        'application/json',
        'text/plain',
        'application/octet-stream',
      ],
    );
    _chosenLabel = chosen == null ? null : documentLabel(chosen.name);
    return chosen?.path;
  }

  Future<void> _previewFile() => _run(() async {
    final path = await _choose(defaultMaxRawBytes);
    if (path == null) return;
    // A failed new preview must not leave an older file ready to import.
    if (mounted) {
      setState(() {
        _preview = null;
        _review = null;
        _selected = false;
        _mappingError = false;
        _applySettings = false;
      });
    }
    final preview = await _service.previewFile(path);
    final source = preview.mappingSource;
    final saved = source == null
        ? null
        : await HistoryMappingStore(
            widget.database,
          ).reviewBytes(namespace: preview.namespace, digest: preview.digest);
    final review = source == null
        ? null
        : saved == null
        ? HistoryMappingReview.unresolved(source)
        : readHistoryMappings(saved, source, catalog: widget.catalog);
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _review = review;
      _filename = _documents == null
          ? documentLabel(File(path).uri.pathSegments.last)
          : _chosenLabel;
      _selected =
          preview.outcome?.status == ImportStatus.alreadySelected &&
          saved != null;
    });
  });

  Future<void> _mappingFile() => _run(() async {
    final path = await _choose(maxHistoryMappingBytes);
    if (path == null) return;
    if (mounted) setState(() => _mappingError = true);
    final file = File(path);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > maxHistoryMappingBytes) {
      throw const FormatException('mapping_file_invalid');
    }
    final review = readHistoryMappings(
      Uint8List.fromList(await file.readAsBytes()),
      _preview!.mappingSource!,
      catalog: widget.catalog,
    );
    if (mounted) {
      setState(() {
        _review = review;
        _selected = false;
        _mappingError = false;
      });
    }
  });

  Future<void> _import() => _run(() async {
    await widget.onImport(_preview!, _review!, applySettings: _applySettings);
    if (mounted) setState(() => _selected = true);
  });

  @override
  Widget build(BuildContext context) {
    final copy = RepsImportStrings.of(context), tokens = context.tokens;
    final preview = _preview, review = _review;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(
          title: FitLabel(
            copy.title,
            maxLines: 2,
            style: WorkoutType.body(size: 20, color: tokens.text),
          ),
          automaticallyImplyLeading: !_busy,
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              Text(
                copy.intro,
                style: WorkoutType.body(size: 14, color: tokens.dim),
              ),
              const SizedBox(height: 20),
              if (_documents == null) ...[
                TextField(
                  key: const Key('reps-import-path'),
                  controller: _path,
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: copy.filePath),
                ),
                const SizedBox(height: 12),
              ],
              OutlinedButton(
                key: const Key('reps-import-choose'),
                onPressed: _busy ? null : _previewFile,
                child: Text(copy.choose),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '${copy.error}\n$_error',
                    key: const Key('reps-import-error'),
                    style: WorkoutType.body(size: 14, color: tokens.danger),
                  ),
                ),
              if (preview?.outcome != null &&
                  preview!.outcome!.status != ImportStatus.alreadySelected)
                Text(
                  '${copy.error}\n${copy.failure(preview.outcome!.category ?? preview.outcome!.status.name)}',
                ),
              if (preview != null && review != null) ...[
                const SizedBox(height: 20),
                Text(
                  copy.preview,
                  style: WorkoutType.display(size: 24, color: tokens.text),
                ),
                Text(
                  _filename ?? '',
                  style: WorkoutType.body(size: 12, color: tokens.dim),
                ),
                const SizedBox(height: 12),
                Text(
                  copy.counts(preview.counts),
                  key: const Key('reps-import-counts'),
                  style: WorkoutType.body(size: 16, color: tokens.text),
                ),
                if (preview.calendarRange != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    preview.calendarRange!,
                    style: WorkoutType.mono(size: 13, color: tokens.dim),
                  ),
                ],
                const SizedBox(height: 20),
                OutlinedButton(
                  key: const Key('reps-import-mapping'),
                  onPressed: _busy ? null : _mappingFile,
                  child: Text(copy.mapping),
                ),
                Text(
                  copy.mappingCounts(review.counts),
                  key: const Key('reps-import-mapping-counts'),
                  style: WorkoutType.body(size: 14, color: tokens.text),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(copy.mappings),
                  children: [
                    for (final entry in review.entries)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry.sourceName),
                        subtitle: Text(
                          '${entry.displayName == null ? '' : '${entry.displayName}\n'}${switch (entry.status) {
                            'exact' => copy.exact,
                            'approximate' => copy.approximate,
                            _ => copy.unresolved,
                          }}\n${entry.rationale}',
                        ),
                      ),
                  ],
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(copy.exceptions),
                  children: [
                    Text(
                      copy.preserved,
                      style: WorkoutType.body(size: 13, color: tokens.dim),
                    ),
                    for (final issue in preview.issues) Text(issue),
                    for (final entry in review.entries.where(
                      (entry) => !entry.resolved,
                    ))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry.sourceName),
                        subtitle: Text(entry.rationale),
                      ),
                  ],
                ),
                if (preview.hasImportedSettings)
                  CheckboxListTile(
                    key: const Key('reps-import-settings'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(copy.applySettings),
                    value: _applySettings,
                    onChanged: _busy || _selected
                        ? null
                        : (value) =>
                              setState(() => _applySettings = value ?? false),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('reps-import-confirm'),
                  onPressed:
                      _busy || !preview.canImport || _selected || _mappingError
                      ? null
                      : _import,
                  child: Text(copy.import),
                ),
                if (_selected) ...[
                  Text(
                    copy.imported,
                    key: const Key('reps-import-success'),
                    style: WorkoutType.body(size: 14, color: tokens.text),
                  ),
                  TextButton(
                    key: const Key('reps-import-done'),
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: Text(copy.done),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
