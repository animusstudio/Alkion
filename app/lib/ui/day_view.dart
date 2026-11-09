import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../catalog/catalog.dart';
import '../catalog_ui/catalog_runtime_state.dart';
import '../catalog_ui/catalog_scope.dart';
import '../data/body_workload.dart';
import '../data/day_template_repository.dart';
import '../data/models.dart';
import '../data/planned_workload.dart';
import '../l10n/app_localizations.dart';
import '../session/session_manager.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../widgets/fit_label.dart';
import '../widgets/glyph_loading.dart';
import '../widgets/plan_form.dart';
import '../widgets/section_label.dart';
import '../widgets/split_card.dart';
import 'body_figure.dart';
import 'slot_summary.dart';
import 'workload_top_muscles.dart';

/// Read-only overview of one saved training day: header, counts, Start and
/// Edit, the planned volume (top muscles beside one body figure) and one
/// compact row per exercise. Nothing here writes domain rows.
class DayView extends StatefulWidget {
  const DayView({
    super.key,
    required this.id,
    required this.onEdit,
    required this.onClose,
    this.onStart,
  });

  /// The day template id.
  final String id;

  /// Opens the editor for this day.
  final VoidCallback onEdit;

  /// Leaves the view (Back), or reacts to the day no longer existing.
  final VoidCallback onClose;

  /// Starts (or resumes) a workout from this day; null hides Start.
  final ValueChanged<DayTemplate>? onStart;

  @override
  State<DayView> createState() => _DayViewState();
}

class _DayViewState extends State<DayView> {
  late final LocalDatabase _db;
  StreamSubscription<List<DayTemplate>>? _daysSub;

  /// The day as last saved, from the days watch (so a Save in the editor
  /// shows here). Null until the first emission.
  DayTemplate? _day;

  /// The days read failed before the day was ever known.
  bool _daysFailed = false;

  /// [DayView.onClose] has been called; nothing else happens afterwards.
  bool _closed = false;

  PlanWorkloadInputs? _inputs;
  bool _inputsFailed = false;
  bool _loading = false;
  int _epoch = 0;

  CatalogBundle? _bundle;
  bool _bundleKnown = false;

  /// A token change while reading re-runs the read at most this often before
  /// the view gives up and shows the unavailable line.
  static const _maxRetries = 3;

  @override
  void initState() {
    super.initState();
    _db = context.read<LocalDatabase>();
    _daysSub = DayTemplateRepository.local(
      _db,
    ).watchDays().listen(_onDays, onError: _onDaysError);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = CatalogScope.maybeOf(context)?.bundle;
    if (_bundleKnown && identical(bundle, _bundle)) return;
    _bundleKnown = true;
    _bundle = bundle;
    if (_day != null) unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    _daysSub?.cancel();
    super.dispose();
  }

  void _onDays(List<DayTemplate> days) {
    if (!mounted || _closed) return;
    DayTemplate? day;
    for (final d in days) {
      if (d.id == widget.id) day = d;
    }
    if (day == null) {
      // Deleted (or never there): the route closes; Delete lands here.
      _closed = true;
      _epoch++;
      _daysSub?.cancel();
      widget.onClose();
      return;
    }
    setState(() {
      _day = day;
      _daysFailed = false;
    });
    unawaited(_load());
  }

  void _onDaysError(Object error, StackTrace stack) {
    // Keep the last good day; only a view that never had one reads as failed.
    if (!mounted || _closed || _day != null) return;
    setState(() => _daysFailed = true);
  }

  /// Reads the exercises and muscle resolutions for the current day. A read
  /// that fails because the store token changed is re-run; any other failure
  /// is unavailable. A newer read (or dispose) drops this one's result.
  Future<void> _load() async {
    final day = _day;
    if (day == null) return;
    final epoch = ++_epoch;
    _loading = true;
    for (var attempt = 0; ; attempt++) {
      final token = _db.token;
      try {
        final inputs = await PlanWorkloadInputs.load(_db, [day], _bundle);
        if (!mounted || epoch != _epoch) return;
        setState(() {
          _inputs = inputs;
          _inputsFailed = false;
          _loading = false;
        });
        return;
      } catch (_) {
        if (!mounted || epoch != _epoch) return;
        final now = _db.token;
        final tokenChanged =
            now.profileId != token.profileId ||
            now.generation != token.generation;
        if (tokenChanged && attempt + 1 < _maxRetries) continue;
        setState(() {
          _inputsFailed = true;
          _loading = false;
        });
        return;
      }
    }
  }

  /// Whether [inputs] already hold every exercise and selection [day] uses,
  /// so a reload after a Save can keep showing counts instead of flashing.
  static bool _covers(PlanWorkloadInputs inputs, DayTemplate day) =>
      day.slots.every(
        (slot) =>
            inputs.exercisesById.containsKey(slot.exerciseId) &&
            (slot.catalog == null ||
                inputs.resolutions.containsKey(
                  slot.catalog!.muscleResolutionKey,
                )),
      );

  /// The inputs that describe [day] now: null while they load.
  PlanWorkloadInputs? _inputsFor(DayTemplate day) {
    final inputs = _inputs;
    if (inputs == null) return null;
    if (_loading && !_covers(inputs, day)) return null;
    return inputs;
  }

  WorkoutWorkload _workload(DayTemplate day) {
    const mode = WorkoutWorkloadMode.planned;
    if (_inputsFailed) return WorkoutWorkload.unavailable(mode);
    final inputs = _inputsFor(day);
    if (inputs == null) return WorkoutWorkload.loading(mode);
    return inputs.dayWorkload(day);
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    final Widget child;
    if (day != null) {
      child = KeyedSubtree(
        key: const ValueKey('day-view-content'),
        child: _content(context, day),
      );
    } else if (_daysFailed) {
      child = Padding(
        key: const ValueKey('day-view-failed'),
        padding: const EdgeInsets.all(16),
        child: Text(
          AppLocalizations.of(context).bodyReadUnavailable,
          key: const Key('day-view-unavailable'),
          style: WorkoutType.body(size: 14, color: context.tokens.dim),
        ),
      );
    } else {
      child = Padding(
        key: const ValueKey('day-view-loading'),
        padding: const EdgeInsets.all(16),
        child: GlyphSkeleton.lines(
          key: const Key('day-view-skeleton'),
          widths: const [.4, .8, .6, 1, 1, .9],
          lineHeight: 18,
          gap: 16,
        ),
      );
    }
    return AnimatedSwitcher(
      duration: Motion.of(context, Motion.base),
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.curve,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: child,
    );
  }

  Widget _content(BuildContext context, DayTemplate day) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final workload = _workload(day);
    final inputs = _inputsFailed ? null : _inputsFor(day);
    return ListView(
      key: const Key('day-view-list'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomNavInset(context)),
      children: [
        _Header(day: day),
        const SizedBox(height: 12),
        _StatChips(day: day, workload: workload, inputs: inputs),
        const SizedBox(height: 20),
        _Actions(day: day, onStart: widget.onStart, onEdit: widget.onEdit),
        const SizedBox(height: 28),
        SectionLabel(label: l.bodyPlanned),
        const SizedBox(height: 12),
        _Overview(workload: workload),
        const SizedBox(height: 28),
        SectionLabel(label: l.splitExercises),
        const SizedBox(height: 4),
        if (inputs != null)
          for (final slot in day.slots)
            _ExerciseRow(
              key: ValueKey('day-view-row-${slot.id}'),
              slot: slot,
              exercise: inputs.exercisesById[slot.exerciseId],
            )
        else if (_inputsFailed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              l.bodyReadUnavailable,
              style: WorkoutType.body(size: 14, color: t.dim),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: GlyphSkeleton.lines(
              key: const Key('day-view-rows-skeleton'),
              widths: [for (final _ in day.slots) 1],
              lineHeight: 56,
              gap: 12,
              active: false,
            ),
          ),
      ],
    );
  }
}

// ── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.day});
  final DayTemplate day;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final focus = day.focus?.trim() ?? '';
    final weekday = day.scheduledWeekday;
    final weekdayLabel = weekday == null
        ? null
        : weekday >= 0 && weekday <= 6
        ? weekdayShort(
            weekday,
            Localizations.localeOf(context).toLanguageTag(),
          ).toUpperCase()
        : l.trainingWeekdayUnavailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: FitLabel(
                l.dayViewTitle.toUpperCase(),
                maxLines: 2,
                style: WorkoutType.body(
                  size: 12,
                  weight: FontWeight.w500,
                  color: t.accentText,
                  letterSpacing: 0.06 * 12,
                ),
              ),
            ),
            if (weekdayLabel != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: _Chip(
                  key: const Key('day-view-weekday'),
                  label: weekdayLabel,
                  accent: true,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: FitLabel(
            day.name,
            maxLines: 3,
            style: WorkoutType.display(size: 28, color: t.text),
          ),
        ),
        if (focus.isNotEmpty) ...[
          const SizedBox(height: 6),
          FitLabel(
            focus,
            maxLines: 3,
            style: WorkoutType.body(size: 16, color: t.dim),
          ),
        ],
      ],
    );
  }
}

// ── Stat chips ──────────────────────────────────────────────────────────────

class _StatChips extends StatelessWidget {
  const _StatChips({
    required this.day,
    required this.workload,
    required this.inputs,
  });

  final DayTemplate day;
  final WorkoutWorkload workload;
  final PlanWorkloadInputs? inputs;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Chip(
          key: const Key('day-view-exercise-count'),
          label: l.todayExerciseCount(day.slots.length),
        ),
        ?_workingSets(context, l),
      ],
    );
  }

  /// The total working sets Start would build: only once the planned
  /// workload is ready, so a load or a failed read never reads as zero.
  Widget? _workingSets(BuildContext context, AppLocalizations l) {
    switch (workload.availability) {
      case WorkloadAvailability.loading:
        return GlyphSkeleton.box(
          key: const Key('day-view-working-sets-loading'),
          width: 112,
          height: MediaQuery.textScalerOf(context).scale(16) + 12,
          active: false,
        );
      case WorkloadAvailability.unavailable:
        return null;
      case WorkloadAvailability.ready:
        break;
    }
    final slots = resolvePlannedDaySlots(day, inputs?.exercisesById ?? {});
    if (slots == null) return null;
    final total = slots.fold<int>(0, (sum, slot) => sum + slot.workSets);
    return _Chip(
      key: const Key('day-view-working-sets'),
      label: l.dayViewWorkingSets(total),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent ? t.accent : t.surface2,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: FitLabel(
          label,
          maxLines: 2,
          style: WorkoutType.mono(
            size: 12,
            color: accent ? t.accentInk : t.text,
          ),
        ),
      ),
    );
  }
}

// ── Start and Edit ──────────────────────────────────────────────────────────

class _Actions extends StatelessWidget {
  const _Actions({
    required this.day,
    required this.onStart,
    required this.onEdit,
  });

  final DayTemplate day;
  final ValueChanged<DayTemplate>? onStart;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final resuming = Provider.of<SessionManager?>(context)?.hasActive ?? false;
    final edit = PrimaryBtn(
      key: const Key('day-view-edit'),
      l.dayViewEdit,
      enabled: true,
      secondary: true,
      glitch: true,
      onTap: onEdit,
    );
    final start = onStart;
    if (start == null || !day.isActive) {
      final status = day.active == null
          ? l.trainingDayUnavailable
          : day.active == false
          ? l.dayViewInactive
          : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null) ...[
            Text(
              status,
              key: const Key('day-view-status'),
              style: WorkoutType.body(size: 14, color: t.dim),
            ),
            const SizedBox(height: 12),
          ],
          edit,
        ],
      );
    }
    final startButton = PrimaryBtn(
      key: const Key('day-view-start'),
      resuming ? l.todayResumeWorkout : l.splitStartWorkout,
      enabled: true,
      glitch: true,
      onTap: () => start(day),
    );
    // Side by side while both labels fit; stacked at large text.
    if (MediaQuery.textScalerOf(context).scale(16) > 20) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [startButton, const SizedBox(height: 8), edit],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: startButton),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: edit),
      ],
    );
  }
}

// ── Overview ────────────────────────────────────────────────────────────────

/// The top muscles beside exactly one body figure, stacked like the Today
/// card when narrow or at large text.
class _Overview extends StatelessWidget {
  const _Overview({required this.workload});
  final WorkoutWorkload workload;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = splitOverviewStacked(context, box.maxWidth);
        final width = splitFigureWidth(context, box.maxWidth);
        final muscles = WorkloadTopMuscles(workload: workload);
        final figure = BodyFigure(width: width, workload: workload);
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              muscles,
              const SizedBox(height: 12),
              Center(child: figure),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: muscles),
            const SizedBox(width: 12),
            figure,
          ],
        );
      },
    );
  }
}

// ── Exercise rows ───────────────────────────────────────────────────────────

/// One exercise: art (or the neutral tile), name and summary chips. Not
/// interactive; one accessibility node reads the name and the summary.
class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({super.key, required this.slot, required this.exercise});

  final Slot slot;

  /// Null when the slot's exercise is missing from the store.
  final Exercise? exercise;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), t = context.tokens;
    final units = Provider.of<UnitService?>(context) ?? UnitService();
    final exercise = this.exercise;
    final summary = exercise == null ? null : slotSummary(slot, exercise);
    final name = exercise == null
        ? l.dayViewExerciseUnavailable
        : _displayName(context, exercise);
    final labels = summary?.labels(l, units) ?? const <String>[];
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: [name, ...labels].join(', '),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SlotThumbnail(exerciseId: slot.exerciseId, selection: slot.catalog),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FitLabel(
                    name,
                    maxLines: 3,
                    style: WorkoutType.body(
                      size: 15.5,
                      weight: FontWeight.w500,
                      color: exercise == null ? t.dim : t.text,
                    ),
                  ),
                  if (summary != null) ...[
                    const SizedBox(height: 6),
                    SlotSummaryChips(summary: summary),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The catalog's identifying label for the slot's choice, as the editor
  /// shows it; else the exercise's own name.
  String _displayName(BuildContext context, Exercise exercise) {
    final CatalogRuntimeState? scope = CatalogScope.maybeOf(context);
    if (scope == null) return exercise.name;
    final selection = slot.catalog;
    final choice = selection != null
        ? scope.choiceForSelection(selection)
        : scope.exercises[slot.exerciseId];
    if (choice == null ||
        (choice.customName == null && choice.variantId == null)) {
      return exercise.name;
    }
    return scope.identifyingLabel(
      choice,
      Localizations.localeOf(context).languageCode,
    );
  }
}
