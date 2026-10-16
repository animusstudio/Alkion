import 'package:flutter/foundation.dart';
import '../domain/evidence.dart';
import '../store/local_store.dart';

/// Profile identity is the selected Alkion profile, independent of accounts.
class IdentityService extends ChangeNotifier {
  IdentityService() : _database = null;
  IdentityService.local(this._database);
  final LocalDatabase? _database;
  String get currentUserId => _database?.profileId ?? '';
  bool _onboardingComplete = false;
  bool get onboardingComplete => _onboardingComplete;
  int _revision = 0;
  Future<void> init({Future<String?> Function()? probeExistingUserId}) =>
      load();
  Future<void> load() async {
    final db = _database;
    if (db == null) {
      throw const StoreException('local_store_required');
    }
    final row = await db.readTransaction(
      (tx) => tx.localState(LocalStateKind.onboarding, 'complete'),
    );
    _revision = row?['revision'] as int? ?? 0;
    _onboardingComplete = row?['status'] == 'complete';
  }

  Future<void>? _pending;
  Future<void> completeOnboarding() {
    return _pending ??= _complete().whenComplete(() => _pending = null);
  }

  Future<void> _complete() async {
    final db = _database;
    if (db == null) {
      throw const StoreException('local_store_required');
    }
    final token = db.token, base = _revision;
    final next = await db.writeTransaction((tx) async {
      final old = await tx.localState(LocalStateKind.onboarding, 'complete');
      if (old?['revision'] == base + 1 && old?['status'] == 'complete') {
        return base + 1;
      }
      return tx.putLocalState(
        LocalStateKind.onboarding,
        'complete',
        localBytes({'profileId': db.profileId}),
        expectedRevision: base,
        status: 'complete',
      );
    }, expected: token);
    _revision = next;
    _onboardingComplete = true;
    notifyListeners();
  }

  Future<void> flushPersistence() async {
    await _pending;
  }
}
