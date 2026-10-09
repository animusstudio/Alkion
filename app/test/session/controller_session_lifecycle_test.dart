import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/data/active_session_draft.dart';
import 'package:workout_tracker/session/active_session_controller.dart';

/// In-memory DraftStore double (DraftStore methods are non-final).
class FakeDraftStore extends DraftStore {
  String? saved;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<void> save(SessionDraft draft) async {
    saved = draft.name;
    saveCount++;
  }

  @override
  Future<SessionDraft?> load() async => null;

  @override
  Future<void> clear() async {
    saved = null;
    clearCount++;
  }
}

void main() {
  group('rest timer state', () {
    test('startRest/addRestTime/stopRest transitions and notifications', () {
      final c = ActiveSessionController();
      c.seedEmpty(name: 'Custom', focus: '');
      var notifies = 0;
      c.addListener(() => notifies++);

      expect(c.restStart, isNull);
      c.startRest(90);
      expect(c.restStart, isNotNull);
      expect(c.restTotal, 90);
      c.addRestTime(30);
      expect(c.restTotal, 120);
      c.stopRest();
      expect(c.restStart, isNull);
      expect(c.restTotal, 0);
      expect(notifies, 3);
    });

    test('addRestTime and stopRest are no-ops when not resting', () {
      final c = ActiveSessionController();
      c.seedEmpty(name: 'Custom', focus: '');
      var notifies = 0;
      c.addListener(() => notifies++);
      c.addRestTime(30);
      c.stopRest();
      expect(c.restTotal, 0);
      expect(notifies, 0);
    });
  });

  group('fromDraft', () {
    test('adopts an existing draft as-is', () {
      final draft = SessionDraft(
        templateId: null,
        name: 'Upper A',
        focus: 'Push',
        startedAt: DateTime(2026, 6, 3, 10, 0),
        blocks: [],
      );
      final c = ActiveSessionController.fromDraft(draft);
      expect(c.hasSession, isTrue);
      expect(c.draft.name, 'Upper A');
      expect(c.draft.startedAt, DateTime(2026, 6, 3, 10, 0));
    });
  });

  group('debounced autosave', () {
    test('mutation saves the draft after the debounce window', () async {
      final store = FakeDraftStore();
      final c = ActiveSessionController(draftStore: store);
      c.seedEmpty(name: 'Custom', focus: '');
      c.markChanged();
      expect(store.saveCount, 0); // not yet — debounced
      await Future<void>.delayed(
          ActiveSessionController.saveDebounce + const Duration(milliseconds: 200));
      expect(store.saveCount, 1);
      expect(store.saved, 'Custom');
    });

    test('discard cancels pending saves and clears the store', () async {
      final store = FakeDraftStore();
      final c = ActiveSessionController(draftStore: store);
      c.seedEmpty(name: 'Custom', focus: '');
      c.markChanged();
      await c.discard();
      await Future<void>.delayed(
          ActiveSessionController.saveDebounce + const Duration(milliseconds: 200));
      expect(store.saveCount, 0); // pending save cancelled
      expect(store.clearCount, 1);
      expect(c.hasSession, isFalse);
    });

    test('no store → no autosave attempt (and no crash)', () async {
      final c = ActiveSessionController();
      c.seedEmpty(name: 'Custom', focus: '');
      c.markChanged();
      await Future<void>.delayed(
          ActiveSessionController.saveDebounce + const Duration(milliseconds: 200));
      expect(c.hasSession, isTrue);
    });
  });
}
