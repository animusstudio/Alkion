import 'package:provider/provider.dart';
import 'package:flutter/material.dart';

import '../data/day_template_repository.dart';
import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../util/dates.dart';
import '../widgets/plan_form.dart';
import '../widgets/fit_label.dart';
import '../widgets/prescription_controls.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';

/// The Split sub-tab: a list of training days in rotation.
///
/// [onOpenEditor] is called with the day id to edit (null = new day).
class SplitTab extends StatefulWidget {
  const SplitTab({super.key, required this.onOpenEditor});

  /// Called with the day id to edit (null = new day).
  final void Function(String? id) onOpenEditor;

  @override
  State<SplitTab> createState() => _SplitTabState();
}

class _SplitTabState extends State<SplitTab> {
  late final DayTemplateRepository _repo = DayTemplateRepository.local(
    context.read<LocalDatabase>(),
  );
  late final Stream<List<DayTemplate>> _daysStream = _repo.watchDays();

  bool _showInactive = false;
  final Map<String, PreparedDomainAction> _pending = {};
  final Set<String> _busy = {};

  Future<void> _setActive(DayTemplate day) async {
    if (_busy.contains(day.id) || day.active == null) return;
    final l = AppLocalizations.of(context);
    try {
      _pending[day.id] ??= _repo.prepareSetActive(
        day.id,
        day.localRevision ??
            (throw const StoreException('observed_revision_required')),
        !day.isActive,
      );
      final enabling = _pending[day.id]!.input['is_active'] == 1;
      setState(() => _busy.add(day.id));
      await context.read<DomainRecovery?>()?.recover();
      await _repo.commitPrepared(_pending[day.id]!);
      _pending.remove(day.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabling
                  ? l.trainingDayEnabled(day.name)
                  : l.trainingDayDisabled(day.name),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) await showWriteFailed(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(day.id));
    }
  }

  Future<void> _actions(DayTemplate day) async {
    final l = AppLocalizations.of(context);
    final action = await showWActionSheet<String>(
      context,
      title: day.name,
      actions: [
        WSheetAction(label: l.planEditDay, value: 'edit', icon: WIcons.edit),
        WSheetAction(
          label: _pending.containsKey(day.id)
              ? l.trainingRetry
              : day.active == null
              ? l.trainingDayUnavailable
              : day.isActive
              ? l.trainingDisable
              : l.trainingEnable,
          value: 'active',
          icon: WIcons.refresh,
          enabled: day.active != null && !_busy.contains(day.id),
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'edit') widget.onOpenEditor(day.id);
    if (action == 'active') await _setActive(day);
  }

  Widget _card(DayTemplate day) => SplitDayCard(
    weekday: day.scheduledWeekday,
    name: day.name,
    focus: day.focus,
    exerciseCount: day.slots.length,
    onTap: () => widget.onOpenEditor(day.id),
    onActions: () => _actions(day),
    status: _busy.contains(day.id)
        ? AppLocalizations.of(context).trainingSaving
        : _pending.containsKey(day.id)
        ? AppLocalizations.of(context).trainingRetryStatus
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return StreamBuilder<List<DayTemplate>>(
      stream: _daysStream,
      builder: (context, snap) {
        final days = snap.data ?? [];

        return ListView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottomNavInset(context)),
          children: [
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
                            _pending.containsKey(day.id)
                                ? AppLocalizations.of(context).trainingRetry
                                : AppLocalizations.of(context).trainingEnable,
                            onTap: _busy.contains(day.id)
                                ? null
                                : () => _setActive(day),
                            icon: WIcons.refresh,
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
            _NewDayButton(
              tokens: tokens,
              onTap: () => widget.onOpenEditor(null),
            ),
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

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tokens.bg,
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
                icon: const Icon(WIcons.more),
                tooltip: l.trainingDayActions(name),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              )
            else
              Icon(WIcons.chevron, size: 16, color: tokens.faint),
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
    );
  }
}
