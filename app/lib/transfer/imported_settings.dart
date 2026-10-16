import 'dart:convert';

import '../domain/evidence.dart';
import '../settings/app_languages.dart';
import '../store/local_store.dart';
import '../theme/tokens.dart';
import 'transfer_service.dart';

/// Applies validated selected settings from one selected import, only on an
/// explicit request. Missing, null-where-undefined, invalid and unknown values
/// are reported and never seed defaults or overwrite current settings.
Future<Map<String, String>> applyImportedSettings(
  LocalDatabase db, {
  required String namespace,
  required String importId,
}) => db.writeTransaction((tx) async {
  final generation = await tx.getOptional(
    'SELECT selected FROM import_generations WHERE profile_id=? AND namespace=? AND import_id=?',
    [tx.profileId, namespace, importId],
  );
  if (generation?['selected'] != 1) {
    throw const StoreException('selected_import_required');
  }
  final entries = await tx.getAll(
    'SELECT entry_bytes FROM import_journal WHERE profile_id=? AND namespace=? AND import_id=? ORDER BY entry_id',
    [tx.profileId, namespace, importId],
  );
  final selected = entries
      .map((e) => decodeBytesJson(e['entry_bytes']))
      .lastWhere((e) => e['event'] == 'selected');
  final evidence = Map<String, dynamic>.from(
    (selected['envelope'] as Map)['settings'] as Map,
  );
  final settings = <String, Object?>{}, units = <String, Object?>{};
  final disposition = <String, String>{};
  for (final entry in evidence.entries) {
    final reading = Map<String, dynamic>.from(entry.value as Map);
    final state = reading['state'], token = reading['token'];
    final decoded = reading['decoded'];
    if (state == 'missing') {
      disposition[entry.key] = 'missing_not_applied';
      continue;
    }
    Object? value;
    var valid = false;
    switch (entry.key) {
      case 'unit':
        valid = token == 'string' && (decoded == 'kg' || decoded == 'lb');
        value = decoded;
      case 'mode':
        valid = token == 'string' && (decoded == 'dark' || decoded == 'light');
        value = decoded;
      case 'profile_name':
        valid = token == 'string' && (decoded as String).trim().isNotEmpty;
        value = decoded;
      case 'rest_compound_seconds' || 'rest_isolation_seconds':
        final n = token == 'number' && decoded is String
            ? int.tryParse(decoded)
            : null;
        valid = n != null && n >= 0 && n <= 86400;
        value = n;
      case 'locale':
        valid =
            token == 'nullValue' ||
            token == 'string' && appLanguages.any((l) => l.code == decoded);
        value = token == 'nullValue' ? null : decoded;
      case 'accent':
        final match = token == 'string'
            ? RegExp(r'^#([0-9A-Fa-f]{8})$').firstMatch(decoded as String)
            : null;
        final argb = match == null ? null : int.parse(match[1]!, radix: 16);
        valid = argb != null && accents.any((c) => c.toARGB32() == argb);
        value = argb;
    }
    if (!valid) {
      disposition[entry.key] = 'invalid_not_applied';
      continue;
    }
    (entry.key == 'unit' ? units : settings)[entry.key] = value;
    disposition[entry.key] = 'applied';
  }
  for (final (key, values) in [('settings', settings), ('units', units)]) {
    if (values.isEmpty) continue;
    final row = await tx.localState(LocalStateKind.semanticSetting, key);
    final current = row == null
        ? <String, Object?>{}
        : Map<String, Object?>.from(
            jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
                as Map,
          );
    await tx.putLocalState(
      LocalStateKind.semanticSetting,
      key,
      localBytes({...current, ...values}),
      expectedRevision: row?['revision'] as int? ?? 0,
    );
  }
  return disposition;
});
