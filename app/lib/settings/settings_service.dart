import 'package:flutter/foundation.dart' show listEquals;
import 'dart:convert';
import 'package:flutter/material.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';
import '../theme/tokens.dart';
import '../identity/alkion_identity.dart';
import 'bodyweight_goal.dart';

String initialsOf(String name) {
  final letters = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(2)
      .map((w) => w[0])
      .join();
  return letters.isEmpty ? 'A' : letters.toUpperCase();
}

/// One revisioned profile-scoped preference snapshot. No platform preference backend.
class LocalPreferences {
  LocalPreferences(this.database, this.key);
  final LocalDatabase database;
  final String key;
  int revision = 0;
  Future<Map<String, dynamic>> load() => database.readTransaction((tx) async {
    final row = await tx.localState(LocalStateKind.semanticSetting, key);
    revision = row?['revision'] as int? ?? 0;
    return row == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(
            jsonDecode(utf8.decode((row['payload_bytes'] as List).cast<int>()))
                as Map,
          );
  });
  Future<void> save(Map<String, Object?> value) async {
    final bytes = localBytes(value), base = revision, token = database.token;
    // Reconcile an uncertain local-state COMMIT before retrying identical bytes.
    final row = await database.readTransaction(
      (tx) => tx.localState(LocalStateKind.semanticSetting, key),
      expected: token,
    );
    if (row != null &&
        row['revision'] == base + 1 &&
        listEquals<int>((row['payload_bytes'] as List).cast<int>(), bytes)) {
      revision = base + 1;
      return;
    }
    final committed = await database.writeTransaction(
      (tx) => tx.putLocalState(
        LocalStateKind.semanticSetting,
        key,
        bytes,
        expectedRevision: base,
      ),
      expected: token,
    );
    revision = committed;
  }
}

class SettingsService extends ChangeNotifier {
  SettingsService() : _preferences = null;
  SettingsService.local(LocalDatabase database)
    : _preferences = LocalPreferences(database, 'settings');
  final LocalPreferences? _preferences;
  String _mode = 'dark', _profileName = 'Athlete';
  Color _accent = accents[0];
  int _restCompoundSeconds = 180, _restIsolationSeconds = 90;
  String? _localeOverride;
  BodyweightGoal _bodyweightGoal = BodyweightGoal.maintain;
  String get mode => _mode;
  Color get accent => _accent;
  Color get accentColor => _accent;
  String get profileName => _profileName;
  String get profileInitials => initialsOf(_profileName);
  String get serverUrl => '';
  bool get syncEnabled => false;
  bool get autoCheckUpdates => false;
  int get lastUpdateCheckMs => 0;
  int get restCompoundSeconds => _restCompoundSeconds;
  int get restIsolationSeconds => _restIsolationSeconds;
  String? get localeOverride => _localeOverride;
  Locale? get locale =>
      _localeOverride == null ? null : Locale(_localeOverride!);
  Brightness get brightness =>
      _mode == 'light' ? Brightness.light : Brightness.dark;
  BodyweightGoal get bodyweightGoal => _bodyweightGoal;
  Future<void> load() async {
    final p = _preferences;
    if (p == null) return;
    final data = await p.load();
    _mode = data['mode'] as String? ?? 'dark';
    _profileName = data['profile_name'] as String? ?? 'Athlete';
    final color = data['accent'] as int?;
    _accent = accents.firstWhere(
      (c) => c.toARGB32() == color,
      orElse: () => accents[0],
    );
    _restCompoundSeconds = data['rest_compound_seconds'] as int? ?? 180;
    _restIsolationSeconds = data['rest_isolation_seconds'] as int? ?? 90;
    _localeOverride = data['locale'] as String?;
    _bodyweightGoal = BodyweightGoal.values.firstWhere(
      (g) => g.name == data['bodyweight_goal'],
      orElse: () => BodyweightGoal.maintain,
    );
    notifyListeners();
  }

  Map<String, Object?> _snapshot() => {
    'mode': _mode,
    'profile_name': _profileName,
    'accent': _accent.toARGB32(),
    'rest_compound_seconds': _restCompoundSeconds,
    'rest_isolation_seconds': _restIsolationSeconds,
    'locale': _localeOverride,
    'bodyweight_goal': _bodyweightGoal.name,
  };
  Future<void> _tail = Future.value();
  (Object, StackTrace)? _error;
  Future<void> _save() {
    final snapshot = _snapshot();
    final future = _tail.then((_) async {
      final p = _preferences;
      if (p == null) throw const StoreException('unbound_preferences');
      await p.save(snapshot);
    });
    _tail = future.then(
      (_) {
        _error = null;
      },
      onError: (Object e, StackTrace st) {
        _error = (e, st);
      },
    );
    notifyListeners();
    return future;
  }

  Future<void> flushPersistence() async {
    while (true) {
      final pending = _tail;
      await pending;
      if (identical(pending, _tail)) break;
    }
    final e = _error;
    if (e != null) Error.throwWithStackTrace(e.$1, e.$2);
  }

  Future<void> setMode(String v) {
    _mode = v;
    return _save();
  }

  Future<void> setAccent(Color v) {
    _accent = v;
    return _save();
  }

  Future<void> setProfileName(String v) {
    _profileName = v;
    return _save();
  }

  Future<void> setRestCompoundSeconds(int v) {
    if (v < 0) throw const StoreException('malformed_value');
    _restCompoundSeconds = v;
    return _save();
  }

  Future<void> setRestIsolationSeconds(int v) {
    if (v < 0) throw const StoreException('malformed_value');
    _restIsolationSeconds = v;
    return _save();
  }

  Future<void> setLocaleOverride(String? v) {
    _localeOverride = v;
    return _save();
  }

  Future<void> setBodyweightGoal(BodyweightGoal v) {
    _bodyweightGoal = v;
    return _save();
  }

  Future<void> setServerUrl(String v) async =>
      AlkionIdentity.unavailable('account connection');
  Future<void> setSyncEnabled(bool v, {Object? parent}) async =>
      AlkionIdentity.unavailable('synchronization');
  Future<void> setAutoCheckUpdates(bool v) async {
    if (v) AlkionIdentity.unavailable('release updates');
  }

  Future<void> markUpdateChecked(int v) async =>
      AlkionIdentity.unavailable('release updates');
}
