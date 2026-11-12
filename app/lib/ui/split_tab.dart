import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../catalog_ui/catalog_scope.dart';
import '../data/body_workload.dart';
import '../data/day_template_repository.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/planned_workload.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/alkion_icon.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/dates.dart';
import '../widgets/plan_form.dart';
import '../widgets/fit_label.dart';
import '../widgets/prescription_controls.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';
import '../widgets/w_toast.dart';
import 'split_volume_card.dart';

/// The Plan route owns immutable status intents independently of the list's
/// lifetime, so opening an editor or another sub-tab cannot discard a retry.
class DayStatusActions extends ChangeNotifier {
  DayStatusActions(this.repository);
  final DayTemplateRepository repository;
  final Map<String, PreparedDomainAction> _pending = {};
  final Set<String> _busy = {};
  bool _disposed = false;

  bool hasPending(String id) => _pending.containsKey(id);
  bool isBusy(String id) => _busy.contains(id);

  Future<bool?> perform(DayTemplate day, {DomainRecovery? recovery}) async {
    if (_disposed || isBusy(day.id) || day.active == null) return null;
    final intent = _pending[day.id] ??= repository.prepareSetActive(
      day.id,
      day.localRevision ??
          (throw const StoreException('observed_revision_required')),
      !day.isActive,
    );
    final enabling = intent.input['is_active'] == 1;
    _busy.add(day.id);
    _notify();
    try {
      await recovery?.recover();
      try {
        await repository.commitPrepared(intent);
      } on StoreException catch (error) {
        // apply checks a matching committed operation before its revision base.
        // This rejection therefore proves this exact intent was never applied.
        // Retire it without rebasing; only a new explicit action may replace it.
        if (error.category == 'revision_conflict' &&
            identical(_pending[day.id], intent)) {
          _pending.remove(day.id);
        }
        rethrow;
      }
      _pending.remove(day.id);
      return enabling;
    } finally {
      _busy.remove(day.id);
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The Split sub-tab: a list of training days in rotation.
///
/// A card's tap calls [onOpenDay]; the card menu's Edit and "New training
/// day" call [onEditDay].
class SplitTab extends StatefulWidget {
  const SplitTab({
    super.key,
    required this.onOpenDay,
    required this.onEditDay,
    this.statusActions,
  });

  /// Called with the id of the day to view.
  final ValueChanged<String> onOpenDay;

  /// Called with the day id to edit (null = new day).
  final void Function(String? id) onEditDay;

  final DayStatusActions? statusActions;

  @override
  State<SplitTab> createState() => _SplitTabState();
}

class _SplitTabState extends State<SplitTab> {
  late final LocalDatabase _db = context.read<LocalDatabase>();
  late final DayTemplateRepository _repo = DayTemplateRepository.local(_db);
  late final Stream<List<DayTemplate>> _daysStream = _repo.watchDays();
  StreamSubscription<List<DayTemplate>>? _daysSub;

  /// The days as last emitted; empty until the first emission or after a
  /// failed read, as the list always showed them.
  List<DayTemplate> _days = const [];

  bool _showInactive = false;
  late final DayStatusActions _statusActions;

  // ── Split volume inputs ──
  // Read once per distinct day-and-slot revision signature of the active
  // days, never from build. A newer read (or dispose) bumps [_epoch] and so
  // drops an older read's result.
  PlanWorkloadInputs? _inputs;
  bool _inputsFailed = false;
  bool _loading = false;
  int _epoch = 0;
  List<Object?>? _signature;
  CatalogBundle? _bundle;
  bool _bundleKnown = false;

  /// The last computed workload, reused while neither the days nor the
  /// inputs change.
  ({List<DayTemplate> days, PlanWorkloadInputs inputs, WorkoutWorkload value})?
  _computed;

  /// A token change while reading re-runs the read at most this often before
  /// the card gives up and shows the unavailable line.
  static const _maxRetries = 3;

  @override
  void initState() {
    super.initState();
    _statusActions = widget.statusActions ?? DayStatusActions(_repo);
    _daysSub = _daysStream.listen(_onDays, onError: _onDaysError);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = CatalogScope.maybeOf(context)?.bundle;
    if (_bundleKnown && identical(bundle, _bundle)) return;
    final first = !_bundleKnown;
    _bundleKnown = true;
    _bundle = bundle;
    // A new catalog bundle can change catalog-backed muscle profiles.
    if (!first) {
      _signature = null;
      _ensureInputs();
    }
  }

  @override
  void dispose() {
    _epoch++;
    _daysSub?.cancel();
    if (widget.statusActions == null) _statusActions.dispose();
    super.dispose();
  }

  void _onDays(List<DayTemplate> days) {
    if (!mounted) return;
    setState(() => _days = days);
    _ensureInputs();
  }

  void _onDaysError(Object error, StackTrace stack) {
    if (!mounted) return;
    setState(() => _days = const []);
  }

  static List<DayTemplate> _activeDays(List<DayTemplate> days) => [
    for (final day in days)
      if (day.isActive) day,
  ];

  /// Whether the overview shows: some active day holds an exercise.
  static bool _hasVolume(List<DayTemplate> days) =>
      days.any((day) => day.isActive && day.slots.isNotEmpty);

  /// What the inputs depend on: each active day's id and revision and each
  /// of its slots' id, revision, exercise and catalog selection.
  static List<Object?> _signatureOf(List<DayTemplate> active) => [
    for (final day in active) ...[
      day.id,
      day.localRevision,
      day.slots.length,
      for (final slot in day.slots) ...[
        slot.id,
        slot.localRevision,
        slot.exerciseId,
        slot.catalog?.muscleResolutionKey,
      ],
    ],
  ];

  /// Starts a read when the active days' signature changed since the last.
  void _ensureInputs() {
    if (!_hasVolume(_days)) return;
    final active = _activeDays(_days);
    final signature = _signatureOf(active);
    if (_signature != null && listEquals(signature, _signature)) return;
    _signature = signature;
    unawaited(_load(active));
  }

  /// Reads the exercises and muscle resolutions for [active]. A read that
  /// fails because the store token changed is re-run; any other failure is
  /// unavailable. A newer read (or dispose) drops this one's result.
  Future<void> _load(List<DayTemplate> active) async {
    final epoch = ++_epoch;
    final bundle = _bundle;
    _loading = true;
    for (var attempt = 0; ; attempt++) {
      final token = _db.token;
      try {
        final inputs = await PlanWorkloadInputs.load(_db, active, bundle);
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

  /// Whether [inputs] already hold every exercise and selection the active
  /// [days] use, so a re-read keeps showing counts instead of flashing.
  static bool _covers(PlanWorkloadInputs inputs, List<DayTemplate> days) =>
      days.every(
        (day) =>
            !day.isActive ||
            day.slots.every(
              (slot) =>
                  inputs.exercisesById.containsKey(slot.exerciseId) &&
                  (slot.catalog == null ||
                      inputs.resolutions.containsKey(
                        slot.catalog!.muscleResolutionKey,
                      )),
            ),
      );

  WorkoutWorkload _workload() {
    const mode = WorkoutWorkloadMode.planned;
    if (_inputsFailed) return WorkoutWorkload.unavailable(mode);
    final inputs = _inputs;
    if (inputs == null || (_loading && !_covers(inputs, _days))) {
      return WorkoutWorkload.loading(mode);
    }
    final cached = _computed;
    if (cached != null &&
        identical(cached.days, _days) &&
        identical(cached.inputs, inputs)) {
      return cached.value;
    }
    final value = inputs.splitWorkload(_days);
    _computed = (days: _days, inputs: inputs, value: value);
    return value;
  }

  Future<void> _setActive(DayTemplate day) async {
    if (_statusActions.isBusy(day.id) || day.active == null) return;
    final l = AppLocalizations.of(context);
    try {
      final enabling = await _statusActions.perform(
        day,
        recovery: context.read<DomainRecovery?>(),
      );
      if (enabling == null) return;
      if (mounted) {
        showWToast(
          context,
          enabling
              ? l.trainingDayEnabled(day.name)
              : l.trainingDayDisabled(day.name),
        );
      }
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    }
  }

  Future<void> _actions(DayTemplate day) async {
    final l = AppLocalizations.of(context);
    final action = await showWActionSheet<String>(
      context,
      title: day.name,
      actions: [
        WSheetAction(
          label: l.planEditDay,
          value: 'edit',
          icon: AlkionGlyph.edit,
        ),
        WSheetAction(
          label: _statusActions.hasPending(day.id)
              ? l.trainingRetry
              : day.active == null
              ? l.trainingDayUnavailable
              : day.isActive
              ? l.trainingDisable
              : l.trainingEnable,
          value: 'active',
          icon: AlkionGlyph.refresh,
          enabled: day.active != null && !_statusActions.isBusy(day.id),
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'edit') widget.onEditDay(day.id);
    if (action == 'active') await _setActive(day);
  }

  Widget _card(DayTemplate day) => SplitDayCard(
    weekday: day.scheduledWeekday,
    name: day.name,
    focus: day.focus,
    exerciseCount: day.slots.length,
    onTap: () => widget.onOpenDay(day.id),
    onActions: () => _actions(day),
    status: _statusActions.isBusy(day.id)
        ? AppLocalizations.of(context).trainingSaving
        : _statusActions.hasPending(day.id)
        ? AppLocalizations.of(context).trainingRetryStatus
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return AnimatedBuilder(
      animation: _statusActions,
      builder: (context, _) {
        final days = _days;

        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottomNavInset(context)),
          children: [
            if (_hasVolume(days)) ...[
              SplitVolumeCard(workload: _workload(), basis: splitBasis(days)),
              const SizedBox(height: 16),
            ],
            ...days.where((d) => d.isActive).map(_card),
            if (days.any((d) => d.active == false)) ...[
              TrainingDisclosure(
                label: AppLocalizations.of(
                  context,
                ).trainingInactive(days.where((d) => d.active == false).length),
                expanded: _showInactive || !days.any((d) => d.isActive),
                onTap: () => setState(() => _showInactive = !_showInactive),
              ),
              if (_showInactive || !days.any((d) => d.isActive))
                ...days
                    .where((d) => d.active == false)
                    .map(
                      (day) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _card(day),
                          TrainingAction(
                            _statusActions.hasPending(day.id)
                                ? AppLocalizations.of(context).trainingRetry
                                : AppLocalizations.of(context).trainingEnable,
                            onTap: _statusActions.isBusy(day.id)
                                ? null
                                : () => _setActive(day),
                            icon: AlkionGlyph.refresh,
                          ),
                        ],
                      ),
                    ),
            ],
            if (days.any((d) => d.active == null)) ...[
              Text(
                AppLocalizations.of(context).trainingDayUnavailable,
                style: WorkoutType.body(color: tokens.dim),
              ),
              ...days.where((d) => d.active == null).map(_card),
            ],

            if (days.isNotEmpty) const SizedBox(height: 16),

            // "New training day" dashed button
            _NewDayButton(tokens: tokens, onTap: () => widget.onEditDay(null)),
          ],
        );
      },
    );
  }
}

// ── Day card ──────────────────────────────────────────────────────────────────

/// A training-day row: weekday block, name, and "focus · N exercises" meta.
///
/// Public so it is directly widget-testable (see `test/ui/split_tab_test.dart`)
/// without mounting the store-backed [SplitTab].
class SplitDayCard extends StatelessWidget {
  const SplitDayCard({
    super.key,
    required this.weekday,
    required this.name,
    required this.focus,
    required this.exerciseCount,
    required this.onTap,
    this.onActions,
    this.status,
  });

  /// Monday-origin (0-6) scheduled weekday, or null if unscheduled.
  final int? weekday;
  final String name;
  final String? focus;
  final int exerciseCount;
  final VoidCallback onTap;
  final VoidCallback? onActions;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);

    // Guard nullable weekday — weekdayShort is non-nullable and indexes an
    // unguarded array.
    final weekBadge = (weekday != null && weekday! >= 0 && weekday! <= 6)
        ? weekdayShort(
            weekday!,
            Localizations.localeOf(context).toLanguageTag(),
          )
        : '–';

    final focusText = focus?.trim() ?? '';
    // The count only (the "{focus} · " prefix stripped), localized.
    final countText = l
        .splitDayMeta('', exerciseCount)
        .replaceFirst(RegExp(r'^\s*·\s*'), '');
    final metaStyle = WorkoutType.body(size: 12, color: tokens.faint);

    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
        overlayColor: tokens.focus.withValues(alpha: .16),
        backgroundColor: tokens.bg,
      ),
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.line)),
        ),
        child: Row(
          children: [
            // Weekday block — same width/divider style as History's date
            // block. Scales down rather than wrapping ("MIÉ" at 1.3x).
            SizedBox(
              width: 44,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    weekBadge.toUpperCase(),
                    maxLines: 1,
                    style: WorkoutType.display(
                      size: 20,
                      weight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                ),
              ),
            ),

            // Divider
            Container(
              width: 1,
              height: 44,
              color: tokens.line,
              margin: const EdgeInsets.symmetric(horizontal: 13),
            ),

            // Name + meta
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FitLabel(
                    name,
                    maxLines: 2,
                    style: WorkoutType.body(
                      size: 15.5,
                      weight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                  if (status != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(status!, style: metaStyle),
                    ),
                  const SizedBox(height: 2),
                  // A long focus ellipsizes; the count keeps its own slot,
                  // capped at the row so at large text it shrinks, then
                  // ellipsizes, rather than overflowing.
                  LayoutBuilder(
                    builder: (context, constraints) => Row(
                      children: [
                        if (focusText.isNotEmpty)
                          Flexible(
                            child: Text(
                              focusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: metaStyle,
                            ),
                          ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth,
                          ),
                          child: FitLabel(
                            focusText.isNotEmpty ? ' · $countText' : countText,
                            style: metaStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            if (onActions != null)
              IconButton(
                onPressed: onActions,
                icon: const AlkionIcon(AlkionGlyph.more),
                tooltip: l.trainingDayActions(name),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              )
            else
              AlkionIcon(
                AlkionGlyph.chevronRight,
                size: 16,
                color: tokens.faint,
              ),
          ],
        ),
      ),
    );
  }
}

// ── New training day button ───────────────────────────────────────────────────

class _NewDayButton extends StatelessWidget {
  const _NewDayButton({required this.tokens, required this.onTap});

  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PrimaryBtn(
      l.planNewDay,
      enabled: true,
      secondary: true,
      onTap: onTap,
      glitch: true,
    );
  }
}
