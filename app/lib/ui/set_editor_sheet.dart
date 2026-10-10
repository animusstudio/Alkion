import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/session_capture_hooks.dart';
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
/// close/switch/delete/add/dispose. Re-derives is_top_set locally on every
/// write (see SessionRepository.updateSet); is_pr is left to the server.
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

  // One debounce timer per set with a pending, unpersisted edit.
  final Map<String, Timer> _timers = {};

  /// While a set's editing card is open, or an edit is not yet persisted,
  /// a data capture waits for the sheet to be closed normally.
  late final Object _unsavedForm = UnsavedEditors.instance.register(
      'history_sets', () => _openId != null || _timers.isNotEmpty);

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
    _sets = widget.block.sets
        .map(
          (s) => _EditableSet(
            id: s.id,
            weightKg: s.weightKg,
            reps: s.reps,
            rir: s.rir,
            isWarmup: s.isWarmup,
          ),
        )
        .toList();
  }

  @override
  void dispose() {
    UnsavedEditors.instance.unregister(_unsavedForm);
    // Fire-and-forget: the sheet is going away, nothing left to await into.
    // A write refused now stays owed (see [_owed]) and is retried when the
    // capture releases the source.
    for (final id in _unpersisted) {
      _timers.remove(id)?.cancel();
      final idx = _sets.indexWhere((e) => e.id == id);
      if (idx != -1) _persist(_sets[idx]);
    }
    super.dispose();
  }

  /// Writes [s]'s current values. The `updateSet` call is issued
  /// synchronously. The edit is owed until the write lands; a refused or
  /// failed write is shown (while the sheet is open) and stays owed.
  /// Completes with whether it landed; never throws.
  Future<bool> _persist(_EditableSet s) {
    final repo = widget.sessionRepo;
    final id = s.id;
    final key = 'history_set:$id';
    final weightKg = s.weightKg.toStringAsFixed(2);
    final reps = s.reps;
    final rir = s.rir;
    Future<void> write() =>
        repo.updateSet(id, weightKg: weightKg, reps: reps, rir: rir);
    UnsavedEditors.instance.owe(key, 'history_sets', write);
    return write().then((_) {
      UnsavedEditors.instance.paid(key, write);
      if (!UnsavedEditors.instance.isOwed(key)) _owed.remove(id);
      return true;
    }, onError: (Object e) {
      _owed.add(id);
      _showFailure(e);
      return false;
    });
  }

  bool _showingFailure = false;

  /// One failure dialog at a time: a gliding ruler can trigger several
  /// refused writes in a row.
  void _showFailure(Object error) {
    if (!mounted || _showingFailure) return;
    _showingFailure = true;
    unawaited(showWriteFailed(context, error)
        .whenComplete(() => _showingFailure = false));
  }

  /// Mutates [s] in place, rebuilds so the editor reflects the new value
  /// (its typed-entry unchanged-value guard compares against the value it
  /// was built with), and (re)starts that set's 400 ms persist debounce.
  void _edit(_EditableSet s, {double? weight, int? reps, int? rir}) {
    setState(() {
      if (weight != null) s.weightKg = weight;
      if (reps != null) s.reps = reps;
      if (rir != null) s.rir = rir;
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
    if (timer == null && !_owed.contains(id)) return true;
    final idx = _sets.indexWhere((e) => e.id == id);
    if (idx == -1) return true;
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
    if (timer == null && !_owed.contains(id)) return;
    final idx = _sets.indexWhere((e) => e.id == id);
    if (idx == -1) return;
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
    commitPendingInput();
    final previous = _openId;
    if (previous != null) _flushSync(previous);
    setState(() => _openId = previous == id ? null : id);
  }

  Future<void> _deleteSet(_EditableSet s) async {
    commitPendingInput();
    if (!await _flush(s.id)) return; // its failure is already shown
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.historyDeleteSetTitle,
      message: l.historyDeleteSetMessage,
      confirmLabel: l.commonDelete,
      destructive: true,
    );
    if (confirmed != true) return;
    try {
      await widget.sessionRepo.deleteSet(s.id);
    } catch (e) {
      // E.g. refused while a data capture holds the source: nothing deleted.
      if (mounted) await showWriteFailed(context, e);
      return;
    }
    if (!mounted) return;
    setState(() {
      _sets.removeWhere((e) => e.id == s.id);
      if (_openId == s.id) _openId = null;
    });
  }

  /// Appends a new working set, seeded from the last working set (or the
  /// heaviest existing set) so the user usually only needs minor tweaks, then
  /// opens its card.
  Future<void> _addSet() async {
    // Flush BEFORE `_sets`/`working` are read below. The seed itself only
    // needs the LOCAL `_sets` values (already current — `_edit` mutates in
    // place synchronously), so this doesn't need to await the write landing;
    // it only needs to be issued before whatever runs next.
    commitPendingInput();
    final open = _openId;
    if (open != null) _flushSync(open);

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
      newId = await widget.sessionRepo.addSet(
        widget.sessionId,
        widget.exercise.id,
        weightKg: w.toStringAsFixed(2),
        reps: r,
        rir: rir,
        isWarmup: false,
      );
    } catch (e) {
      // E.g. refused while a data capture holds the source: nothing added.
      if (mounted) await showWriteFailed(context, e);
      return;
    }
    if (!mounted) return;
    setState(() {
      _sets.add(
        _EditableSet(
          id: newId,
          weightKg: w,
          reps: r,
          rir: rir,
          isWarmup: false,
        ),
      );
      _openId = newId;
    });
  }

  /// The 1-based working-set index for the set at [i], or -1 for warm-ups.
  int _workIndexOf(int i) {
    if (_sets[i].isWarmup) return -1;
    var n = 0;
    for (var j = 0; j <= i; j++) {
      if (!_sets[j].isWarmup) n++;
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
        if (!didPop) return;
        commitPendingInput();
        _flushAllSync();
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          decoration: BoxDecoration(
            color: tokens.bg,
            border: Border(top: BorderSide(color: tokens.line)),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
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
              const SizedBox(height: 14),

              // Title
              Text(
                widget.exercise.name,
                style: WorkoutType.display(
                  size: 18,
                  weight: FontWeight.w700,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                l.historyEditSets,
                style: WorkoutType.mono(size: 11, color: tokens.faint),
              ),
              const SizedBox(height: 14),

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
                                Icon(
                                  WIcons.plus,
                                  size: 14,
                                  color: tokens.accentText,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  l.sessionAddSet,
                                  style: WorkoutType.mono(
                                    size: 11,
                                    weight: FontWeight.w600,
                                    color: tokens.accentText,
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
    required this.weightKg,
    required this.reps,
    required this.rir,
    required this.isWarmup,
  });

  final String id;
  double weightKg;
  int reps;
  int? rir;
  final bool isWarmup;
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
    required this.onTap,
    required this.onWeight,
    required this.onReps,
    required this.onRir,
    required this.onDelete,
  });

  final _EditableSet set;
  final int workIndex;
  final UnitService units;
  final bool open;
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
              ? _SetEditingCard(
                  set: set,
                  units: units,
                  onWeight: onWeight,
                  onReps: onReps,
                  onRir: onRir,
                  onDelete: onDelete,
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
                child: Text(
                  set.isWarmup ? l.sessionWarmupShort : '$workIndex',
                  textAlign: TextAlign.center,
                  style: WorkoutType.mono(
                    size: 13,
                    weight: FontWeight.w700,
                    color: tokens.dim,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: units.fmtWt(set.weightKg),
                              style: WorkoutType.mono(
                                size: 15,
                                weight: FontWeight.w700,
                                color: tokens.text,
                              ),
                            ),
                            TextSpan(
                              text: units.uLabel,
                              style: WorkoutType.mono(
                                size: 11,
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
                              text: '${set.reps}',
                              style: WorkoutType.mono(
                                size: 15,
                                weight: FontWeight.w700,
                                color: tokens.text,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!set.isWarmup && set.rir != null) ...[
                      const SizedBox(width: 10),
                      Text(
                        l.sessionRir(set.rir!),
                        style: WorkoutType.mono(
                          size: 10.5,
                          color: tokens.faint,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(WIcons.chevron, size: 18, color: tokens.faint),
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

    TextStyle caption() => WorkoutType.mono(
      size: 10,
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
        borderRadius: BorderRadius.circular(AppRadius.radius * 0.8),
        border: Border.all(color: tokens.accentText, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SetValuesEditor(
            weightKg: set.weightKg,
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
                        weight: FontWeight.w600,
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
