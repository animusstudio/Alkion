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
import '../theme/alkion_icon.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import '../widgets/pending_input.dart';
import '../widgets/rir_picker.dart';
import '../util/error_message.dart';
import '../widgets/w_dialog.dart';
import '../history_mapping/history_mapping_label.dart';

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
    this.workoutRevision,
  });

  /// The sets to edit; empty for an exercise just picked in History, which
  /// writes nothing until "Add set".
  final ExerciseBlockData block;
  final Exercise exercise;
  final String sessionId;
  final SessionRepository sessionRepo;
  final UnitService units;

  /// The session's observed workout revision. Required for an empty
  /// [block]; otherwise taken from its first set.
  final int? workoutRevision;

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
  bool _disposing = false;

  /// Prepared writes not yet acknowledged, in the order they were prepared.
  /// Every write in a session shares the workout revision, so each one is
  /// prepared only once all earlier ones have landed, and a failed one is
  /// retried with its own identity before anything newer is prepared: an
  /// uncertain COMMIT is reconciled, never rewritten under a new identity.
  final _prepared = <String, _PreparedWrite>{};

  /// Adds and deletes the user confirmed, in order, not yet prepared: each
  /// is prepared only once everything before it has landed, so one tapped
  /// behind a failing write is queued, never dropped.
  final _planned = <_PlannedWrite>[];

  /// A write failed and something is still unwritten: the sheet says so.
  /// A transient failure retries on the next change, close or flush.
  bool _failed = false;

  /// The failure is permanent ([historyWriteIsPermanent]): the sheet shows
  /// its mapped message and the explicit Discard set changes.
  bool _permanent = false;
  Object? _failure;

  /// A prepared or queued write at the head failed for good: every later
  /// write waits behind it, so nothing retries silently any more; only an
  /// explicit Discard set changes clears it.
  Object? _blocked;

  /// Sets whose edit cannot be prepared (no observed base). They fail
  /// alone: the other sets are still written.
  final _unpreparable = <String, Object>{};

  /// Serialises every write this sheet issues. Idle, a write starts
  /// synchronously, so the call reaches the store before whatever the
  /// caller does next (History's reload after the sheet pops).
  Future<void> _tail = Future.value();
  bool _idle = true;

  /// One owed entry for the whole sheet: the latest values of every set,
  /// after whatever it already prepared. It stays owed, even after the
  /// sheet closes, until everything has landed.
  late final String _owedKey = 'history_sets:${domainUuid.v4()}';

  ///
  /// The registry pays an entry only for the identical function it owes, so
  /// the tear-off is taken once.
  late final Future<void> Function() _retryAll = _retryAllNow;
  Future<void> _retryAllNow() => _serial(_writeAll);

  // One debounce timer per set with a pending, unpersisted edit.
  final Map<String, Timer> _timers = {};

  /// While a set's editing card is open, or an edit is not yet persisted,
  /// a persistence flush (backup, restore, close) waits for the sheet to be
  /// closed normally.
  late final Object _unsavedForm = UnsavedEditors.instance.register(
    'history_sets',
    () => _openId != null || _timers.isNotEmpty,
  );

  bool get _unwritten =>
      _prepared.isNotEmpty ||
      _planned.isNotEmpty ||
      _sets.any((s) => s.changed.isNotEmpty);

  /// Whether [id] has a delete prepared or queued: its card is locked.
  bool _deleting(String id) =>
      _prepared.containsKey('delete:$id') ||
      _planned.any((p) => p.key == 'delete:$id');

  bool get _adding =>
      _prepared.keys.any((k) => k.startsWith('add:')) ||
      _planned.any((p) => p.key.startsWith('add:'));

  @override
  void initState() {
    super.initState();
    _unsavedForm; // registered while the sheet is open
    _workoutRevision =
        widget.workoutRevision ??
        (widget.block.sets.isEmpty
            ? null
            : widget.block.sets.first.workoutRevision);
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
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    // Fire-and-forget: the sheet is going away, nothing left to await into.
    // Whatever is unwritten stays owed and is retried on the next flush.
    if (_unwritten) {
      UnsavedEditors.instance.owe(_owedKey, 'history_sets', _retryAll);
      _retryAll().then(
        (_) => UnsavedEditors.instance.paid(_owedKey, _retryAll),
        onError: (Object _) {},
      );
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted && !_disposing) setState(() {});
  }

  Future<void> _serial(Future<void> Function() run) {
    final result = _idle ? Future.sync(run) : _tail.then((_) => run());
    _idle = false;
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _tail = tail;
    tail.then((_) {
      if (identical(_tail, tail)) _idle = true;
    });
    return result;
  }

  /// Commits every prepared write in order; stops at the first failure,
  /// which stays prepared for the next attempt.
  Future<void> _drain() async {
    while (_prepared.isNotEmpty) {
      final MapEntry(:key, :value) = _prepared.entries.first;
      final outcome = await widget.sessionRepo.commitPrepared(value.intent);
      _adoptResult(jsonDecode(utf8.decode(outcome.bytes)) as Map);
      _prepared.remove(key);
      value.landed(outcome);
      _refresh();
    }
  }

  /// Writes everything unwritten after every earlier write. Owed until the
  /// sheet has nothing unwritten. Completes with whether it landed; never
  /// throws. A failure is shown once per failed state (then the inline
  /// note carries it) and keeps the work owed.
  Future<bool> _run() {
    UnsavedEditors.instance.owe(_owedKey, 'history_sets', _retryAll);
    return _serial(_writeAll).then(
      (_) {
        if (!_unwritten) {
          UnsavedEditors.instance.paid(_owedKey, _retryAll);
        }
        return true;
      },
      onError: (Object e) {
        final permanent = historyWriteIsPermanent(e);
        final changed = !_failed || permanent != _permanent;
        _failed = true;
        _permanent = permanent;
        _failure = e;
        _refresh();
        if (changed) _showFailure(e);
        return false;
      },
    );
  }

  /// Everything prepared, then each queued add or delete, then every set's
  /// latest edit. With nothing prepared before, the first write is issued
  /// synchronously. A set whose edit cannot be prepared fails alone; the
  /// other sets are still written.
  Future<void> _writeAll() async {
    final blocked = _blocked;
    if (blocked != null) {
      // No silent retries: only an explicit Discard set changes clears it.
      throw blocked;
    }
    try {
      if (_prepared.isNotEmpty) await _drain();
      while (_planned.isNotEmpty) {
        // Prepared against the bases the earlier writes left; kept queued
        // if it cannot be prepared.
        _planned.first.prepare();
        _planned.removeAt(0);
        await _drain();
      }
    } catch (e) {
      if (historyWriteIsPermanent(e)) _blocked = e;
      rethrow;
    }
    for (final s in _sets.toList()) {
      if (s.changed.isEmpty ||
          _deleting(s.id) ||
          _unpreparable.containsKey(s.id)) {
        continue;
      }
      try {
        _prepareEdit(s);
      } on StoreException catch (e) {
        if (!historyWriteIsPermanent(e)) rethrow;
        _unpreparable[s.id] = e;
        continue;
      }
      try {
        if (_prepared.isNotEmpty) await _drain();
      } catch (e) {
        if (historyWriteIsPermanent(e)) _blocked = e;
        rethrow;
      }
    }
    final stuck = _unpreparable.entries
        .where((e) => _sets.any((s) => s.id == e.key && s.changed.isNotEmpty))
        .map((e) => e.value);
    if (stuck.isNotEmpty) throw stuck.first;
    _settled();
  }

  void _settled() {
    if (_failed && !_unwritten) {
      _failed = _permanent = false;
      _failure = null;
      _refresh();
    }
  }

  /// After a permanent failure: drops only this sheet's owed writes and
  /// unwritten edits, after a destructive confirm, then closes so History
  /// shows the stored sets again.
  Future<void> _discardOwed() async {
    if (!_permanent) return;
    final l = AppLocalizations.of(context);
    final discard = await showWConfirm(
      context,
      title: l.historyDiscardSetsTitle,
      message: l.historyDiscardOwedMessage,
      cancelLabel: l.commonKeepEditing,
      confirmLabel: l.commonDiscard,
      destructive: true,
    );
    if (discard != true || !mounted || !_permanent) return;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _prepared.clear();
    _planned.clear();
    _blocked = null;
    _unpreparable.clear();
    for (final s in _sets) {
      s.changed.clear();
    }
    UnsavedEditors.instance.discard(_owedKey);
    setState(() {
      _failed = _permanent = false;
      _failure = null;
      _openId = null;
    });
    Navigator.of(context).pop();
  }

  void _adoptResult(Map result) {
    _workoutRevision = result['revision'] as int;
    final revisions = Map<String, dynamic>.from(result['sets'] as Map? ?? {});
    for (final s in _sets) {
      if (revisions[s.id] is int) {
        s.revision = revisions[s.id] as int;
      }
    }
  }

  /// Prepares [s]'s changed fields against the current bases. The edit
  /// keeps the fields it names; untouched fields keep their raw evidence,
  /// and a cleared RIR is written as null.
  void _prepareEdit(_EditableSet s) {
    if (s.changed.isEmpty || !_sets.contains(s) || _deleting(s.id)) {
      return;
    }
    if (_workoutRevision == null || s.revision == null) {
      throw const StoreException('observed_revision_required');
    }
    final edits = s.edits;
    // The editor owns its observed bases. A watch/re-read on another caller
    // cannot rebase these values onto a newer record.
    final intent = widget.sessionRepo.prepareHistoryEdit(
      widget.sessionId,
      _workoutRevision!,
      {
        'mode': 'edit',
        'set': {
          'id': s.id,
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
    _prepared['edit:${s.id}'] = _PreparedWrite(intent, (_) {
      // An edit made while this write ran is still unwritten.
      if (s.edits == edits) s.changed.clear();
    });
  }

  /// Writes [s]'s current values (and anything else unwritten). Completes
  /// with whether they landed.
  Future<bool> _persist(_EditableSet s) => _run();

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
  /// An edit while an earlier write runs or is owed is kept and written
  /// after it, never dropped.
  void _edit(
    _EditableSet s, {
    double? weight,
    int? reps,
    int? rir,
    bool clearRir = false,
  }) {
    if (_deleting(s.id)) {
      return;
    }
    // A typed weight the sheet could not show in the selected unit (a
    // saturated 1e30, or 1e16 lb) is refused: no write, nothing changes.
    if (weight != null &&
        !historyDoubleFits(weight, pounds: widget.units.unit == Unit.lb)) {
      return;
    }
    setState(() {
      s.edits++;
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
      if (rir != null || clearRir) {
        s.rir = clearRir ? null : rir;
        s.changed.add('rir');
      }
    });
    _timers[s.id]?.cancel();
    _timers[s.id] = Timer(const Duration(milliseconds: 400), () {
      _timers.remove(s.id);
      _persist(s);
    });
  }

  /// Cancels [id]'s pending debounce timer, if any, and starts persisting its
  /// current value without awaiting the round trip. When the sheet is idle
  /// the write is issued synchronously within this call — ahead of whatever
  /// a non-awaiting caller (switching sets, adding a set, or the sheet's own
  /// pop handler) does next, such as History's post-close reload.
  void _flushSync(String id) {
    final timer = _timers.remove(id);
    timer?.cancel();
    final idx = _sets.indexWhere((e) => e.id == id);
    if (idx == -1) {
      return;
    }
    final s = _sets[idx];
    if (timer == null && s.changed.isEmpty && !_failed) {
      return;
    }
    unawaited(_persist(s));
  }

  /// Flushes every set with a pending edit, synchronously. Called when the
  /// sheet is popped — see the `PopScope` in [build] — so every write is
  /// issued before the caller's own post-close reload, which otherwise
  /// races an unfired debounce timer (`showModalBottomSheet`'s future
  /// completes at pop, well before `dispose`).
  void _flushAllSync() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    if (_unwritten) {
      unawaited(_run());
    }
  }

  /// Opens [id]'s editing card, or collapses it if already open. Flushes
  /// whichever card was open before (itself, if collapsing) without waiting
  /// on the write to land.
  void _toggle(String id) {
    if (_deleting(id)) {
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
    // A set with a delete prepared or queued has its card locked, so this
    // is only a guard; the owed delete retries with everything else.
    if (_deleting(s.id)) {
      return;
    }
    commitPendingInput();
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.historyDeleteSetTitle,
      message: l.historyDeleteSetMessage,
      confirmLabel: l.commonDelete,
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // The set's unwritten edit is moot once it is deleted; an edit already
    // prepared for it is owed and lands first. Behind a failing write the
    // delete stays queued and is prepared once that write has landed.
    _timers.remove(s.id)?.cancel();
    setState(
      () => _planned.add(
        _PlannedWrite('delete:${s.id}', () {
          if (_workoutRevision == null || s.revision == null) {
            throw const StoreException('observed_revision_required');
          }
          final intent = widget.sessionRepo.prepareHistoryEdit(
            widget.sessionId,
            _workoutRevision!,
            {
              'mode': 'delete',
              'set': {'id': s.id, 'base': s.revision},
            },
          );
          _prepared['delete:${s.id}'] = _PreparedWrite(intent, (_) {
            _sets.remove(s);
            if (_openId == s.id) {
              _openId = null;
            }
          });
        }),
      ),
    );
    await _run();
  }

  /// Appends a new working set, seeded from the last working set (or the
  /// heaviest existing set, or the exercise's start weight in an empty
  /// block) with no RIR, so the user usually only needs minor tweaks, then
  /// opens its card.
  Future<void> _addSet() async {
    if (_adding) {
      // An add is owed or queued: retry it, never add a second one.
      await _run();
      return;
    }
    // The seed only needs the LOCAL `_sets` values (already current —
    // `_edit` mutates in place synchronously).
    commitPendingInput();
    final open = _openId;
    if (open != null) {
      _flushSync(open);
    }

    final working = _sets.where((s) => !s.isWarmup).toList();
    final last = working.isNotEmpty
        ? working.last
        : (_sets.isNotEmpty ? _sets.last : null);

    final double w =
        last?.weightKg ??
        (_sets.isEmpty
            ? widget.exercise.baseWeightKg ?? 0.0
            : _sets.map((s) => s.weightKg).reduce((a, b) => a >= b ? a : b));
    final int r = last?.reps ?? (widget.exercise.defaultRepLow ?? 8);
    final weightKnown = last?.weightKnown ?? true,
        repsKnown = last?.repsKnown ?? true;
    final id = domainUuid.v4();

    _planned.add(
      _PlannedWrite('add:$id', () {
        if (_workoutRevision == null) {
          throw const StoreException('observed_revision_required');
        }
        final intent = widget.sessionRepo.prepareHistoryEdit(
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
                'weight_kg': weightKnown ? w.toStringAsFixed(2) : null,
                'reps': repsKnown ? r : null,
                'rir': null,
              },
            },
          },
        );
        _prepared['add:$id'] = _PreparedWrite(intent, (outcome) {
          final frozen = Map<String, dynamic>.from(
                intent.input['set']['fields'] as Map,
              ),
              added = intent.input['set']['id'] as String;
          final result = jsonDecode(utf8.decode(outcome.bytes)) as Map;
          final revision = (result['sets'] as Map?)?[added];
          if (!_sets.any((set) => set.id == added)) {
            _sets.add(
              _EditableSet(
                id: added,
                revision: revision is int ? revision : 1,
                weightKg:
                    double.tryParse(frozen['weight_kg']?.toString() ?? '') ?? 0,
                reps: frozen['reps'] is int ? frozen['reps'] as int : 0,
                rir: null,
                weightKnown: frozen['weight_kg'] != null,
                repsKnown: frozen['reps'] is int,
                isWarmup: false,
              ),
            );
            if (!_disposing) _openId = added;
          }
        });
      }),
    );
    await _run();
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
              HistoryMappingLabel(exerciseId: widget.exercise.id),
              const SizedBox(height: 2),
              Text(
                l.historyEditSets,
                style: WorkoutType.body(size: 12, color: tokens.faint),
              ),
              if (_failed && _unwritten && !_permanent) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: FitLabel(
                    l.historyNotSavedWillRetry,
                    key: const Key('history-not-saved'),
                    maxLines: 3,
                    style: WorkoutType.body(size: 12, color: tokens.danger),
                  ),
                ),
              ],
              // A permanent failure does not retry: its mapped message and
              // the one way out, an explicit Discard set changes.
              if (_failed && _unwritten && _permanent) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: FitLabel(
                    userMessage(l, _failure!).message,
                    key: const Key('history-not-saved-permanent'),
                    maxLines: 6,
                    style: WorkoutType.body(size: 12, color: tokens.danger),
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const Key('history-discard-owed'),
                    onPressed: _discardOwed,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: tokens.danger,
                    ),
                    child: Text(l.historyDiscardSetChanges),
                  ),
                ),
              ],
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
                            locked: _deleting(_sets[i].id),
                            onTap: () => _toggle(_sets[i].id),
                            onWeight: (v) => _edit(_sets[i], weight: v),
                            onReps: (v) => _edit(_sets[i], reps: v),
                            onRir: (v) => _edit(_sets[i], rir: v),
                            onClearRir: () => _edit(_sets[i], clearRir: true),
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
                                AlkionIcon(
                                  AlkionGlyph.add,
                                  size: 16,
                                  color: tokens.text,
                                ),
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

/// Whether a History write failed for good: retrying the same prepared
/// write cannot succeed (the set or workout changed or is gone, or a base
/// was never observed). Store recovery refusals and other errors are
/// transient and keep retrying.
bool historyWriteIsPermanent(Object error) {
  if (isStoreRecoveryRefusal(error)) return false;
  if (errorBucket(error) == ErrorBucket.conflict) return true;
  return const {
    'not_found',
    'deleted_target',
    'missing_reference',
    'set_order_review_required',
    'invalid_projection_field',
    'operation_id_reuse',
    'prepared_action_mismatch',
  }.contains(errorCategory(error));
}

/// An add or delete the user confirmed, prepared when its turn comes.
class _PlannedWrite {
  _PlannedWrite(this.key, this.prepare);
  final String key;
  final void Function() prepare;
}

/// A prepared History write and what to apply locally once it lands.
class _PreparedWrite {
  _PreparedWrite(this.intent, this.landed);
  final PreparedDomainAction intent;
  final void Function(LocalActionResult outcome) landed;
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

  /// Counts local edits, so a write that lands knows whether a newer edit
  /// is still unwritten.
  int edits = 0;
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
    required this.onClearRir,
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
  final VoidCallback onClearRir;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SetLineRow(
          set: set,
          workIndex: workIndex,
          units: units,
          open: open,
          onTap: onTap,
        ),
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
                    onClearRir: onClearRir,
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
/// working sets, trailing chevron (down while its card is open). A
/// 48dp-tall tap target as a whole. Visual
/// reference: `SetLine` in `session/set_line.dart` (not reused directly —
/// its API is session-specific).
class _SetLineRow extends StatelessWidget {
  const _SetLineRow({
    required this.set,
    required this.workIndex,
    required this.units,
    required this.open,
    required this.onTap,
  });

  final _EditableSet set;
  final int workIndex;
  final UnitService units;
  final bool open;
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
              AlkionIcon(
                open ? AlkionGlyph.chevronDown : AlkionGlyph.chevronRight,
                key: Key('set-chevron-${set.id}'),
                size: 22,
                color: tokens.faint,
              ),
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
    required this.onClearRir,
    required this.onDelete,
  });

  final _EditableSet set;
  final UnitService units;
  final ValueChanged<double> onWeight;
  final ValueChanged<int> onReps;
  final ValueChanged<int> onRir;
  final VoidCallback onClearRir;
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
            // Unknown reps read "—" and type from an empty field, never
            // from a seeded number.
            repsAvailable: set.repsKnown,
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
                    // Tapping the selected chip clears RIR (stored as
                    // null); History opts in, the live workout does not.
                    child: RirPicker(
                      value: set.rir,
                      onChanged: onRir,
                      onClear: onClearRir,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Semantics(
            button: true,
            child: GestureDetector(
              key: const Key('delete-set'),
              behavior: HitTestBehavior.opaque,
              onTap: onDelete,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AlkionIcon(
                        AlkionGlyph.delete,
                        size: 16,
                        color: tokens.danger,
                      ),
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
          ),
        ],
      ),
    );
  }
}
