import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/data/finished_session_store.dart';
import 'package:alkion/data/models.dart';
import 'package:alkion/l10n/app_localizations.dart';
import 'package:alkion/session/active_session_controller.dart';
import 'package:alkion/session/resume.dart';

FinishedSession fin({
  String id = 'S',
  String date = '2026-09-23',
  DateTime? at,
  SessionDraft? draft,
}) => FinishedSession(
  sessionId: id,
  sessionDate: date,
  finishedAt: at ?? DateTime(2026, 9, 23, 10, 0),
  elapsedSeconds: 2400,
  draft:
      draft ??
      SessionDraft(
        templateId: null,
        name: 'Upper A',
        focus: '',
        startedAt: DateTime(2026, 9, 23, 9, 20),
        blocks: [],
      ),
);

Exercise ex(String id) => Exercise(
  id: id,
  name: id,
  slug: id,
  muscleGroup: 'chest',
  compound: true,
  plateStepKg: 2.5,
  isTemplate: false,
);

BlockState block(String exId, List<SetState> warm, List<SetState> work) =>
    BlockState(
      exercise: ex(exId),
      resolved: ResolvedSlot(
        exercise: ex(exId),
        workSets: work.length,
        warmupSets: warm.length,
        repLow: 5,
        repHigh: 8,
        rirLow: 1,
        rirHigh: 2,
      ),
      warmupSets: warm,
      workingSets: work,
      expanded: true,
      bestKg: 90,
    );

SetState mkSet(
  String id, {
  double w = 100,
  int reps = 5,
  bool done = true,
  bool warmup = false,
}) => SetState(
  id: id,
  weightKg: w,
  reps: reps,
  rir: warmup ? null : 1,
  isWarmup: warmup,
  done: done,
);

LoggedSet row(
  String id,
  String exId,
  int n, {
  double w = 100,
  int reps = 5,
  int? rir = 1,
  bool warmup = false,
}) => LoggedSet(
  id: id,
  exerciseId: exId,
  setNumber: n,
  weightKg: w,
  reps: reps,
  rir: warmup ? null : rir,
  isWarmup: warmup,
  isTopSet: false,
  isPr: false,
);

/// Snapshot: row block first (t1 done, t2 planned), then bench (w1, s1, s2
/// done, s3 planned), then dips (d1 done only).
SessionDraft snapshot() => SessionDraft(
  templateId: 'd1',
  name: 'Upper A',
  focus: 'Push',
  startedAt: DateTime(2026, 9, 23, 9),
  sessionId: null,
  blocks: [
    block('row', [], [mkSet('t1', w: 50), mkSet('t2', w: 50, done: false)]),
    block(
      'bench',
      [mkSet('w1', w: 40, warmup: true)],
      [mkSet('s1'), mkSet('s2', w: 95), mkSet('s3', w: 95, done: false)],
    ),
    block('dips', [], [mkSet('d1', w: 0, reps: 12)]),
  ],
);

/// The DB rows matching [snapshot] exactly (ordered like setsForSession:
/// exercise_id, set_number).
List<LoggedSet> unchangedRows() => [
  row('w1', 'bench', 1, w: 40, warmup: true),
  row('s1', 'bench', 2),
  row('s2', 'bench', 3, w: 95),
  row('d1', 'dips', 1, w: 0, reps: 12),
  row('t1', 'row', 1, w: 50),
];

void main() {
  group('isResumable', () {
    test('same calendar day', () {
      expect(isResumable(fin(), 'S', DateTime(2026, 9, 23, 22, 0)), isTrue);
    });
    test('00:20 after a 23:50 finish', () {
      expect(
        isResumable(
          fin(date: '2026-09-22', at: DateTime(2026, 9, 22, 23, 50)),
          'S',
          DateTime(2026, 9, 23, 0, 20),
        ),
        isTrue,
      );
    });
    test('61 minutes after a previous-day finish', () {
      expect(
        isResumable(
          fin(date: '2026-09-22', at: DateTime(2026, 9, 22, 23, 50)),
          'S',
          DateTime(2026, 9, 23, 0, 51),
        ),
        isFalse,
      );
    });
    test(
      're-finished after midnight: only the grace hour, not the whole next day',
      () {
        final f = fin(date: '2026-09-22', at: DateTime(2026, 9, 23, 0, 30));
        expect(isResumable(f, 'S', DateTime(2026, 9, 23, 1, 15)), isTrue);
        expect(isResumable(f, 'S', DateTime(2026, 9, 23, 12, 0)), isFalse);
      },
    );
    test('wrong session or no snapshot', () {
      expect(
        isResumable(fin(), 'other', DateTime(2026, 9, 23, 10, 5)),
        isFalse,
      );
      expect(isResumable(null, 'S', DateTime(2026, 9, 23, 10, 5)), isFalse);
    });
    test('a clock moved back counts as within the hour', () {
      expect(isResumable(fin(), 'S', DateTime(2026, 9, 22, 23, 0)), isTrue);
    });
  });

  group('resumableUntil', () {
    test('a daytime finish lasts until the end of its day', () {
      expect(resumableUntil(fin()), DateTime(2026, 9, 24));
    });
    test('a late finish lasts its grace hour past midnight', () {
      expect(
        resumableUntil(
          fin(date: '2026-09-22', at: DateTime(2026, 9, 22, 23, 50)),
        ),
        DateTime(2026, 9, 23, 0, 50),
      );
    });
    test('a re-finish after midnight lasts only its grace hour', () {
      expect(
        resumableUntil(
          fin(date: '2026-09-22', at: DateTime(2026, 9, 23, 0, 30)),
        ),
        DateTime(2026, 9, 23, 1, 30),
      );
    });
  });

  group('resumeStateFor', () {
    final now = DateTime(2026, 9, 23, 10, 5);
    test('none without a snapshot or a running resume', () {
      expect(
        resumeStateFor(
          activeSessionId: null,
          lastFinished: null,
          sessionId: 'S',
          now: now,
        ),
        SessionResumeState.none,
      );
    });
    test(
      'available while the snapshot is resumable (a fresh live workout has no sessionId, so it does not count)',
      () {
        expect(
          resumeStateFor(
            activeSessionId: null,
            lastFinished: fin(),
            sessionId: 'S',
            now: now,
          ),
          SessionResumeState.available,
        );
      },
    );
    test('inProgress for the resumed session', () {
      expect(
        resumeStateFor(
          activeSessionId: 'S',
          lastFinished: null,
          sessionId: 'S',
          now: now,
        ),
        SessionResumeState.inProgress,
      );
    });
    test('inProgress wins when the kept snapshot matches too', () {
      expect(
        resumeStateFor(
          activeSessionId: 'S',
          lastFinished: fin(),
          sessionId: 'S',
          now: now,
        ),
        SessionResumeState.inProgress,
      );
    });
    test('a later finish supersedes an earlier workout of the same day', () {
      expect(
        resumeStateFor(
          activeSessionId: null,
          lastFinished: fin(id: 'B'),
          sessionId: 'A',
          now: now,
        ),
        SessionResumeState.none,
      );
    });
  });

  group('resumeTapAction', () {
    test('the resumed workout itself is running → reopen it', () {
      expect(
        resumeTapAction(SessionResumeState.inProgress, hasActive: true),
        ResumeTapAction.openRunning,
      );
    });
    test(
      'the window closed since the card was built → forget the snapshot',
      () {
        expect(
          resumeTapAction(SessionResumeState.none, hasActive: false),
          ResumeTapAction.forgetExpired,
        );
        expect(
          resumeTapAction(SessionResumeState.none, hasActive: true),
          ResumeTapAction.forgetExpired,
        );
      },
    );
    test('another workout is running → blocked', () {
      expect(
        resumeTapAction(SessionResumeState.available, hasActive: true),
        ResumeTapAction.blockedByActive,
      );
    });
    test('otherwise → resume', () {
      expect(
        resumeTapAction(SessionResumeState.available, hasActive: false),
        ResumeTapAction.resume,
      );
    });
  });

  group('mergeLoggedSets', () {
    test('unchanged rows keep every set, the block order and planned sets', () {
      final m = mergeLoggedSets(snapshot(), unchangedRows());
      expect(m.unmatched, isEmpty);
      expect(m.draft.blocks.map((b) => b.exercise.id), [
        'row',
        'bench',
        'dips',
      ]);
      final bench = m.draft.blocks[1];
      expect(bench.warmupSets.map((s) => s.id), ['w1']);
      expect(bench.workingSets.map((s) => s.id), ['s1', 's2', 's3']);
      expect(bench.workingSets.map((s) => s.done), [true, true, false]);
      expect(m.draft.blocks[0].workingSets.map((s) => s.id), ['t1', 't2']);
    });

    test('a History edit wins over the snapshot', () {
      final rows = unchangedRows()
        ..removeWhere((r) => r.id == 's2')
        ..add(row('s2', 'bench', 3, w: 97.5, reps: 6, rir: 2));
      final s2 = mergeLoggedSets(
        snapshot(),
        rows,
      ).draft.blocks[1].workingSets[1];
      expect(s2.weightKg, 97.5);
      expect(s2.reps, 6);
      expect(s2.rir, 2);
      expect(s2.done, isTrue);
    });

    test('a set deleted in History is dropped', () {
      final rows = unchangedRows()..removeWhere((r) => r.id == 's2');
      expect(
        mergeLoggedSets(
          snapshot(),
          rows,
        ).draft.blocks[1].workingSets.map((s) => s.id),
        ['s1', 's3'],
      );
    });

    test('sets added in History join their block in set order', () {
      final rows = unchangedRows()
        ..add(row('h2', 'bench', 6, w: 80, reps: 10))
        ..add(row('h1', 'bench', 5, w: 80, reps: 10));
      final bench = mergeLoggedSets(snapshot(), rows).draft.blocks[1];
      expect(bench.workingSets.map((s) => s.id), [
        's1',
        's2',
        's3',
        'h1',
        'h2',
      ]);
      expect(bench.workingSets.last.done, isTrue);
    });

    test(
      'a set added in History for another exercise is reported as unmatched',
      () {
        final rows = unchangedRows()..add(row('x1', 'curl', 1, w: 20));
        final m = mergeLoggedSets(snapshot(), rows);
        expect(m.unmatched.single.exerciseId, 'curl');
        expect(m.unmatched.single.rows.single.id, 'x1');
        expect(m.draft.blocks.map((b) => b.exercise.id), [
          'row',
          'bench',
          'dips',
        ]);
      },
    );

    test(
      'a block whose sets were all deleted is dropped; one with planned sets stays',
      () {
        final rows = unchangedRows()
          ..removeWhere((r) => r.id == 'd1' || r.id == 't1');
        final m = mergeLoggedSets(snapshot(), rows);
        expect(m.draft.blocks.map((b) => b.exercise.id), ['row', 'bench']);
        expect(m.draft.blocks[0].workingSets.map((s) => s.id), ['t2']);
      },
    );

    test(
      'an unticked snapshot set that was logged later counts as done, once',
      () {
        final rows = unchangedRows()
          ..add(row('s3', 'bench', 4, w: 100, reps: 4));
        final bench = mergeLoggedSets(snapshot(), rows).draft.blocks[1];
        expect(bench.workingSets.map((s) => s.id), ['s1', 's2', 's3']);
        expect(bench.workingSets.last.done, isTrue);
        expect(bench.workingSets.last.reps, 4);
      },
    );

    test('merging leaves the snapshot untouched', () {
      final source = snapshot();
      final rows = unchangedRows()
        ..removeWhere((r) => r.id == 's2')
        ..add(row('s2', 'bench', 3, w: 97.5));
      mergeLoggedSets(source, rows);
      expect(source.blocks[1].workingSets[1].weightKg, 95);
    });
  });

  group('discardDialogCopy', () {
    final en = lookupAppLocalizations(const Locale('en'));
    SessionDraft d({String? sessionId}) => SessionDraft(
      templateId: null,
      name: 'Upper A',
      focus: '',
      startedAt: DateTime(2026, 9, 23, 9),
      blocks: [],
      sessionId: sessionId,
    );

    test('a fresh workout warns that its logged sets will be lost', () {
      final copy = discardDialogCopy(en, d());
      expect(copy.title, 'Discard workout?');
      expect(copy.message, 'Your logged sets will be lost.');
    });

    test('a resumed workout says History keeps the finished version', () {
      final copy = discardDialogCopy(en, d(sessionId: 'S'));
      expect(copy.title, 'Discard changes?');
      expect(
        copy.message,
        'The workout stays in History as it was when you finished it.',
      );
    });

    test('Italian', () {
      final copy = discardDialogCopy(
        lookupAppLocalizations(const Locale('it')),
        d(sessionId: 'S'),
      );
      expect(copy.title, 'Scartare le modifiche?');
    });
  });

  test('a failed resume names its error', () {
    expect(
      lookupAppLocalizations(
        const Locale('en'),
      ).historyResumeFailed('disk full'),
      'Failed to resume workout: disk full',
    );
    expect(
      lookupAppLocalizations(
        const Locale('it'),
      ).historyResumeFailed('disk full'),
      'Ripresa allenamento non riuscita: disk full',
    );
  });
}
