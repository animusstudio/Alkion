import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Store-generation selection inside one profile directory.
///
/// Without a selection file the T2 canonical `alkion.sqlite` stays selected.
/// A completed manual restore selects `generations/<restore id>/alkion.sqlite`
/// by atomically replacing [selectionFileName]. Previous generations are never
/// moved or deleted; they are fenced through their own persisted metadata.
const selectionFileName = 'selected-generation.json';
const selectionFormat = 'alkion-selected-generation';
const generationsDirectoryName = 'generations';
const generationDatabaseName = 'alkion.sqlite';
const restoreIntentName = 'intent.json';
const restoreSelectedName = 'selected.json';
const restoreAbandonedName = 'abandoned.json';
String freshPreparationDirectory(String supportRoot, String applicationId) =>
    p.join(p.dirname(supportRoot), '.$applicationId-fresh-restore');
final restoreIdPattern = RegExp(r'^rs-[0-9a-f]{32}$');

/// Raised before any store byte is opened. Categories are stable.
final class GenerationSelectionException implements Exception {
  const GenerationSelectionException(this.category);
  final String category;
  @override
  String toString() => 'Alkion store generation: $category';
}

String generationDirectory(String profileDirectory, String restoreId) =>
    p.join(profileDirectory, generationsDirectoryName, restoreId);

String generationDatabasePath(String profileDirectory, String restoreId) =>
    p.join(
      generationDirectory(profileDirectory, restoreId),
      generationDatabaseName,
    );

bool _present(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// The restore ID recorded by the selection file, or null for the canonical
/// generation. Malformed or linked selection bytes are preserved and refused.
String? selectedRestoreId(String profileDirectory) {
  final path = p.join(profileDirectory, selectionFileName);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return null;
  }
  if (type == FileSystemEntityType.file) {
    try {
      final value = jsonDecode(File(path).readAsStringSync());
      final id = value is Map ? value['restore_id'] : null;
      if (value is Map &&
          value['format'] == selectionFormat &&
          value['version'] == 1 &&
          id is String &&
          restoreIdPattern.hasMatch(id)) {
        return id;
      }
    } on FormatException {
      // Preserved below as invalid selection bytes.
    }
  }
  throw const GenerationSelectionException('selected_generation_invalid');
}

/// Restores whose durable intent is neither selected nor abandoned. Any such
/// restore refuses every opener until it is explicitly completed or abandoned.
List<String> pendingRestoreIds(String profileDirectory) {
  final directory = p.join(profileDirectory, generationsDirectoryName);
  final type = FileSystemEntity.typeSync(directory, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return const [];
  }
  if (type != FileSystemEntityType.directory) {
    throw const GenerationSelectionException('selected_generation_invalid');
  }
  final selected = selectedRestoreId(profileDirectory);
  final pending = <String>[];
  for (final entry in Directory(directory).listSync(followLinks: false)) {
    final id = p.basename(entry.path);
    if (!restoreIdPattern.hasMatch(id)) {
      continue;
    }
    if (FileSystemEntity.typeSync(entry.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const GenerationSelectionException('selected_generation_invalid');
    }
    if (_present(p.join(entry.path, restoreIntentName)) &&
        !_present(p.join(entry.path, restoreSelectedName)) &&
        !_present(p.join(entry.path, restoreAbandonedName)) &&
        id != selected) {
      pending.add(id);
    }
  }
  return pending..sort();
}

/// Resolves the selected database file. A selected generation whose file is
/// missing is refused, never recreated empty.
String selectedDatabasePath(String profileDirectory) {
  if (pendingRestoreIds(profileDirectory).isNotEmpty) {
    throw const GenerationSelectionException('restore_interrupted');
  }
  final restoreId = selectedRestoreId(profileDirectory);
  if (restoreId == null) {
    return p.join(profileDirectory, generationDatabaseName);
  }
  final path = generationDatabasePath(profileDirectory, restoreId);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const GenerationSelectionException('selected_generation_missing');
  }
  return path;
}
