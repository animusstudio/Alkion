import 'package:flutter/foundation.dart';
import 'package:powersync/powersync.dart' show uuid; // shared uuid singleton (project convention)
import 'package:shared_preferences/shared_preferences.dart';

import '../capture/preference_writes.dart';
import '../capture/source_write_gate.dart';

/// Owns the device-local identity for the standalone (server-optional) app.
///
/// `currentUserId` is the owner id used for local writes that need one (the
/// `muscle_targets` seed in particular). It is generated once and persisted, or
/// ADOPTED from an existing install (a remembered login / synced data) so prior
/// rows are not orphaned. `onboardingComplete` gates the first-launch screen.
class IdentityService extends ChangeNotifier {
  static const _kUserId = 'identity.current_user_id';
  static const _kOnboarded = 'identity.onboarding_complete';

  String _currentUserId = '';
  bool _onboardingComplete = false;

  String get currentUserId => _currentUserId;
  bool get onboardingComplete => _onboardingComplete;

  Future<void> init({
    required Future<String?> Function() probeExistingUserId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString(_kUserId);
    if (persisted != null && persisted.isNotEmpty) {
      _currentUserId = persisted;
      _onboardingComplete = prefs.getBool(_kOnboarded) ?? true;
      return;
    }
    final adopted = await probeExistingUserId();
    if (adopted != null && adopted.isNotEmpty) {
      _currentUserId = adopted;
      _onboardingComplete = true;
    } else {
      _currentUserId = uuid.v4();
      _onboardingComplete = false;
    }
    final userId = _currentUserId;
    final onboarded = _onboardingComplete;
    await writePreferences('prefs.identity', (prefs) async {
      final stored = await prefs.setString(_kUserId, userId);
      return await prefs.setBool(_kOnboarded, onboarded) && stored;
    });
  }

  /// Marks onboarding complete and persists it; [parent] when it is part of
  /// the onboarding operation that seeded the catalog.
  Future<void> completeOnboarding({SourceTicket? parent}) async {
    await writePreferences(
        'prefs.identity.onboarding', (prefs) => prefs.setBool(_kOnboarded, true),
        parent: parent);
    _onboardingComplete = true;
    notifyListeners();
  }
}
