import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/session/active_session_controller.dart';
import 'package:workout_tracker/session/session_manager.dart';
import 'package:workout_tracker/session/workout_notification.dart';

class FakeDraftStore extends DraftStore {
  FakeDraftStore({this.draft});
  SessionDraft? draft;

  @override
  Future<SessionDraft?> load() async => draft;

  @override
  Future<void> save(SessionDraft d) async => draft = d;

  @override
  Future<void> clear() async => draft = null;
}

void main() {
  test('register/clear lifecycle notifies', () {
    final m = SessionManager();
    var notifies = 0;
    m.addListener(() => notifies++);

    final c = ActiveSessionController();
    c.seedEmpty(name: 'Custom', focus: '');
    m.register(c);
    expect(m.hasActive, isTrue);
    expect(m.active, same(c));

    m.clear();
    expect(m.hasActive, isFalse);
    expect(notifies, 2);
  });

  test('controller discard auto-clears the manager', () async {
    final m = SessionManager();
    final c = ActiveSessionController();
    c.seedEmpty(name: 'Custom', focus: '');
    m.register(c);

    await c.discard(); // draft → null → manager clears itself
    expect(m.hasActive, isFalse);
  });

  test('resumeFromDraft restores a session from disk', () async {
    final store = FakeDraftStore(
      draft: SessionDraft(
        templateId: null,
        name: 'Upper A',
        focus: 'Push',
        startedAt: DateTime(2026, 6, 3, 9, 0),
        blocks: [],
      ),
    );
    final m = SessionManager();
    final resumed = await m.resumeFromDraft(store: store);
    expect(resumed, isTrue);
    expect(m.hasActive, isTrue);
    expect(m.active!.draft.name, 'Upper A');
    expect(m.active!.draft.startedAt, DateTime(2026, 6, 3, 9, 0));
  });

  test('resumeFromDraft without a draft is a no-op', () async {
    final m = SessionManager();
    final resumed = await m.resumeFromDraft(store: FakeDraftStore());
    expect(resumed, isFalse);
    expect(m.hasActive, isFalse);
  });

  test('reconcile applies a background +30s from the prefs blob', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final c = ActiveSessionController();
    c.seedEmpty(name: 'Custom', focus: '');
    c.startRest(90);
    final startMs = c.restStart!.millisecondsSinceEpoch;

    // The background isolate already wrote +30s (90 → 120) to disk; the live
    // controller is still at 90 (its in-memory total never saw the change).
    SharedPreferences.setMockInitialValues({
      restBlobName: 'Custom',
      restBlobStartedAt: DateTime.now().toIso8601String(),
      restBlobStartMs: startMs,
      restBlobTotal: 120,
    });

    final m = SessionManager();
    m.register(c);
    await m.reconcileForTest();

    expect(m.active!.restTotal, 120);
    expect(m.active!.restStart!.millisecondsSinceEpoch, startMs);
  });

  test('screenOpen flag notifies on change only', () {
    final m = SessionManager();
    var notifies = 0;
    m.addListener(() => notifies++);
    m.screenOpen = true;
    m.screenOpen = true; // no-op
    m.screenOpen = false;
    expect(notifies, 2);
  });
}
