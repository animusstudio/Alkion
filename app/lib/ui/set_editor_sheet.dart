import 'dart:async';
import 'dart:convert';
import '../data/exercise_repository.dart';
import '../store/local_store.dart';
import '../domain/local_action.dart';

import 'package:flutter/material.dart';

import '../data/session_writer.dart';
import '../data/history_numeric_evidence.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../l10n/app_localizations.dart';
import '../session/set_values_editor.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import '../widgets/pending_input.dart';
import '../widgets/rir_picker.dart';
import '../widgets/w_dialog.dart';

/// The per-exercise set editor sheet opened from History: each logged set is
/// a read-only 48dp line (the same look as the live workout's `SetLine`, but
/// with its own API since it edits history rather than a live session);
/// tapping one opens it in place as an editing card with the shared
/// weight/reps rulers ([SetValuesEditor]), 48dp RIR chips and a 48dp
/// "Delete set" action. Only one card is open at a time.
///
/// Edits persist debounced (400 ms per set) via [SessionRepository.updateSet]
/// rather than on every ruler tick; a pending edit is flushed immediately on
/// close/switch/delete/add/dispose. Writes use the local repository workflow;
/// captured numeric evidence remains separate from local derivation.
class SetEditorSheet extends StatefulWidget {
  const SetEditorSheet({
    super.key,
    required this.block,
    required this.exercise,
    required this.sessionId,
    required this.sessionRepo,
    required this.units,
  });

  final ExerciseBlockData block;
  final Exercise exercise;
  final String sessionId;
  final SessionRepository sessionRepo;
  final UnitService units;

  @override
  State<SetEditorSheet> createState() => _SetEditorSheetState();
}

class _SetEditorSheetState extends State<SetEditorSheet> {
  // Local mutable copies, keyed by set id, so the sheet reflects edits/deletes
  // without a refetch while open.
  late List<_EditableSet> _sets;

  // The one set whose editing card is open, if any.
  String? _openId;
  int? _workoutRevision;
  int _writes = 0;
  bool _disposing = false;
  void _busy(int delta) {
    _writes += delta;
    if (mounted && !_disposing) {
      setState(() {});
    }
  }

  Future<LocalActionResult> _commitOwedAction(
    PreparedDomainAction intent,
    void Function() clear,
  ) async {
    final repo = widget.sessionRepo,
        key =
            'history_action:${intent.token.profileId}:${intent.action.operationId}';
    late LocalActionResult outcome;
    late Future<void> Function() write;
    write = () async {
      _busy(1);
      try {
        outcome = await repo.commitPrepared(intent);
        _adoptResult(jsonDecode(utf8.decode(outcome.bytes)) as Map);
        clear();
        UnsavedEditors.instance.paid(key, write);
      } finally {
        _busy(-1);
      }
    };
    UnsavedEditors.instance.owe(key, 'history_sets', write);
    await write();
    return outcome;
  }

  final _pendingIntents = <String, PreparedDomainAction>{};
  PreparedDomainAction? _pendingAdd, _pendingDelete;
  void _adoptResult(Map result) {
    _workoutRevision = result['revision'] as int;
    final revisions = Map<String, dynamic>.from(result['sets'] as Map? ?? {});
    for (final s in _sets) {
      if (revisions[s.id] is int) {
        s.revision = revisions[s.id] as int;
      }
    }
  }

  // One debounce timer per set with a pending, unpersisted edit.
  final Map<String, Timer> _timers = {};

  /// While a set's editing card is open, or an edit is not yet persisted,
  /// a data capture waits for the sheet to be closed normally.
  late final Object _unsavedForm = UnsavedEditors.instance.register(
    'history_sets',
    () => _openId != null || _timers.isNotEmpty,
  );

  /// Sets whose latest write was refused (a data capture held the source)
  /// or failed. Their edit stays owed — and keeps blocking capture through
  /// [UnsavedEditors.owe], even after the sheet closes — and is written
  /// again on the next collapse, switch, close or capture release.
  final Set<String> _owed = {};

  Set<String> get _unpersisted => {..._timers.keys, ..._owed};

  @override
  void initState() {
    super.initState();
    _unsavedForm; // registered while the sheet is open
    _workoutRevision = widget.block.sets.isEmpty
        ? null
        : widget.block.sets.first.workoutRevision;
    _sets = widget.block.sets
        .map(
          (s) => _EditableSet(
            id: s.id,
            revision: s.localRevision,
            weightKg: s.weightKg,
            reps: s.reps,
            rir: s.rir,
            // Unit-independent: a finite load within the kg display bound.
            // Valid text beyond it (a 400-digit decimal, 1e29) is not known.
            weightKnown: s.weightAvailable && historyDoubleFits(s.weightKg),
            repsKnown: s.repsEvidence == null || s.repsEvidence!.raw is int,
            orderKnown: s.qualifiedSetNumber != null,
            isWarmup: s.isWarmup,
          ),
        )
        .toList();
  }

  @override
  void dispose() {
    _disposing = true;
    UnsavedEditors.instance.unregister(_unsavedForm);
    // Fire-and-forget: the sheet is going away, nothing left to await into.
    // A write refused now stays owed (see [_owed]) and is retried when the
    // capture releases the source.
    for (final id in _unpersisted) {
      _timers.remove(id)?.cancel();
      final idx = _sets.indexWhere((e) => e.id == id);
      if (idx != -1) {
        _persist(_sets[idx]);
      }
    }
    super.dispose();
  }

  /// Writes [s]'s current values. The `updateSet` call is issued
  /// synchronously. The edit is owed until the write lands; a refused or
  /// failed write is shown (while the sheet is open) and stays owed.
  /// Completes with whether it landed; never throws.
  Future<bool> _persist(_EditableSet s) {
    final repo = widget.sessionRepo, id = s.id;
    if (_workoutRevision == null || s.revision == null) {
      _showFailure(const StoreException('observed_revision_required'));
      return Future.value(false);
    }
    // The editor owns its observed bases. A watch/re-read on another caller
    // cannot rebase these values onto a newer record.
    final intent = _pendingIntents[id] ??= repo.prepareHistoryEdit(
      widget.sessionId,
      _workoutRevision!,
      {
        'mode': 'edit',
        'set': {
          'id': id,
          'base': s.revision,
          'fields': {
            if (s.changed.contains('weight_kg'))
              'weight_kg': s.weightKg.toStringAsFixed(2),
            if (s.changed.contains('reps')) 'reps': s.reps,
            if (s.changed.contains('rir')) 'rir': s.rir,
          },
        },
      },
    );
    final key = 'history_set:${intent.token.profileId}:$id';
    Future<void> write() async {
      _busy(1);
      try {
        final outcome = await repo.commitPrepared(intent);
        _adoptResult(jsonDecode(utf8.decode(outcome.bytes)) as Map);
        if (identical(_pendingIntents[id], intent)) {
          _pendingIntents.remove(id);
        }
        s.changed.clear();
      } finally {
        _busy(-1);
      }
    }

    UnsavedEditors.instance.owe(key, 'history_sets', write);
    return write().then(
      (_) {
        UnsavedEditors.instance.paid(key, write);
        if (!UnsavedEditors.instance.isOwed(key)) {
          _owed.remove(id);
        }
        return true;
      },
      onError: (Object e) {
        _owed.add(id);
        _showFailure(e);
        return false;
      },
    );
  }

  bool _showingFailure = false;

  /// One failure dialog at a time: a gliding ruler can trigger several
  /// refused writes in a row.
  void _showFailure(Object error) {
    if (!mounted || _disposing || _showingFailure) {
      return;
    }
    _showingFailure = true;
    unawaited(
      showWriteFailed(
        context,
        error,
      ).whenComplete(() => _showingFailure = false),
    );
  }

  /// Mutates [s] in place, rebuilds so the editor reflects the new value
  /// (its typed-entry unchanged-value guard compares against the value it
  /// was built with), and (re)starts that set's 400 ms persist debounce.
  void _edit(_EditableSet s, {double? weight, int? reps, int? rir}) {
    if (_writes > 0 || _pendingIntents.containsKey(s.id)) {
      return;
    }
    // A typed weight the sheet could not show in the selected unit (a
    // saturated 1e30, or 1e16 lb) is refused: no write, nothing changes.
    if (weight != null &&
        !historyDoubleFits(weight, pounds: widget.units.unit == Unit.lb)) {
      return;
    }
    setState(() {
      if (weight != null) {
        s.weightKg = weight;
        s.weightKnown = true;
        s.changed.add('weight_kg');
      }
      if (reps != null) {
        s.reps = reps;
        s.repsKnown = true;
        s.changed.add('reps');
      }
      if (rir != null) {
        s.rir = rir;
        s.changed.add('rir');
      }
    });
    _timers[s.id]?.cancel();
    _timers[s.id] = Timer(const Duration(milliseconds: 400), () {
      _timers.remove(s.id);
      _persist(s);
    });
  }

  /// Cancels [id]'s pending debounce timer, if any, and awaits its persist
  /// (also of an owed edit). False if that write did not land. Used only
  /// where the caller must not race the delete against a stale value —
  /// everywhere else the write only needs to be *issued* synchronously (see
  /// [_flushSync]), not awaited.
  Future<bool> _flush(String id) async {
    final timer = _timers.remove(id);
    timer?.cancel();
    if (timer == null && !_owed.contains(id)) {
      return true;
    }
    final idx = _sets.indexWhere((e) => e.id == id);
    if (idx == -1) {
      return true;
    }
    return _persist(_sets[idx]);
  }

  /// Cancels [id]'s pending debounce timer, if any, and starts persisting its
  /// current value without awaiting the round trip. The `updateSet` call is
  /// still issued synchronously within this call — ahead of whatever a
  /// non-awaiting caller (switching sets, adding a set, or the sheet's own
  /// pop handler) does next, such as History's post-close reload.
  void _flushSync(String id) {
    final timer = _timers.remove(id);
    timer?.cancel();
    if (timer == null && !_owed.contains(id)) {
      return;
    }
    final idx = _sets.indexWhere((e) => e.id == id);
    if (idx == -1) {
      return;
    }
    unawaited(_persist(_sets[idx]));
  }

  /// Flushes every set with a pending edit, synchronously. Called when the
  /// sheet is popped — see the `PopScope` in [build] — so every `updateSet`
  /// call lands before the caller's own post-close reload, which otherwise
  /// races an unfired debounce timer (`showModalBottomSheet`'s future
  /// completes at pop, well before `dispose`).
  void _flushAllSync() {
    for (final id in _unpersisted) {
      _flushSync(id);
    }
  }

  /// Opens [id]'s editing card, or collapses it if already open. Flushes
  /// whichever card was open before (itself, if collapsing) without waiting
  /// on the write to land.
  void _toggle(String id) {
    if (_writes > 0) {
      return;
    }
    commitPendingInput();
    final previous = _openId;
    if (previous != null) {
      _flushSync(previous);
    }
    setState(() => _openId = previous == id ? null : id);
  }

  Future<void> _deleteSet(_EditableSet s) async {
    if (_writes > 0 ||
        _pendingAdd != null ||
        (_pendingDelete != null &&
            _pendingDelete!.input['set']['id'] != s.id)) {
      return;
    }
    commitPendingInput();
    if (!await _flush(s.id)) {
      return;
    } // its failure is already shown
    if (!mounted) {
      return;
    }
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.historyDeleteSetTitle,
      message: l.historyDeleteSetMessage,
      confirmLabel: l.commonDelete,
      destructive: true,
    );
    if (confirmed != true) {
      return;
    }
    try {
      if (_workoutRevision == null || s.revision == null) {
        throw const StoreException('observed_revision_required');
      }
      final intent = _pendingDelete ??= widget.sessionRepo.prepareHistoryEdit(
        widget.sessionId,
        _workoutRevision!,
        {
          'mode': 'delete',
          'set': {'id': s.id, 'base': s.revision},
        },
      );
      await _commitOwedAction(intent, () {
        _pendingDelete = null;
        if (mounted && !_disposing) {
          setState(() {
            _sets.removeWhere((set) => set.id == intent.input['set']['id']);
            if (_openId == intent.input['set']['id']) {
              _openId = null;
            }
          });
        }
      });
    } catch (e) {
      // E.g. refused while a data capture holds the source: nothing deleted.
      if (mounted) {
        await showWriteFailed(context, e);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sets.removeWhere((e) => e.id == s.id);
      if (_openId == s.id) {
        _openId = null;
      }
    });
  }

  /// Appends a new working set, seeded from the last working set (or the
  /// heaviest existing set) so the user usually only needs minor tweaks, then
  /// opens its card.
  Future<void> _addSet() async {
    if (_writes > 0 ||
        _pendingDelete != null ||
        (_pendingIntents.isNotEmpty && !_pendingIntents.containsKey(_openId))) {
      return;
    }
    // Flush BEFORE `_sets`/`working` are read below. The seed itself only
    // needs the LOCAL `_sets` values (already current — `_edit` mutates in
    // place synchronously), so this doesn't need to await the write landing;
    // it only needs to be issued before whatever runs next.
    commitPendingInput();
    final open = _openId;
    if (open != null && !await _flush(open)) {
      return;
    }
    if (!mounted) {
      return;
    }

    final working = _sets.where((s) => !s.isWarmup).toList();
    final last = working.isNotEmpty
        ? working.last
        : (_sets.isNotEmpty ? _sets.last : null);

    final double w =
        last?.weightKg ??
        (_sets.isEmpty
            ? 0.0
            : _sets.map((s) => s.weightKg).reduce((a, b) => a >= b ? a : b));
    final int r = last?.reps ?? (widget.exercise.defaultRepLow ?? 8);
    final int? rir = working.isNotEmpty ? working.last.rir : null;

    final String newId;
    try {
      if (_workoutRevision == null) {
        throw const StoreException('observed_revision_required');
      }
      final id = _pendingAdd?.input['set']['id'] as String? ?? domainUuid.v4();
      final intent = _pendingAdd ??= widget.sessionRepo.prepareHistoryEdit(
        widget.sessionId,
        _workoutRevision!,
        {
          'mode': 'add',
          'set': {
            'id': id,
            'base': 0,
            'exercise_id': widget.exercise.id,
            'is_warmup': 0,
            'fields': {
              'weight_kg': last?.weightKnown == false
                  ? null
                  : w.toStringAsFixed(2),
              'reps': last?.repsKnown == false ? null : r,
              'rir': rir,
            },
          },
        },
      );
      await _commitOwedAction(intent, () {
        _pendingAdd = null;
        final frozen = Map<String, dynamic>.from(
              intent.input['set']['fields'] as Map,
            ),
            id = intent.input['set']['id'] as String;
        if (mounted && !_disposing && !_sets.any((set) => set.id == id)) {
          setState(() {
            _sets.add(
              _EditableSet(
                id: id,
                revision: 1,
                weightKg:
                    double.tryParse(frozen['weight_kg']?.toString() ?? '') ?? 0,
                reps: frozen['reps'] is int ? frozen['reps'] as int : 0,
                rir: frozen['rir'] is int ? frozen['rir'] as int : null,
                weightKnown: frozen['weight_kg'] != null,
                repsKnown: frozen['reps'] is int,
                isWarmup: false,
              ),
            );
            _openId = id;
          });
        }
      });
      newId = intent.input['set']['id'] as String;
    } catch (e) {
      // E.g. refused while a data capture holds the source: nothing added.
      if (mounted) {
        await showWriteFailed(context, e);
      }
      return;
    }
    if (!mounted || _sets.any((set) => set.id == newId)) {
      return;
    }
    setState(() {
      _sets.add(
        _EditableSet(
          id: newId,
          revision: 1,
          weightKg: w,
          reps: r,
          rir: rir,
          weightKnown: last?.weightKnown ?? true,
          repsKnown: last?.repsKnown ?? true,
          isWarmup: false,
        ),
      );
      _openId = newId;
    });
  }

  /// The 1-based working-set index for the set at [i], or -1 for warm-ups.
  int _workIndexOf(int i) {
    if (_sets[i].isWarmup) {
      return -1;
    }
    var n = 0;
    for (var j = 0; j <= i; j++) {
      if (!_sets[j].isWarmup) {
        n++;
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    // `showModalBottomSheet`'s future completes at pop — before the exit
    // animation ends and well before `dispose` — so History's post-close
    // reload can otherwise race a still-pending debounce timer and read a
    // stale value. Flushing here issues every pending `updateSet` call
    // synchronously at pop, ahead of that reload; `dispose` keeps the same
    // flush as a backstop (idempotent — the timers are already gone).
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          return;
        }
        commitPendingInput();
        _flushAllSync();
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          decoration: BoxDecoration(
            color: tokens.surface,
            border: Border(top: BorderSide(color: tokens.line)),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.sheet),
            ),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            14,
            16,
            16 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Grab handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tokens.lineStrong,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title
              FitLabel(
                widget.exercise.name,
                maxLines: 2,
                style: WorkoutType.display(
                  size: 22,
                  weight: FontWeight.w500,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                l.historyEditSets,
                style: WorkoutType.body(size: 12, color: tokens.faint),
              ),
              const SizedBox(height: 16),

              // Sets (scrollable in case of many)
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < _sets.length; i++)
                        Reveal(
                          key: ValueKey(_sets[i].id),
                          child: _SetEntry(
                            set: _sets[i],
                            workIndex: _workIndexOf(i),
                            units: widget.units,
                            open: _openId == _sets[i].id,
                            locked:
                                _writes > 0 ||
                                _pendingIntents.isNotEmpty ||
                                _pendingAdd != null ||
                                _pendingDelete != null,
                            onTap: () => _toggle(_sets[i].id),
                            onWeight: (v) => _edit(_sets[i], weight: v),
                            onReps: (v) => _edit(_sets[i], reps: v),
                            onRir: (v) => _edit(_sets[i], rir: v),
                            onDelete: () => _deleteSet(_sets[i]),
                          ),
                        ),
                      const SizedBox(height: 6),
                      // Add-set affordance.
                      GestureDetector(
                        key: const Key('add-set'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _addSet,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(WIcons.plus, size: 14, color: tokens.text),
                                const SizedBox(width: 6),
                                Text(
                                  l.sessionAddSet,
                                  style: WorkoutType.body(
                                    size: 12,
                                    weight: FontWeight.w500,
                                    color: tokens.text,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mutable per-set editing state for the sheet.
class _EditableSet {
  _EditableSet({
    required this.id,
    this.revision,
    required this.weightKg,
    required this.reps,
    required this.rir,
    this.weightKnown = true,
    this.repsKnown = true,
    this.orderKnown = true,
    required this.isWarmup,
  });

  final String id;
  int? revision;
  final changed = <String>{};
  double weightKg;
  int reps;
  int? rir;
  bool weightKnown, repsKnown;
  final bool orderKnown;
  final bool isWarmup;

  /// Whether the load renders in [unit]; otherwise it shows `—`.
  bool showsLoad(Unit unit) =>
      weightKnown && historyDoubleFits(weightKg, pounds: unit == Unit.lb);
}

/// One set: a read-only 48dp line that is the tap target, plus (when [open])
/// its editing card underneath. The line stays visible while open and acts
/// as the card's header — tapping it again collapses the card.
class _SetEntry extends StatelessWidget {
  const _SetEntry({
    required this.set,
    required this.workIndex,
    required this.units,
    required this.open,
    required this.locked,
    required this.onTap,
    required this.onWeight,
    required this.onReps,
    required this.onRir,
    required this.onDelete,
  });

  final _EditableSet set;
  final int workIndex;
  final UnitService units;
  final bool open, locked;
  final VoidCallback onTap;
  final ValueChanged<double> onWeight;
  final ValueChanged<int> onReps;
  final ValueChanged<int> onRir;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SetLineRow(set: set, workIndex: workIndex, units: units, onTap: onTap),
        AnimatedSize(
          duration: Motion.of(context, Motion.base),
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: open
              ? AbsorbPointer(
                  absorbing: locked,
                  child: _SetEditingCard(
                    set: set,
                    units: units,
                    onWeight: onWeight,
                    onReps: onReps,
                    onRir: onRir,
                    onDelete: onDelete,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The read-only line: index/W, `{weight}{unit} × {reps}`, `RIR n` for
/// working sets, trailing chevron. A 48dp-tall tap target as a whole. Visual
/// reference: `SetLine` in `session/set_line.dart` (not reused directly —
/// its API is session-specific).
class _SetLineRow extends StatelessWidget {
  const _SetLineRow({
    required this.set,
    required this.workIndex,
    required this.units,
    required this.onTap,
  });

  final _EditableSet set;
  final int workIndex;
  final UnitService units;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final shows = set.showsLoad(units.unit);

    return Semantics(
      button: true,
      child: GestureDetector(
        key: Key('set-line-${set.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    set.isWarmup
                        ? l.sessionWarmupShort
                        : set.orderKnown
                        ? '$workIndex'
                        : '—',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: WorkoutType.mono(
                      size: 13,
                      weight: FontWeight.w400,
                      color: tokens.dim,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: shows ? units.fmtWt(set.weightKg) : '—',
                                semanticsLabel: shows
                                    ? null
                                    : l.alkionLoadUnavailableLabel,
                                style: WorkoutType.mono(
                                  size: 15,
                                  weight: FontWeight.w400,
                                  color: tokens.text,
                                ),
                              ),
                              if (shows)
                                TextSpan(
                                  text: units.uLabel,
                                  style: WorkoutType.mono(
                                    size: 12,
                                    color: tokens.faint,
                                  ),
                                ),
                              TextSpan(
                                text: '  ×  ',
                                style: WorkoutType.mono(
                                  size: 12,
                                  color: tokens.faint,
                                ),
                              ),
                              TextSpan(
                                text: set.repsKnown ? '${set.reps}' : '—',
                                style: WorkoutType.mono(
                                  size: 15,
                                  weight: FontWeight.w400,
                                  color: tokens.text,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ),
                    if (!set.isWarmup && set.rir != null) ...[
                      const SizedBox(width: 12),
                      Text(
                        l.sessionRir(set.rir!),
                        style: WorkoutType.mono(size: 12, color: tokens.faint),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(WIcons.chevron, size: 22, color: tokens.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// The open card: a bordered container like `LiveSetCard`, without its label
/// or last-session line — just the shared rulers, RIR chips, and delete.
class _SetEditingCard extends StatelessWidget {
  const _SetEditingCard({
    required this.set,
    required this.units,
    required this.onWeight,
    required this.onReps,
    required this.onRir,
    required this.onDelete,
  });

  final _EditableSet set;
  final UnitService units;
  final ValueChanged<double> onWeight;
  final ValueChanged<int> onReps;
  final ValueChanged<int> onRir;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final pounds = units.unit == Unit.lb;

    TextStyle caption() => WorkoutType.body(
      size: 12,
      color: tokens.faint,
      letterSpacing: 0.08 * 10,
    );
    Widget inset(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: child,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: tokens.surface2,
        borderRadius: BorderRadius.circular(AppRadius.panel),
        border: Border.all(color: tokens.lineStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Whenever the line shows `—` for the load, including a load that
          // only the other unit can show, which is why the ruler reads 0.
          if (!set.showsLoad(units.unit))
            inset(
              FitLabel(l.alkionLoadUnavailable, maxLines: 6, style: caption()),
            ),
          if (!set.repsKnown || !set.orderKnown)
            inset(Text(l.alkionLegacyFallback, style: caption())),
          SetValuesEditor(
            // Only a load the selected unit can show seeds the ruler; an
            // untouched card writes nothing either way.
            weightKg: historyDoubleFits(set.weightKg, pounds: pounds)
                ? set.weightKg
                : 0.0,
            reps: set.reps,
            unit: units,
            onWeight: onWeight,
            onReps: onReps,
          ),
          if (!set.isWarmup) ...[
            const SizedBox(height: 12),
            // When the chips wrap to two rows, the caption stays level with the
            // first.
            inset(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 48,
                    child: Center(
                      child: Text(l.sessionColRir, style: caption()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RirPicker(value: set.rir, onChanged: onRir),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          GestureDetector(
            key: const Key('delete-set'),
            behavior: HitTestBehavior.opaque,
            onTap: onDelete,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(WIcons.trash, size: 16, color: tokens.danger),
                    const SizedBox(width: 8),
                    Text(
                      l.historyDeleteSet,
                      style: WorkoutType.body(
                        size: 14,
                        weight: FontWeight.w500,
                        color: tokens.danger,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
