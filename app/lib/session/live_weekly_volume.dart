import '../ui/today_labels.dart';
import '../util/calendar_keys.dart';
import 'active_session_controller.dart';

/// The live parts of one weekly volume row: working sets marked done in the
/// workout in progress, and its working sets not done yet.
typedef LiveVolumeSets = ({int live, int pending});

/// Working sets of the workout in progress, by muscle group.
///
/// Each non-warm-up set counts once for its block's `exercise.muscleGroup`,
/// as the weekly stat does. A block with no group adds to [unknownLive] /
/// [unknownPending].
final class DraftVolume {
  const DraftVolume({
    this.live = const {},
    this.pending = const {},
    this.unknownLive = 0,
    this.unknownPending = 0,
  });

  /// Working sets marked done, keyed by muscle group.
  final Map<String, int> live;

  /// Working sets not marked done yet, keyed by muscle group.
  final Map<String, int> pending;
  final int unknownLive;
  final int unknownPending;

  static const empty = DraftVolume();

  /// Counts [draft]'s working sets that the weekly stat does not hold yet.
  ///
  /// - A fresh workout lands on today when finished; a resumed one keeps its
  ///   own date (empty when it has none, as `finish` writes it). Sets that
  ///   would land before [weekStart] are not this week's, so they count for
  ///   nothing here.
  /// - A resumed workout's already-logged rows ([SessionDraft.setBases]) are
  ///   counted by the stat already, so they are skipped to avoid counting
  ///   them twice.
  factory DraftVolume.of(
    SessionDraft draft, {
    required DateTime weekStart,
    required DateTime now,
  }) {
    final date =
        draft.sessionDate ?? (draft.sessionId == null ? isoDate(now) : '');
    if (date.compareTo(isoDate(weekStart)) < 0) return empty;
    final live = <String, int>{};
    final pending = <String, int>{};
    var unknownLive = 0, unknownPending = 0;
    for (final block in draft.blocks) {
      final muscle = block.exercise.muscleGroup;
      for (final set in block.workingSets) {
        if (set.isWarmup || draft.setBases.containsKey(set.id)) continue;
        if (muscle.isEmpty) {
          set.done ? unknownLive++ : unknownPending++;
        } else {
          final into = set.done ? live : pending;
          into[muscle] = (into[muscle] ?? 0) + 1;
        }
      }
    }
    return DraftVolume(
      live: live,
      pending: pending,
      unknownLive: unknownLive,
      unknownPending: unknownPending,
    );
  }
}

/// Weekly volume rows combining finished sessions with the workout in
/// progress.
///
/// [rows] keeps the shape `VolumeBars` and Today already use: `sets` is the
/// done-this-week count from finished sessions. [live] is null with no
/// workout in progress, else one entry per row, in the same order.
final class LiveWeeklyVolume {
  const LiveWeeklyVolume._(this.rows, this.live, this.unknownSets);

  final List<({String muscle, int sets, int target})> rows;
  final List<LiveVolumeSets>? live;

  /// Working sets with no muscle group: finished ones plus those marked done
  /// in the workout. Planned sets are not counted until they are done.
  final int unknownSets;

  /// Combines the weekly stat ([volume], [unknownSets]) with [draft].
  ///
  /// With no [draft] the rows are exactly [weeklyVolumeRows]. With one, every
  /// muscle with sets this week, done or planned, gets a row, including
  /// muscles that appear only in the draft. Its planned total is done +
  /// live + pending; a muscle with no target uses it as its target, so the
  /// bar fills when the plan is done. Rows order by planned total, so ticking
  /// a set off never reorders them. Muscles with a target and nothing done
  /// or planned follow, as on Today.
  factory LiveWeeklyVolume.combine({
    required List<({String muscle, int sets})> volume,
    required int unknownSets,
    required Map<String, int> targets,
    DraftVolume? draft,
  }) {
    if (draft == null) {
      return LiveWeeklyVolume._(
        weeklyVolumeRows(volume, targets),
        null,
        unknownSets,
      );
    }
    final done = <String, int>{for (final v in volume) v.muscle: v.sets};
    final planned = <String, int>{
      for (final muscle in {
        ...done.keys,
        ...draft.live.keys,
        ...draft.pending.keys,
      })
        muscle:
            (done[muscle] ?? 0) +
            (draft.live[muscle] ?? 0) +
            (draft.pending[muscle] ?? 0),
    }..removeWhere((_, total) => total <= 0);
    final trained = planned.keys.toList()
      ..sort((a, b) {
        final c = planned[b]!.compareTo(planned[a]!);
        return c != 0 ? c : a.compareTo(b);
      });
    final untrained =
        targets.entries
            .where((t) => t.value > 0 && !planned.containsKey(t.key))
            .toList()
          ..sort((a, b) {
            final c = b.value.compareTo(a.value);
            return c != 0 ? c : a.key.compareTo(b.key);
          });
    return LiveWeeklyVolume._(
      [
        for (final m in trained)
          (muscle: m, sets: done[m] ?? 0, target: targets[m] ?? planned[m]!),
        for (final t in untrained) (muscle: t.key, sets: 0, target: t.value),
      ],
      [
        for (final m in trained)
          (live: draft.live[m] ?? 0, pending: draft.pending[m] ?? 0),
        for (final _ in untrained) (live: 0, pending: 0),
      ],
      unknownSets + draft.unknownLive,
    );
  }
}
