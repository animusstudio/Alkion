import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../capture/preference_writes.dart';
import '../capture/source_write_gate.dart';
import '../theme/tokens.dart';
import 'bodyweight_goal.dart';

const String _kMode = 'mode';
const String _kAccent = 'accent';
const String _kProfileName = 'profile_name';
const String _kServerUrl = 'server_url';

/// Avatar initials for a profile [name]: up to two leading letters of the first
/// two words, uppercased; falls back to 'A' when empty. Shared by the Profile
/// and Today greeting avatars so they never diverge.
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

/// Client-local settings: appearance (mode + accent), profile name, and
/// backend server URL. Persisted via shared_preferences; loaded once at
/// startup before the widget tree is built.
class SettingsService extends ChangeNotifier {
  String _mode = 'dark';
  Color _accent = accents[0];
  String _profileName = 'Athlete';
  String _serverUrl = 'http://localhost:8080';
  bool _syncEnabled = false;
  int _restCompoundSeconds = 180;
  int _restIsolationSeconds = 90;
  String? _localeOverride;
  bool _autoCheckUpdates = true;
  int _lastUpdateCheckMs = 0;
  BodyweightGoal _bodyweightGoal = BodyweightGoal.maintain;

  String get mode => _mode;
  Color get accent => _accent;
  String get profileName => _profileName;
  String get profileInitials => initialsOf(_profileName);
  String get serverUrl => _serverUrl;
  bool get syncEnabled => _syncEnabled;
  int get restCompoundSeconds => _restCompoundSeconds;
  int get restIsolationSeconds => _restIsolationSeconds;
  bool get autoCheckUpdates => _autoCheckUpdates;
  int get lastUpdateCheckMs => _lastUpdateCheckMs;
  BodyweightGoal get bodyweightGoal => _bodyweightGoal;

  /// The persisted language-code override (e.g. 'it'), or null to follow the
  /// system locale.
  String? get localeOverride => _localeOverride;

  /// The forced [Locale] for MaterialApp, or null to follow the system locale.
  Locale? get locale =>
      _localeOverride == null ? null : Locale(_localeOverride!);

  /// Derived brightness from the stored mode string.
  Brightness get brightness =>
      _mode == 'light' ? Brightness.light : Brightness.dark;

  /// The current accent colour (alias for direct use in buildTheme).
  Color get accentColor => _accent;

  /// Load all preferences from shared_preferences. Call once at startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    _mode = prefs.getString(_kMode) ?? 'dark';
    _profileName = prefs.getString(_kProfileName) ?? 'Athlete';
    _serverUrl = prefs.getString(_kServerUrl) ?? 'http://localhost:8080';
    _syncEnabled = prefs.getBool('settings.sync_enabled') ?? false;
    _restCompoundSeconds = prefs.getInt('settings.rest_compound_seconds') ?? 180;
    _restIsolationSeconds =
        prefs.getInt('settings.rest_isolation_seconds') ?? 90;
    _localeOverride = prefs.getString('settings.locale');
    _autoCheckUpdates = prefs.getBool('settings.auto_check_updates') ?? true;
    _lastUpdateCheckMs = prefs.getInt('settings.last_update_check_ms') ?? 0;
    final storedGoal = prefs.getString('settings.bodyweight_goal');
    _bodyweightGoal = BodyweightGoal.values
        .firstWhere((g) => g.name == storedGoal, orElse: () => BodyweightGoal.maintain);

    // Accent: stored as ARGB int via toARGB32(). Reconstruct via Color.fromARGB
    // (not Color(int) — deprecated in Flutter 3.44). Fall back to accents[0]
    // if the stored value is not one of the 4 canonical accents.
    final storedAccent = prefs.getInt(_kAccent);
    if (storedAccent != null) {
      final a = (storedAccent >> 24) & 0xFF;
      final r = (storedAccent >> 16) & 0xFF;
      final g = (storedAccent >> 8) & 0xFF;
      final b = storedAccent & 0xFF;
      final candidate = Color.fromARGB(a, r, g, b);
      _accent = accents.contains(candidate) ? candidate : accents[0];
    } else {
      _accent = accents[0];
    }

    notifyListeners();
  }

  /// Set the theme mode ('dark' or 'light') and persist.
  Future<void> setMode(String mode) async {
    if (mode == _mode) return;
    final previous = _mode;
    _mode = mode;
    await _persist('prefs.settings.mode', (p) => p.setString(_kMode, mode),
        undo: () => _mode == mode ? _mode = previous : null);
    notifyListeners();
  }

  /// Set the accent colour and persist.
  Future<void> setAccent(Color accent) async {
    if (accent == _accent) return;
    final previous = _accent;
    _accent = accent;
    await _persist(
        'prefs.settings.accent', (p) => p.setInt(_kAccent, accent.toARGB32()),
        undo: () => _accent == accent ? _accent = previous : null);
    notifyListeners();
  }

  /// Set the profile display name and persist.
  Future<void> setProfileName(String name) async {
    if (name == _profileName) return;
    final previous = _profileName;
    _profileName = name;
    await _persist(
        'prefs.settings.profile_name', (p) => p.setString(_kProfileName, name),
        undo: () => _profileName == name ? _profileName = previous : null);
    notifyListeners();
  }

  /// Set the backend server URL and persist.
  Future<void> setServerUrl(String url) async {
    if (url == _serverUrl) return;
    final previous = _serverUrl;
    _serverUrl = url;
    await _persist(
        'prefs.settings.server_url', (p) => p.setString(_kServerUrl, url),
        undo: () => _serverUrl == url ? _serverUrl = previous : null);
    notifyListeners();
  }

  /// Enable or disable background sync and persist. [parent] when it is part
  /// of a larger admitted operation (sign-out).
  Future<void> setSyncEnabled(bool value, {SourceTicket? parent}) async {
    final previous = _syncEnabled;
    _syncEnabled = value;
    await _persist('prefs.settings.sync_enabled',
        (p) => p.setBool('settings.sync_enabled', value),
        undo: () => _syncEnabled == value ? _syncEnabled = previous : null,
        parent: parent);
    notifyListeners();
  }

  /// Set the global default rest for compound exercises (seconds) and persist.
  Future<void> setRestCompoundSeconds(int v) async {
    final previous = _restCompoundSeconds;
    _restCompoundSeconds = v;
    await _persist('prefs.settings.rest_compound_seconds',
        (p) => p.setInt('settings.rest_compound_seconds', v),
        undo: () => _restCompoundSeconds == v
            ? _restCompoundSeconds = previous
            : null);
    notifyListeners();
  }

  /// Set the global default rest for isolation exercises (seconds) and persist.
  Future<void> setRestIsolationSeconds(int v) async {
    final previous = _restIsolationSeconds;
    _restIsolationSeconds = v;
    await _persist('prefs.settings.rest_isolation_seconds',
        (p) => p.setInt('settings.rest_isolation_seconds', v),
        undo: () => _restIsolationSeconds == v
            ? _restIsolationSeconds = previous
            : null);
    notifyListeners();
  }

  /// Set the language override (a code like 'it') or null to follow the system
  /// locale, and persist.
  Future<void> setLocaleOverride(String? code) async {
    final previous = _localeOverride;
    _localeOverride = code;
    await _persist(
        'prefs.settings.locale',
        (p) => code == null
            ? p.remove('settings.locale')
            : p.setString('settings.locale', code),
        undo: () =>
            _localeOverride == code ? _localeOverride = previous : null);
    notifyListeners();
  }

  /// Enable or disable the daily auto-check for app updates and persist.
  Future<void> setAutoCheckUpdates(bool value) async {
    final previous = _autoCheckUpdates;
    _autoCheckUpdates = value;
    await _persist('prefs.settings.auto_check_updates',
        (p) => p.setBool('settings.auto_check_updates', value),
        undo: () =>
            _autoCheckUpdates == value ? _autoCheckUpdates = previous : null);
    notifyListeners();
  }

  /// Set the bodyweight goal and persist.
  Future<void> setBodyweightGoal(BodyweightGoal goal) async {
    if (goal == _bodyweightGoal) return;
    final previous = _bodyweightGoal;
    _bodyweightGoal = goal;
    await _persist('prefs.settings.bodyweight_goal',
        (p) => p.setString('settings.bodyweight_goal', goal.name),
        undo: () =>
            _bodyweightGoal == goal ? _bodyweightGoal = previous : null);
    notifyListeners();
  }

  /// Record the timestamp (epoch millis) of the most recent update check and
  /// persist, gating the once/day auto-check throttle.
  Future<void> markUpdateChecked(int nowMs) async {
    final previous = _lastUpdateCheckMs;
    _lastUpdateCheckMs = nowMs;
    await _persist('prefs.settings.last_update_check_ms',
        (p) => p.setInt('settings.last_update_check_ms', nowMs),
        undo: () => _lastUpdateCheckMs == nowMs
            ? _lastUpdateCheckMs = previous
            : null);
    notifyListeners();
  }

  /// Persists one setting as an admitted source operation (see
  /// [writePreferences]). A write refused because a data capture holds the
  /// source changed nothing on disk: [undo] restores the shown value, the
  /// listeners hear it, and the refusal is rethrown for the caller to show.
  Future<void> _persist(
    String operation,
    Future<bool> Function(SharedPreferences prefs) write, {
    required void Function() undo,
    SourceTicket? parent,
  }) async {
    try {
      await writePreferences(operation, write, parent: parent);
    } catch (e) {
      if (isAdmissionRefusal(e)) {
        undo();
        notifyListeners();
      }
      rethrow;
    }
  }
}
