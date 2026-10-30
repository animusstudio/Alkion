import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../data/bodyweight_repository.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/session_writer.dart';
import '../data/stats_repository.dart';
import '../export/export_service.dart';
import '../files/document_access.dart';
import '../l10n/app_localizations.dart';
import '../settings/app_languages.dart';
import '../settings/bodyweight_goal.dart';
import '../settings/settings_service.dart';
import '../store/local_store.dart';
import '../session/session_manager.dart';
import '../widgets/pending_input.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../util/dates.dart';
import '../widgets/alkion_brand.dart';
import '../widgets/fit_label.dart';
import '../widgets/plan_form.dart';
import '../widgets/stepper.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';
import 'alkion_recovery/recovery_screen.dart';
import 'animus_connection_panel.dart';
import 'export_failure.dart';
import 'training_preferences_sheet.dart';

// ── Group + Row helpers ─────────────────────────────────────────────────────

class _Group extends StatelessWidget {
  const _Group({super.key, required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: FitLabel(
              label.toUpperCase(),
              maxLines: 2,
              style: WorkoutType.body(
                size: 12,
                weight: FontWeight.w500,
                color: tokens.dim,
              ),
            ),
          ),
          Container(
            // No clipBehavior: the rounded fill + border come from the
            // decoration, and the children (transparent rows, interior
            // dividers) never paint into the corners — so an anti-aliased clip
            // does no visual work here. It only forces an offscreen clip layer,
            // which Impeller's raster cache mis-composites as a stale gray box
            // at the wrong scroll position (the reported artifact).
            decoration: BoxDecoration(
              color: tokens.surface,
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(AppRadius.panel),
            ),
            child: Column(
              children: [
                for (int i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i < children.length - 1)
                    Divider(height: 1, thickness: 1, color: tokens.line),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    this.sub,
    this.right,
    this.control = false,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? sub;
  final Widget? right;

  final bool control;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    Widget row = Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackControl =
              control &&
              (constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tokens.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Icon(icon, size: 18, color: tokens.dim),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FitLabel(
                      title,
                      maxLines: 2,
                      style: WorkoutType.body(
                        size: 16,
                        weight: FontWeight.w500,
                        color: tokens.text,
                      ),
                    ),
                    if (sub != null) ...[
                      const SizedBox(height: 4),
                      FitLabel(
                        sub!,
                        maxLines: 3,
                        style: WorkoutType.body(size: 12, color: tokens.dim),
                      ),
                    ],
                    if (stackControl && right != null) ...[
                      const SizedBox(height: 12),
                      right!,
                    ],
                  ],
                ),
              ),
              if (right != null && !stackControl) ...[
                const SizedBox(width: 8),
                // Capped so a wide control (chips, a long sync status at large
                // text) wraps inside its slot instead of squeezing the title to
                // nothing or overflowing the row.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.6,
                  ),
                  child: right!,
                ),
              ],
            ],
          );
        },
      ),
    );

    if (onTap != null) {
      row = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          focusColor: tokens.focus.withValues(alpha: 0.2),
          child: row,
        ),
      );
    }

    return row;
  }
}

// ── Quick-stats card ──────────────────────────────────────────────────────────

/// Quick-stats row (sessions / PRs / bodyweight).
///
/// A StatefulWidget so its DB watch-streams are created ONCE in field
/// initializers and cached — never in `build()`. Creating a single-subscription
/// stream in `build()` re-subscribes it when the profile list recycles/keeps
/// this row alive on scroll, throwing "Stream has already been listened to";
/// in a release build that uncaught error renders as a gray ErrorWidget over
/// the top of the screen (the reported "infinite gray box").
class _QuickStats extends StatefulWidget {
  const _QuickStats();

  @override
  State<_QuickStats> createState() => _QuickStatsState();
}

class _QuickStatsState extends State<_QuickStats> {
  late final Stream<List<HistorySessionRow>> _sessions =
      SessionRepository.local(
        context.read<LocalDatabase>(),
      ).watchSessionStats();
  late final Stream<List<BodyweightEntry>> _bodyweight =
      BodyweightRepository.local(
        context.read<LocalDatabase>(),
      ).watchSeriesAsc();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unitService = context.watch<UnitService>();

    return StreamBuilder<List<HistorySessionRow>>(
      stream: _sessions,
      builder: (context, sessionSnap) {
        final sessions = sessionSnap.data ?? [];
        final sessionCount = sessions.length.toString();
        final prCount = sessions
            .fold<int>(0, (sum, s) => sum + s.prCount)
            .toString();

        return StreamBuilder<List<BodyweightEntry>>(
          stream: _bodyweight,
          builder: (context, bwSnap) {
            final bwEntries = bwSnap.data ?? [];
            final uncertainDay = bwEntries
                .where((e) => !e.dateAvailable)
                .firstOrNull;
            final current = bwEntries.isEmpty || uncertainDay != null
                ? null
                : bwEntries.last.weightKg;
            final bwText = current == null || !current.isFinite
                ? '–'
                : '${unitService.fmtBw(current)}${unitService.uLabel}';

            return LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth < 360 &&
                    MediaQuery.textScalerOf(context).scale(12) > 18;
                final cards = <Widget>[
                  _StatCard(
                    label: l.profileStatSessions,
                    value: sessionCount,
                    horizontal: stacked,
                  ),
                  _StatCard(
                    label: l.profileStatPrs,
                    value: prCount,
                    horizontal: stacked,
                  ),
                  UnitSwap(
                    unitKey: unitService.unit,
                    child: _StatCard(
                      label: l.profileStatBodyweight,
                      value: bwText,
                      horizontal: stacked,
                      detail: current == null && bwEntries.isNotEmpty
                          ? uncertainDay != null
                                ? l.alkionDateUnavailable(
                                    uncertainDay.date.isEmpty
                                        ? '—'
                                        : uncertainDay.date,
                                  )
                                : l.alkionUnavailableOn(bwEntries.last.date)
                          : null,
                    ),
                  ),
                ];
                return stacked
                    ? Column(
                        children: [
                          for (var i = 0; i < cards.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            cards[i],
                          ],
                        ],
                      )
                    : Row(
                        children: [
                          for (var i = 0; i < cards.length; i++) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(child: cards[i]),
                          ],
                        ],
                      );
              },
            );
          },
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    this.detail,
    this.horizontal = false,
  });

  final String label;
  final String value;
  final String? detail;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final number = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        value,
        maxLines: 1,
        style: WorkoutType.mono(
          size: 22,
          weight: FontWeight.w400,
          color: tokens.text,
        ),
      ),
    );
    final caption = Column(
      crossAxisAlignment: horizontal
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        FitLabel(
          label,
          maxLines: 2,
          style: WorkoutType.body(
            size: 12,
            weight: FontWeight.w500,
            color: tokens.dim,
          ),
        ),
        if (detail != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: FitLabel(
              detail!,
              maxLines: 3,
              style: WorkoutType.body(size: 12, color: tokens.dim),
            ),
          ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(AppRadius.panel),
      ),
      child: horizontal
          ? Row(
              children: [
                Expanded(child: caption),
                const SizedBox(width: 12),
                Flexible(child: number),
              ],
            )
          : Column(children: [number, const SizedBox(height: 8), caption]),
    );
  }
}

// ── Training line ─────────────────────────────────────────────────────────────

/// The Profile header's second line, or null to hide it.
///
/// "Since" is the month of the first logged workout, dropped when
/// [firstSessionDate] is null or doesn't parse; the split is the number of
/// the user's own training days, dropped when [dayCount] is null or 0.
String? profileTrainingLine(
  AppLocalizations l,
  String localeName, {
  String? firstSessionDate,
  int? dayCount,
}) {
  final month = fmtMonthYear(firstSessionDate, localeName);
  final parts = [
    if (month != null) l.profileTrainingSince(month),
    if (dayCount != null && dayCount > 0) l.profileSplitDays(dayCount),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

// ── ProfileScreen ─────────────────────────────────────────────────────────────

/// Profile & Settings, embedded as a shell destination or opened standalone.
///
/// Exposes:
///   • Editable profile name → SettingsService
///   • Training line (first workout month · training days) from the local DB
///   • Quick stats (Sessions / PRs / Bodyweight) from the local DB
///   • Units chip (kg / lb) → UnitService
///   • Theme chip (Dark / Light) and all stored accent choices
///   • Backup/restore and workout-history sharing
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.onClose,
    this.embedded = false,
    this.onLogout,
    this.auth,
  });

  final VoidCallback onClose;
  final bool embedded;
  final Future<void> Function()? onLogout;
  final Object? auth;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Name editing state
  bool _editingName = false;
  late final TextEditingController _nameCtrl;

  // Data export state
  bool _exportingHistory = false;

  // Update-check state (Android only).

  // Runtime app version (footer; reused by the Updates group).
  String _version = '';

  // The header's training line data; null until the first value arrives, and
  // the header shows no line until then. Held here, not in the header: the
  // header is a ListView child swapped out while the name is edited, and a
  // stream it owned would re-query on every remount and make the line blink.
  ({String? firstSessionDate, int dayCount})? _training;
  StreamSubscription<({String? firstSessionDate, int dayCount})>? _trainingSub;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    _nameCtrl = TextEditingController(text: settings.profileName);
    PackageInfo.fromPlatform().then((i) {
      if (mounted) {
        setState(() => _version = i.version);
      }
    });
    // onError hides the line rather than leaving it stale; the subscription
    // stays open, so the next emission brings it back.
    _trainingSub = StatsRepository.local(context.read<LocalDatabase>())
        .watchTrainingSummary()
        .listen(
          (t) {
            if (mounted) {
              setState(() => _training = t);
            }
          },
          onError: (Object e, StackTrace st) {
            debugPrint('profile: training summary stream error: $e');
            if (mounted) {
              setState(() => _training = null);
            }
          },
        );
  }

  @override
  void dispose() {
    _trainingSub?.cancel();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  // Shared with the Today greeting avatar via [initialsOf] so they never diverge.
  String _initials(String name) => initialsOf(name);

  void _submitName(SettingsService settings) {
    final trimmed = _nameCtrl.text.trim();
    if (trimmed.isNotEmpty) {
      showWriteFailures(context, settings.setProfileName(trimmed));
    }
    setState(() => _editingName = false);
  }

  // ── Language picker ─────────────────────────────────────────────────────────

  // The language in its own name, as the sheet lists it; null, or a code the
  // UI can't write, reads as the system default.
  String _languageLabel(BuildContext context, String? code) {
    for (final lang in appLanguages) {
      if (lang.code == code) {
        return lang.name;
      }
    }
    return AppLocalizations.of(context).languageSystem;
  }

  Future<void> _pickLanguage(
    BuildContext context,
    SettingsService settings,
  ) async {
    final choice = await showLanguageSheet(
      context,
      current: settings.localeOverride,
    );
    if (choice == null) {
      return;
    } // dismissed
    if (!context.mounted) {
      return;
    }
    showWriteFailures(
      context,
      settings.setLocaleOverride(choice == 'system' ? null : choice),
    );
  }

  Future<void> _pickBodyStyle(SettingsService settings) async {
    final l = AppLocalizations.of(context);
    final choice = await showWActionSheet<String>(
      context,
      title: l.bodyArtworkStyle,
      actions: [
        WSheetAction(
          label: l.bodyMaleArtwork,
          value: 'male',
          selected: settings.bodyStyle == 'male',
        ),
        WSheetAction(
          label: l.bodyFemaleArtwork,
          value: 'female',
          selected: settings.bodyStyle == 'female',
        ),
      ],
    );
    if (choice != null && mounted) {
      showWriteFailures(context, settings.setBodyStyle(choice));
    }
  }

  // ── Bodyweight goal picker ──────────────────────────────────────────────

  String _goalLabel(AppLocalizations l, BodyweightGoal g) => switch (g) {
    BodyweightGoal.cut => l.goalCut,
    BodyweightGoal.bulk => l.goalBulk,
    BodyweightGoal.maintain => l.goalMaintain,
  };

  Future<void> _pickGoal(BuildContext context, SettingsService settings) async {
    final l = AppLocalizations.of(context);
    final picked = await showWActionSheet<BodyweightGoal>(
      context,
      title: l.profileGoal,
      actions: [
        for (final g in BodyweightGoal.values)
          WSheetAction(
            label: _goalLabel(l, g),
            value: g,
            icon: WIcons.target,
            selected: g == settings.bodyweightGoal,
          ),
      ],
    );
    if (picked != null && context.mounted) {
      showWriteFailures(context, settings.setBodyweightGoal(picked));
    }
  }

  Future<void> _flushBoundary() async {
    commitPendingInput();
    await UnsavedEditors.instance.drainOrThrow();
    if (!mounted) {
      throw const StoreException('boundary_unmounted');
    }
    await context.read<SessionManager>().flushPersistence();
    if (!mounted) {
      throw const StoreException('boundary_unmounted');
    }
    await context.read<SettingsService>().flushPersistence();
    if (!mounted) {
      throw const StoreException('boundary_unmounted');
    }
    await context.read<UnitService>().flushPersistence();
  }

  Future<void> _exportHistory() async {
    // Earliest session date bounds the picker; fall back to one year back.
    final row = await context.read<LocalDatabase>().getOptional(
      'SELECT MIN(date) AS d FROM sessions',
    );
    final now = DateTime.now();
    var first =
        DateTime.tryParse((row?['d'] as String?) ?? '') ??
        now.subtract(const Duration(days: 365));
    if (first.isAfter(now)) {
      first = now;
    }
    if (!mounted) {
      return;
    }

    final range = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: now,
      initialDateRange: DateTimeRange(start: first, end: now),
    );
    if (range == null || !mounted) {
      return;
    }

    setState(() => _exportingHistory = true);
    try {
      await _flushBoundary();
      if (!mounted) {
        return;
      }
      final result = await ExportService(
        context.read<LocalDatabase>(),
      ).exportHistory(from: range.start, to: range.end);
      if (mounted) {
        await _reportExport(result);
      }
    } catch (e) {
      if (mounted) {
        await _exportError(e);
      }
    } finally {
      if (mounted) {
        setState(() => _exportingHistory = false);
      }
    }
  }

  Future<void> _reportExport(ExportResult result) async {
    final l = AppLocalizations.of(context);
    switch (result.outcome) {
      case ExportOutcome.shared:
        await showWDialog<bool>(
          context,
          title: l.alkionDocumentShared,
          message: l.alkionDocumentSharedMessage,
          actions: [WDialogAction(label: l.commonOk, value: true)],
        );
      case ExportOutcome.providerVerified:
        await showWDialog<bool>(
          context,
          title: l.alkionDocumentSaved,
          message: l.alkionDocumentSavedMessage(
            documentLabel(result.path ?? ''),
          ),
          actions: [WDialogAction(label: l.commonOk, value: true)],
        );
      case ExportOutcome.cancelled:
        await showWDialog<bool>(
          context,
          title: l.alkionDocumentCancelled,
          message: l.alkionDocumentCancelledMessage,
          actions: [WDialogAction(label: l.commonOk, value: true)],
        );
      case ExportOutcome.saved:
        await showWDialog<bool>(
          context,
          title: l.exportSavedTitle,
          message: l.exportSavedMessage(result.path ?? ''),
          actions: [WDialogAction(label: l.commonOk, value: true)],
        );
      case ExportOutcome.empty:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.exportNoSessionsInRange)));
    }
  }

  Future<void> _exportError(Object e) async {
    final l = AppLocalizations.of(context);
    await showWDialog<bool>(
      context,
      title: l.exportFailedTitle,
      message:
          compatibilityExportRefusalMessage(l, e) ??
          l.alkionDocumentFailureMessage(
            e is DocumentException ? e.category : '$e',
          ),
      actions: [WDialogAction(label: l.commonOk, value: true)],
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final unitService = context.watch<UnitService>();
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);

    return Scaffold(
      body: ColoredBox(
        color: tokens.bg,
        child: Column(
          children: [
            // ── Header ────────────────────────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: tokens.bg,
                border: Border(bottom: BorderSide(color: tokens.line)),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Row(
                    children: [
                      if (!widget.embedded)
                        Semantics(
                          button: true,
                          label: l.commonBack,
                          excludeSemantics: true,
                          onTap: widget.onClose,
                          child: GestureDetector(
                            onTap: widget.onClose,
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Center(
                                child: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    border: Border.all(color: tokens.line),
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.control,
                                    ),
                                    color: tokens.surface2,
                                  ),
                                  child: Icon(
                                    WIcons.back,
                                    size: 18,
                                    color: tokens.dim,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (!widget.embedded) const SizedBox(width: 12),
                      Expanded(
                        child: FitLabel(
                          l.profileTitle,
                          maxLines: 2,
                          style: WorkoutType.display(
                            size: widget.embedded ? 28 : 22,
                            weight: FontWeight.w500,
                            color: tokens.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Scrollable body ───────────────────────────────────────────────
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  24,
                  16,
                  widget.embedded
                      ? bottomNavInset(context)
                      : 32 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                children: [
                  // ── Profile header ──────────────────────────────────────────
                  _buildProfileHeader(settings, tokens),

                  const SizedBox(height: 24),

                  // ── Quick stats ─────────────────────────────────────────────
                  const _QuickStats(),

                  const SizedBox(height: 24),

                  // ── Units ───────────────────────────────────────────────────
                  _Group(
                    label: l.profileGroupUnits,
                    children: [
                      _Row(
                        icon: WIcons.scale,
                        title: l.profileWeightUnit,
                        sub: l.profileWeightUnitSub,
                        control: true,
                        right: ChipSelect<Unit>(
                          items: Unit.values,
                          selected: unitService.unit,
                          labelOf: (u) => u == Unit.kg ? 'kg' : 'lb',
                          onSelect: unitService.setUnit,
                        ),
                      ),
                    ],
                  ),

                  // ── Bodyweight ──────────────────────────────────────────────
                  _Group(
                    label: l.profileGroupBodyweight,
                    children: [
                      _Row(
                        icon: WIcons.scale,
                        title: l.profileGoal,
                        sub: _goalLabel(l, settings.bodyweightGoal),
                        right: Icon(
                          WIcons.chevron,
                          size: 16,
                          color: tokens.faint,
                        ),
                        onTap: () => _pickGoal(context, settings),
                      ),
                    ],
                  ),

                  // ── Appearance ──────────────────────────────────────────────
                  _Group(
                    label: l.profileGroupAppearance,
                    children: [
                      _Row(
                        icon: settings.mode == 'dark'
                            ? WIcons.flame
                            : WIcons.bolt,
                        title: l.profileTheme,
                        control: true,
                        right: ChipSelect<String>(
                          items: const ['dark', 'light'],
                          selected: settings.mode,
                          labelOf: (m) => m == 'dark'
                              ? l.profileThemeDark
                              : l.profileThemeLight,
                          onSelect: (m) =>
                              showWriteFailures(context, settings.setMode(m)),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Row(
                            icon: WIcons.target,
                            title: l.profileAccent,
                            sub: l.profileAccentSub,
                            right: null,
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: _buildAccentSwatches(settings, tokens),
                          ),
                        ],
                      ),
                      _Row(
                        icon: WIcons.user,
                        title: l.bodyArtworkStyle,
                        sub: settings.bodyStyle == 'female'
                            ? l.bodyFemaleArtwork
                            : l.bodyMaleArtwork,
                        right: Icon(
                          WIcons.chevron,
                          size: 16,
                          color: tokens.faint,
                        ),
                        onTap: () => _pickBodyStyle(settings),
                      ),
                      _Row(
                        icon: WIcons.globe,
                        title: l.settingsLanguage,
                        sub: _languageLabel(context, settings.localeOverride),
                        right: Icon(
                          WIcons.chevron,
                          size: 16,
                          color: tokens.faint,
                        ),
                        onTap: () => _pickLanguage(context, settings),
                      ),
                    ],
                  ),

                  _Group(
                    label: l.trainingPreferences,
                    children: [
                      _Row(
                        icon: WIcons.gear,
                        title: l.trainingPreferences,
                        sub: l.trainingPreferencesHint,
                        right: Icon(
                          WIcons.chevron,
                          size: 16,
                          color: tokens.faint,
                        ),
                        onTap: () =>
                            showTrainingPreferencesSheet(context, settings),
                      ),
                    ],
                  ),

                  // ── Rest ────────────────────────────────────────────────────
                  _Group(
                    label: l.profileGroupRest,
                    children: [
                      _Row(
                        icon: WIcons.timer,
                        title: l.profileCompoundRest,
                        sub: l.profileCompoundRestSub,
                        control: true,
                        right: SizedBox(
                          width: 192,
                          child: WStepper(
                            value: settings.restCompoundSeconds.toDouble(),
                            step: 15,
                            format: (v) => '${v.round()}s',
                            onChanged: (v) => showWriteFailures(
                              context,
                              settings.setRestCompoundSeconds(v.round()),
                            ),
                            editable: true,
                            allowDecimal: false,
                            min: 0,
                            formatForEdit: (v) => v.round().toString(),
                            semanticLabel: l.profileCompoundRest,
                          ),
                        ),
                      ),
                      _Row(
                        icon: WIcons.timer,
                        title: l.profileIsolationRest,
                        sub: l.profileIsolationRestSub,
                        control: true,
                        right: SizedBox(
                          width: 192,
                          child: WStepper(
                            value: settings.restIsolationSeconds.toDouble(),
                            step: 15,
                            format: (v) => '${v.round()}s',
                            onChanged: (v) => showWriteFailures(
                              context,
                              settings.setRestIsolationSeconds(v.round()),
                            ),
                            editable: true,
                            allowDecimal: false,
                            min: 0,
                            formatForEdit: (v) => v.round().toString(),
                            semanticLabel: l.profileIsolationRest,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const AnimusConnectionPanel(),

                  // ── Data ────────────────────────────────────────────────────
                  _Group(
                    key: const Key('profile-data-actions'),
                    label: l.profileGroupData,
                    children: [
                      _Row(
                        icon: WIcons.refresh,
                        title: l.alkionBackupRestore,
                        sub: l.alkionBackupRestoreSub,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                AlkionRecoveryScreen(flush: _flushBoundary),
                          ),
                        ),
                      ),
                      _Row(
                        icon: WIcons.history,
                        title: l.exportHistory,
                        sub: l.exportHistorySub,
                        right: _exportingHistory ? const _RowSpinner() : null,
                        onTap: _exportingHistory ? null : _exportHistory,
                      ),
                    ],
                  ),

                  // ── Version footer ───────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      children: [
                        const AlkionBrandLockup(compact: true),
                        const SizedBox(height: 8),
                        Text(
                          _version.isEmpty
                              ? 'Alkion Dev'
                              : 'Alkion Dev · v$_version',
                          textAlign: TextAlign.center,
                          style: WorkoutType.body(size: 12, color: tokens.dim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Sub-builders ──────────────────────────────────────────────────────────

  Widget _buildProfileHeader(SettingsService settings, WorkoutTokens tokens) {
    final l = AppLocalizations.of(context);
    final training = _training;
    final trainingLine = training == null
        ? null
        : profileTrainingLine(
            l,
            Localizations.localeOf(context).toLanguageTag(),
            firstSessionDate: training.firstSessionDate,
            dayCount: training.dayCount,
          );
    return Row(
      children: [
        // Local identity uses a neutral surface; workout data owns the accent.
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            color: tokens.surface2,
            border: Border.all(color: tokens.line),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FittedBox(
              child: Text(
                _initials(settings.profileName),
                style: WorkoutType.display(
                  size: 26,
                  weight: FontWeight.w500,
                  color: tokens.text,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_editingName)
                TextInput(
                  controller: _nameCtrl,
                  placeholder: l.profileNamePlaceholder,
                  onChanged: (_) => setState(() {}),
                )
              else
                Semantics(
                  button: true,
                  label: l.profileEditName,
                  excludeSemantics: true,
                  onTap: () => setState(() => _editingName = true),
                  child: GestureDetector(
                    onTap: () => setState(() => _editingName = true),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Row(
                        children: [
                          Flexible(
                            child: FitLabel(
                              settings.profileName,
                              maxLines: 2,
                              style: WorkoutType.display(
                                size: 22,
                                weight: FontWeight.w500,
                                color: tokens.text,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(WIcons.edit, size: 15, color: tokens.faint),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_editingName) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _submitName(settings),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: tokens.text,
                    ),
                    child: FitLabel(
                      l.profileSaveName,
                      maxLines: 2,
                      style: WorkoutType.body(
                        size: 14,
                        weight: FontWeight.w500,
                        color: tokens.text,
                      ),
                    ),
                  ),
                ),
              ] else if (trainingLine != null) ...[
                const SizedBox(height: 3),
                Text(
                  trainingLine,
                  key: const Key('profile-training-line'),
                  style: WorkoutType.body(size: 12, color: tokens.dim),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAccentSwatches(SettingsService settings, WorkoutTokens tokens) {
    final l = AppLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: accents.asMap().entries.map((entry) {
        final n = entry.key + 1;
        final color = entry.value;
        final isSelected = settings.accent == color;
        return Semantics(
          button: true,
          selected: isSelected,
          label: l.profileAccentOption(n),
          excludeSemantics: true,
          onTap: () => showWriteFailures(context, settings.setAccent(color)),
          child: IconButton(
            key: ValueKey('profile-accent-$n'),
            onPressed: () =>
                showWriteFailures(context, settings.setAccent(color)),
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              fixedSize: const Size(48, 48),
              padding: const EdgeInsets.all(8),
              focusColor: tokens.focus.withValues(alpha: 0.25),
              side: BorderSide(color: isSelected ? tokens.text : tokens.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
            icon: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              child: isSelected
                  ? Icon(
                      WIcons.check,
                      size: 18,
                      color: color.computeLuminance() > 0.179
                          ? const Color(0xFF000000)
                          : const Color(0xFFFFFFFF),
                    )
                  : null,
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _RowSpinner extends StatelessWidget {
  const _RowSpinner();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: context.tokens.dim,
      ),
    );
  }
}
