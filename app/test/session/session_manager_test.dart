import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/active_session_draft.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/session_manager.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
  test('register/clear lifecycle notifies', () {
    final m = SessionManager();
    addTearDown(m.dispose);
    var notifies = 0;
    m.addListener(() => notifies++);

    final c = ActiveSessionController();
    addTearDown(c.dispose);
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
    addTearDown(m.dispose);
    final c = ActiveSessionController();
    addTearDown(c.dispose);
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
    addTearDown(m.dispose);
    final resumed = await m.resumeFromDraft(store: store);
    expect(resumed, isTrue);
    expect(m.hasActive, isTrue);
    expect(m.active!.draft.name, 'Upper A');
    expect(m.active!.draft.startedAt, DateTime(2026, 6, 3, 9, 0));
  });

  test('resumeFromDraft without a draft is a no-op', () async {
    final m = SessionManager();
    addTearDown(m.dispose);
    final resumed = await m.resumeFromDraft(store: FakeDraftStore());
    expect(resumed, isFalse);
    expect(m.hasActive, isFalse);
  });

  test(
    'foreground notification +30s extends the current rest without a preference mirror',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final c = ActiveSessionController();
      addTearDown(c.dispose);
      c.seedEmpty(name: 'Custom', focus: '');
      c.startRest(90);
      final startMs = c.restStart!.millisecondsSinceEpoch;

      final m = SessionManager();
      addTearDown(m.dispose);
      m.register(c);
      m.add30FromNotification();
      await m.reconcileForTest();

      expect(m.active!.restTotal, 120);
      expect(m.active!.restStart!.millisecondsSinceEpoch, startMs);
    },
  );

  test('screenOpen flag notifies on change only', () {
    final m = SessionManager();
    addTearDown(m.dispose);
    var notifies = 0;
    m.addListener(() => notifies++);
    m.screenOpen = true;
    m.screenOpen = true; // no-op
    m.screenOpen = false;
    expect(notifies, 2);
  });
}
