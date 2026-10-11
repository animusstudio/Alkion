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
    _stored = _storedSnapshot();

    notifyListeners();
  }

  /// Set the theme mode ('dark' or 'light') and persist.
  Future<void> setMode(String mode) async {
    if (mode == _mode) return;
    _mode = mode;
    await _persist<String>('prefs.settings.mode', mode,
        current: () => _mode,
        restore: (v) => _mode = v,
        write: (p) => p.setString(_kMode, mode),);
    notifyListeners();
  }

  /// Set the accent colour and persist.
  Future<void> setAccent(Color accent) async {
    if (accent == _accent) return;
    _accent = accent;
    await _persist<Color>('prefs.settings.accent', accent,
        current: () => _accent,
        restore: (v) => _accent = v,
        write: (p) => p.setInt(_kAccent, accent.toARGB32()),);
    notifyListeners();
  }

  /// Set the profile display name and persist.
  Future<void> setProfileName(String name) async {
    if (name == _profileName) return;
    _profileName = name;
    await _persist<String>('prefs.settings.profile_name', name,
        current: () => _profileName,
        restore: (v) => _profileName = v,
        write: (p) => p.setString(_kProfileName, name),);
    notifyListeners();
  }

  /// Set the backend server URL and persist.
  Future<void> setServerUrl(String url) async {
    if (url == _serverUrl) return;
    _serverUrl = url;
    await _persist<String>('prefs.settings.server_url', url,
        current: () => _serverUrl,
        restore: (v) => _serverUrl = v,
        write: (p) => p.setString(_kServerUrl, url),);
    notifyListeners();
  }

  /// Enable or disable background sync and persist. [parent] when it is part
  /// of a larger admitted operation (sign-out).
  Future<void> setSyncEnabled(bool value, {SourceTicket? parent}) async {
    _syncEnabled = value;
    await _persist<bool>('prefs.settings.sync_enabled', value,
        current: () => _syncEnabled,
        restore: (v) => _syncEnabled = v,
        write: (p) => p.setBool('settings.sync_enabled', value),
        parent: parent,);
    notifyListeners();
  }

  /// Set the global default rest for compound exercises (seconds) and persist.
  Future<void> setRestCompoundSeconds(int v) async {
    _restCompoundSeconds = v;
    await _persist<int>('prefs.settings.rest_compound_seconds', v,
        current: () => _restCompoundSeconds,
        restore: (v) => _restCompoundSeconds = v,
        write: (p) => p.setInt('settings.rest_compound_seconds', v),);
    notifyListeners();
  }

  /// Set the global default rest for isolation exercises (seconds) and persist.
  Future<void> setRestIsolationSeconds(int v) async {
    _restIsolationSeconds = v;
    await _persist<int>('prefs.settings.rest_isolation_seconds', v,
        current: () => _restIsolationSeconds,
        restore: (v) => _restIsolationSeconds = v,
        write: (p) => p.setInt('settings.rest_isolation_seconds', v),);
    notifyListeners();
  }

  /// Set the language override (a code like 'it') or null to follow the system
  /// locale, and persist.
  Future<void> setLocaleOverride(String? code) async {
    _localeOverride = code;
    await _persist<String?>('prefs.settings.locale', code,
        current: () => _localeOverride,
        restore: (v) => _localeOverride = v,
        write: (p) => code == null
            ? p.remove('settings.locale')
            : p.setString('settings.locale', code),);
    notifyListeners();
  }

  /// Enable or disable the daily auto-check for app updates and persist.
  Future<void> setAutoCheckUpdates(bool value) async {
    _autoCheckUpdates = value;
    await _persist<bool>('prefs.settings.auto_check_updates', value,
        current: () => _autoCheckUpdates,
        restore: (v) => _autoCheckUpdates = v,
        write: (p) => p.setBool('settings.auto_check_updates', value),);
    notifyListeners();
  }

  /// Set the bodyweight goal and persist.
  Future<void> setBodyweightGoal(BodyweightGoal goal) async {
    if (goal == _bodyweightGoal) return;
    _bodyweightGoal = goal;
    await _persist<BodyweightGoal>('prefs.settings.bodyweight_goal', goal,
        current: () => _bodyweightGoal,
        restore: (v) => _bodyweightGoal = v,
        write: (p) => p.setString('settings.bodyweight_goal', goal.name),);
    notifyListeners();
  }

  /// Record the timestamp (epoch millis) of the most recent update check and
  /// persist, gating the once/day auto-check throttle.
  Future<void> markUpdateChecked(int nowMs) async {
    _lastUpdateCheckMs = nowMs;
    await _persist<int>('prefs.settings.last_update_check_ms', nowMs,
        current: () => _lastUpdateCheckMs,
        restore: (v) => _lastUpdateCheckMs = v,
        write: (p) => p.setInt('settings.last_update_check_ms', nowMs),);
    notifyListeners();
  }

  /// Values last loaded from, or successfully written to, preferences, by
  /// write operation: what a refused write shows again.
  late Map<String, Object?> _stored = _storedSnapshot();

  Map<String, Object?> _storedSnapshot() => {
        'prefs.settings.mode': _mode,
        'prefs.settings.accent': _accent,
        'prefs.settings.profile_name': _profileName,
        'prefs.settings.server_url': _serverUrl,
        'prefs.settings.sync_enabled': _syncEnabled,
        'prefs.settings.rest_compound_seconds': _restCompoundSeconds,
        'prefs.settings.rest_isolation_seconds': _restIsolationSeconds,
        'prefs.settings.locale': _localeOverride,
        'prefs.settings.auto_check_updates': _autoCheckUpdates,
        'prefs.settings.bodyweight_goal': _bodyweightGoal,
        'prefs.settings.last_update_check_ms': _lastUpdateCheckMs,
      };

  /// Persists [value] (already shown) as one admitted source operation (see
  /// [writePreferences]). On success it becomes the stored value. A write
  /// refused because a data capture holds the source changed nothing on
  /// disk: if [value] is still shown, the last durably stored value is shown
  /// again (not merely the value shown before this call, which an earlier
  /// refused change may have set), the listeners hear it, and the refusal is
  /// rethrown for the caller to show.
  Future<void> _persist<T>(
    String operation,
    T value, {
    required T Function() current,
    required void Function(T stored) restore,
    required Future<bool> Function(SharedPreferences prefs) write,
    SourceTicket? parent,
  }) async {
    final stored = _stored;
    try {
      await writePreferences(operation, write, parent: parent);
      stored[operation] = value;
    } catch (e) {
      if (isAdmissionRefusal(e)) {
        final last = stored[operation] as T;
        if (current() == value && value != last) {
          restore(last);
          notifyListeners();
        }
      }
      rethrow;
    }
  }
}
