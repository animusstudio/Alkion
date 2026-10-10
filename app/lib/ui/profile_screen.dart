import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:powersync/powersync.dart' show SyncStatus;
import 'package:provider/provider.dart';

import '../auth/auth_store.dart';
import '../capture/capture_transport.dart';
import '../capture/source_write_gate.dart';
import '../data/bodyweight_repository.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../data/stats_repository.dart';
import '../export/export_service.dart';
import '../l10n/app_localizations.dart';
import '../settings/app_languages.dart';
import '../settings/bodyweight_goal.dart';
import '../settings/settings_service.dart';
import '../sync/db.dart';
import '../sync/sync_health.dart';
import '../sync/sync_status_label.dart';
import '../sync/sync_status_ui.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../update/update_service.dart';
import '../update/update_ui.dart';
import '../util/dates.dart';
import '../widgets/fit_label.dart';
import '../widgets/plan_form.dart';
import '../widgets/stepper.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';
import 'login_screen.dart';
import 'sign_in_again.dart';

// ── Group + Row helpers (mirror screen-profile.jsx) ──────────────────────────

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 9),
            child: Text(
              label.toUpperCase(),
              style: WorkoutType.mono(
                size: 10.5,
                weight: FontWeight.w600,
                color: tokens.faint,
                letterSpacing: 0.1 * 10.5,
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
              borderRadius: BorderRadius.circular(AppRadius.radius),
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
    this.below,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? sub;
  final Widget? right;

  /// A line under the title and sub, for a value too long for [right].
  final Widget? below;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final r = AppRadius.radius * 0.5;

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: 13),
      child: LayoutBuilder(builder: (context, constraints) => Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tokens.surface3,
              borderRadius: BorderRadius.circular(r),
            ),
            child: Icon(
              icon,
              size: 18,
              color: danger ? tokens.danger : tokens.accentText,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FitLabel(
                  title,
                  maxLines: 2,
                  style: WorkoutType.body(
                    size: 14.5,
                    weight: FontWeight.w600,
                    color: danger ? tokens.danger : tokens.text,
                  ),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WorkoutType.mono(size: 10.5, color: tokens.faint),
                  ),
                ],
                if (below != null) ...[
                  const SizedBox(height: 6),
                  below!,
                ],
              ],
            ),
          ),
          if (right != null) ...[
            const SizedBox(width: 8),
            // Capped so a wide control (chips, a long sync status at large
            // text) wraps inside its slot instead of squeezing the title to
            // nothing or overflowing the row.
            ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: constraints.maxWidth * _rightShare),
              child: right!,
            ),
          ],
        ],
      )),
    );

    if (onTap != null) {
      row = GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: onTap, child: row);
    }

    return row;
  }

  /// The most of the row the right slot may take; the 144dp rest steppers
  /// still fit it at 320dp.
  static const _rightShare = 0.6;

  static const _hPad = 14.0;
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
      SessionRepository(db).watchSessionStats();
  late final Stream<List<BodyweightEntry>> _bodyweight =
      BodyweightRepository(db).watchSeriesAsc();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final unitService = context.watch<UnitService>();

    return StreamBuilder<List<HistorySessionRow>>(
      stream: _sessions,
      builder: (context, sessionSnap) {
        final sessions = sessionSnap.data ?? [];
        final sessionCount = sessions.length.toString();
        final prCount =
            sessions.fold<int>(0, (sum, s) => sum + s.prCount).toString();

        return StreamBuilder<List<BodyweightEntry>>(
          stream: _bodyweight,
          builder: (context, bwSnap) {
            final bwEntries = bwSnap.data ?? [];
            final bwText = bwEntries.isEmpty
                ? '–'
                : '${unitService.fmtBw(bwEntries.last.weightKg)}${unitService.uLabel}';

            return Row(
              children: [
                Expanded(
                    child: _StatCard(
                        label: l.profileStatSessions, value: sessionCount)),
                const SizedBox(width: 8),
                Expanded(
                    child: _StatCard(label: l.profileStatPrs, value: prCount)),
                const SizedBox(width: 8),
                // Expanded must stay the direct Row child; UnitSwap's
                // AnimatedSwitcher cannot host a flex ParentDataWidget.
                Expanded(
                  child: UnitSwap(
                    unitKey: unitService.unit,
                    child: _StatCard(
                        label: l.profileStatBodyweight, value: bwText),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // No internal Expanded: callers place this in a Row and own the flex,
    // so wrappers (e.g. UnitSwap) can sit between the Row and the card.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(AppRadius.radius),
      ),
      child: Column(
        children: [
          // A third of a narrow phone at large text: "82.4kg" scales down
          // whole and the label shrinks, then ellipsizes.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: WorkoutType.display(
                size: 20,
                weight: FontWeight.w700,
                color: tokens.text,
              ),
            ),
          ),
          const SizedBox(height: 6),
          FitLabel(
            label.toUpperCase(),
            style: WorkoutType.mono(
              size: 9,
              color: tokens.faint,
              letterSpacing: 0.06 * 9,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Training line ─────────────────────────────────────────────────────────────

/// The Profile header's second line, or null to hide it.
///
/// "Since" is the month of the first logged workout, dropped when
/// [firstSessionDate] is null or doesn't parse; the split is the number of
/// the user's own training days, dropped when [dayCount] is null or 0.
String? profileTrainingLine(AppLocalizations l, String localeName,
    {String? firstSessionDate, int? dayCount}) {
  final month = fmtMonthYear(firstSessionDate, localeName);
  final parts = [
    if (month != null) l.profileTrainingSince(month),
    if (dayCount != null && dayCount > 0) l.profileSplitDays(dayCount),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

// ── ProfileScreen ─────────────────────────────────────────────────────────────

/// Full-screen Profile & Settings overlay, pushed on the root navigator.
///
/// Exposes:
///   • Editable profile name → SettingsService
///   • Training line (first workout month · training days) from the local DB
///   • Quick stats (Sessions / PRs / Bodyweight) from the local DB
///   • Units chip (kg / lb) → UnitService
///   • Theme chip (Dark / Light) + 4 accent swatches → SettingsService
///   • Configurable server URL → confirm → setServerUrl + apiBaseUrl, then
///     onLogout first, onClose second (safe teardown order)
///   • Account: signed-in email + Sign out (danger, confirm)
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.onClose,
    required this.onLogout,
    required this.auth,
  });

  final VoidCallback onClose;
  final Future<void> Function() onLogout;
  final AuthStore auth;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Name editing state
  bool _editingName = false;
  late final TextEditingController _nameCtrl;

  // Server URL field
  late final TextEditingController _serverCtrl;
  String _currentServerUrl = '';

  // Data export state
  bool _exportingFull = false;
  bool _exportingHistory = false;

  // Update-check state (Android only).
  bool _checking = false;

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
    _serverCtrl = TextEditingController(text: settings.serverUrl);
    _currentServerUrl = settings.serverUrl;
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _version = i.version);
    });
    // onError hides the line rather than leaving it stale; the subscription
    // stays open, so the next emission brings it back.
    _trainingSub = StatsRepository(db).watchTrainingSummary().listen((t) {
      if (mounted) setState(() => _training = t);
    }, onError: (Object e, StackTrace st) {
      debugPrint('profile: training summary stream error: $e');
      if (mounted) setState(() => _training = null);
    });
  }

  @override
  void dispose() {
    _trainingSub?.cancel();
    _nameCtrl.dispose();
    _serverCtrl.dispose();
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
      if (lang.code == code) return lang.name;
    }
    return AppLocalizations.of(context).languageSystem;
  }

  Future<void> _pickLanguage(
      BuildContext context, SettingsService settings) async {
    final choice =
        await showLanguageSheet(context, current: settings.localeOverride);
    if (choice == null) return; // dismissed
    if (!context.mounted) return;
    showWriteFailures(context,
        settings.setLocaleOverride(choice == 'system' ? null : choice));
  }

  // ── Bodyweight goal picker ──────────────────────────────────────────────

  String _goalLabel(AppLocalizations l, BodyweightGoal g) => switch (g) {
        BodyweightGoal.cut => l.goalCut,
        BodyweightGoal.bulk => l.goalBulk,
        BodyweightGoal.maintain => l.goalMaintain,
      };

  Future<void> _pickGoal(BuildContext context, SettingsService settings) async {
    final l = AppLocalizations.of(context);
    final picked = await showWActionSheet<BodyweightGoal>(context,
        title: l.profileGoal,
        actions: [
          for (final g in BodyweightGoal.values)
            WSheetAction(
              label: _goalLabel(l, g),
              value: g,
              icon: WIcons.target,
              selected: g == settings.bodyweightGoal,
            ),
        ]);
    if (picked != null && context.mounted) {
      showWriteFailures(context, settings.setBodyweightGoal(picked));
    }
  }

  // ── Server-switch flow ────────────────────────────────────────────────────

  Future<void> _applyServer(SettingsService settings) async {
    final url = _serverCtrl.text.trim();
    if (url.isEmpty || !url.startsWith('http')) return;

    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.profileSwitchServerTitle,
      message: l.profileSwitchServerMessage,
      confirmLabel: l.profileSwitchServerConfirm,
      destructive: true,
    );

    if (confirmed != true) return;

    try {
      // An account switch is refused up front while a data capture runs.
      TransportAdmission.instance.ensureOpen('account.switch_server');

      // Persist new URL and update the global apiBaseUrl.
      await settings.setServerUrl(url);
      apiBaseUrl = url;

      // onLogout first (flips _loggedIn → swaps AppShell for LoginScreen
      // while AppShell is still live), then onClose (pops overlay — harmless
      // no-op once the parent route is gone).
      await widget.onLogout();
    } on SourceGateException catch (e) {
      if (mounted) await showWriteFailed(context, e);
      return;
    }
    widget.onClose();
  }

  // ── Sign-in flow (when signed out) ─────────────────────────────────────────

  Future<void> _signIn(SettingsService settings) async {
    final url = _serverCtrl.text.trim();
    // Login (auth_store) hits the global apiBaseUrl, so it must point at the
    // entered URL before we push LoginScreen. We do NOT persist it yet —
    // settings.setServerUrl is deferred into onLoggedIn so abandoning login
    // leaves no persisted change.
    apiBaseUrl = url;
    if (!mounted) return;

    final navigator = Navigator.of(context);
    await navigator.push(MaterialPageRoute(
      builder: (_) => LoginScreen(
        auth: widget.auth,
        onLoggedIn: () async {
          // Persist the URL only now that login succeeded.
          await settings.setServerUrl(url);
          apiBaseUrl = url;
          await reconcileAndConnect(navigator, settings, auth: widget.auth);
        },
      ),
    ));

    if (mounted) setState(() {});
  }

  /// Signing in again after the server ended the session; the flow itself
  /// is shared with the Today banner (see [signInAgain]).
  Future<void> _signInAgain(SettingsService settings) async {
    await signInAgain(context, auth: widget.auth, settings: settings);
    if (mounted) setState(() {});
  }

  // ── Sign-out flow ─────────────────────────────────────────────────────────

  Future<void> _signOut() async {
    // Signing out wipes local data, so changes that never uploaded (or can't,
    // with the session expired) would be lost.
    final pending = await pendingUploadCount();
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final confirmed = await showWConfirm(
      context,
      title: l.profileSignOutTitle,
      // Only unsynced changes are lost by signing out; with none pending,
      // even an expired session signs out harmlessly.
      message: pending > 0
          ? l.profileSignOutUnsyncedMessage(pending)
          : l.profileSignOutMessage,
      confirmLabel: l.profileSignOut,
    );

    if (confirmed != true) return;

    try {
      await widget.onLogout();
    } on SourceGateException catch (e) {
      // Refused while a data capture holds the source: still signed in,
      // nothing cleared.
      if (mounted) await showWriteFailed(context, e);
      return;
    }
    widget.onClose();
  }

  Future<void> _exportFull() async {
    setState(() => _exportingFull = true);
    try {
      final result = await ExportService(db).exportFull(
        settings: context.read<SettingsService>(),
        units: context.read<UnitService>(),
      );
      if (mounted) await _reportExport(result);
    } catch (e) {
      if (mounted) await _exportError(e);
    } finally {
      if (mounted) setState(() => _exportingFull = false);
    }
  }

  Future<void> _exportHistory() async {
    // Earliest session date bounds the picker; fall back to one year back.
    final row = await db.getOptional('SELECT MIN(date) AS d FROM sessions');
    final now = DateTime.now();
    var first = DateTime.tryParse((row?['d'] as String?) ?? '') ??
        now.subtract(const Duration(days: 365));
    if (first.isAfter(now)) first = now;
    if (!mounted) return;

    final range = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: now,
      initialDateRange: DateTimeRange(start: first, end: now),
    );
    if (range == null || !mounted) return;

    setState(() => _exportingHistory = true);
    try {
      final result =
          await ExportService(db).exportHistory(from: range.start, to: range.end);
      if (mounted) await _reportExport(result);
    } catch (e) {
      if (mounted) await _exportError(e);
    } finally {
      if (mounted) setState(() => _exportingHistory = false);
    }
  }

  Future<void> _reportExport(ExportResult result) async {
    final l = AppLocalizations.of(context);
    switch (result.outcome) {
      case ExportOutcome.shared:
        return; // the share sheet was the feedback
      case ExportOutcome.saved:
        await showWDialog<bool>(
          context,
          title: l.exportSavedTitle,
          message: l.exportSavedMessage(result.path ?? ''),
          actions: [WDialogAction(label: l.commonOk, value: true)],
        );
      case ExportOutcome.empty:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.exportNoSessionsInRange)),
        );
    }
  }

  Future<void> _exportError(Object e) async {
    final l = AppLocalizations.of(context);
    await showWDialog<bool>(
      context,
      title: l.exportFailedTitle,
      message: '$e',
      actions: [WDialogAction(label: l.commonOk, value: true)],
    );
  }

  // ── Update check (manual button) ────────────────────────────────────────────

  Future<void> _checkUpdates() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final settings = context.read<SettingsService>();
    setState(() => _checking = true);
    UpdateInfo? info;
    var errored = false;
    try {
      info = await UpdateService().checkForUpdate(force: true);
    } catch (_) {
      errored = true;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    try {
      await settings.markUpdateChecked(DateTime.now().millisecondsSinceEpoch);
    } on SourceGateException {
      // Not recorded while a data capture holds the source; the result below
      // is still shown.
    }
    if (!mounted) return;
    if (errored) {
      messenger.showSnackBar(SnackBar(content: Text(l.updatesError)));
    } else if (info == null) {
      messenger.showSnackBar(SnackBar(content: Text(l.updatesUpToDate)));
    } else {
      await showUpdateDialog(context, info);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final unitService = context.watch<UnitService>();
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);

    // Keep _currentServerUrl in sync when settings change externally.
    if (_currentServerUrl != settings.serverUrl &&
        _serverCtrl.text == _currentServerUrl) {
      _serverCtrl.text = settings.serverUrl;
      _currentServerUrl = settings.serverUrl;
    }

    final trimmedServerUrl = _serverCtrl.text.trim();
    final serverChanged = trimmedServerUrl != settings.serverUrl &&
        trimmedServerUrl.startsWith('http');

    final signedIn = widget.auth.email != null;

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
                padding:
                    const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
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
                                borderRadius:
                                    BorderRadius.circular(AppRadius.pill),
                                color: tokens.surface,
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
                    const SizedBox(width: 12),
                    Text(
                      l.profileTitle,
                      style: WorkoutType.display(
                        size: 19,
                        weight: FontWeight.w700,
                        color: tokens.text,
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
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 104),
              children: [
                // ── Profile header ──────────────────────────────────────────
                _buildProfileHeader(settings, tokens),

                const SizedBox(height: 22),

                // ── Quick stats ─────────────────────────────────────────────
                const _QuickStats(),

                const SizedBox(height: 22),

                // ── Units ───────────────────────────────────────────────────
                _Group(
                  label: l.profileGroupUnits,
                  children: [
                    _Row(
                      icon: WIcons.scale,
                      title: l.profileWeightUnit,
                      sub: l.profileWeightUnitSub,
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
                      right: Icon(WIcons.chevron, size: 16, color: tokens.faint),
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
                      right: ChipSelect<String>(
                        items: const ['dark', 'light'],
                        selected: settings.mode,
                        labelOf: (m) =>
                            m == 'dark' ? l.profileThemeDark : l.profileThemeLight,
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
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                          child: _buildAccentSwatches(settings, tokens),
                        ),
                      ],
                    ),
                    _Row(
                      icon: WIcons.globe,
                      title: l.settingsLanguage,
                      sub: _languageLabel(context, settings.localeOverride),
                      right: Icon(WIcons.chevron, size: 16, color: tokens.faint),
                      onTap: () => _pickLanguage(context, settings),
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
                      right: SizedBox(
                        width: 144,
                        child: WStepper(
                          value: settings.restCompoundSeconds.toDouble(),
                          step: 15,
                          format: (v) => '${v.round()}s',
                          onChanged: (v) => showWriteFailures(context,
                              settings.setRestCompoundSeconds(v.round())),
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
                      right: SizedBox(
                        width: 144,
                        child: WStepper(
                          value: settings.restIsolationSeconds.toDouble(),
                          step: 15,
                          format: (v) => '${v.round()}s',
                          onChanged: (v) => showWriteFailures(context,
                              settings.setRestIsolationSeconds(v.round())),
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

                // ── Sync & Backend ──────────────────────────────────────────
                _Group(
                  label: l.profileGroupSync,
                  children: [
                    _SyncRow(
                      live: signedIn && settings.syncEnabled,
                      expired: widget.auth.sessionExpired,
                      title: l.profileSyncServer,
                      sub: settings.serverUrl,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 13),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextInput(
                            controller: _serverCtrl,
                            placeholder: l.profileServerPlaceholder,
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l.profileLocalFirstHint,
                            style: WorkoutType.mono(
                              size: 10.5,
                              color: tokens.faint,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (signedIn)
                            PrimaryBtn(
                              l.profileApplyServer,
                              enabled: serverChanged,
                              secondary: true,
                              onTap: () => _applyServer(settings),
                            )
                          else
                            PrimaryBtn(
                              l.profileSignInToSync,
                              enabled: true,
                              onTap: () => _signIn(settings),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),

                // ── Data ────────────────────────────────────────────────────
                _Group(
                  label: l.profileGroupData,
                  children: [
                    _Row(
                      icon: WIcons.export,
                      title: AppLocalizations.of(context).exportAllData,
                      sub: AppLocalizations.of(context).exportFullBackup,
                      right: _exportingFull ? const _RowSpinner() : null,
                      onTap: _exportingFull ? null : _exportFull,
                    ),
                    _Row(
                      icon: WIcons.history,
                      title: AppLocalizations.of(context).exportHistory,
                      sub: AppLocalizations.of(context).exportHistorySub,
                      right: _exportingHistory ? const _RowSpinner() : null,
                      onTap: _exportingHistory ? null : _exportHistory,
                    ),
                  ],
                ),

                // ── Updates ─────────────────────────────────────────────────
                _Group(
                  label: l.updatesGroup,
                  children: [
                    _Row(
                      icon: WIcons.update,
                      title: l.updatesVersion(
                          _version.isEmpty ? '–' : _version),
                    ),
                    if (Platform.isAndroid) ...[
                      _Row(
                        icon: WIcons.refresh,
                        title: _checking ? l.updatesChecking : l.updatesCheck,
                        right: _checking ? const _RowSpinner() : null,
                        onTap: _checking ? null : _checkUpdates,
                      ),
                      _Row(
                        icon: WIcons.bolt,
                        title: l.updatesAutoCheck,
                        right: Toggle(
                          value: settings.autoCheckUpdates,
                          semanticLabel: l.updatesAutoCheck,
                          onChanged: (v) => showWriteFailures(
                              context,
                              context
                                  .read<SettingsService>()
                                  .setAutoCheckUpdates(v)),
                        ),
                      ),
                    ],
                  ],
                ),

                // ── Account ─────────────────────────────────────────────────
                if (signedIn)
                  _Group(
                    label: l.profileGroupAccount,
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: widget.auth.sessionExpired,
                        builder: (context, expired, _) => expired
                            ? _Row(
                                icon: WIcons.user,
                                title: l.syncSessionExpired,
                                sub: l.profileSessionExpiredSub,
                                right: Icon(WIcons.chevron,
                                    size: 16, color: tokens.faint),
                                onTap: () => _signInAgain(settings),
                              )
                            : _Row(
                                icon: WIcons.user,
                                title: l.profileSignedIn,
                                sub: widget.auth.email ?? '–',
                              ),
                      ),
                      _Row(
                        icon: WIcons.logout,
                        title: l.profileSignOut,
                        danger: true,
                        onTap: _signOut,
                      ),
                    ],
                  ),

                // ── Version footer ───────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _version.isEmpty ? 'Reps' : 'Reps · v$_version',
                    textAlign: TextAlign.center,
                    style: WorkoutType.mono(size: 10.5, color: tokens.faint),
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
        // 66px accent avatar
        Container(
          width: 66,
          height: 66,
          decoration: BoxDecoration(
            color: tokens.accent,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            _initials(settings.profileName),
            style: WorkoutType.display(
              size: 26,
              weight: FontWeight.w700,
              color: tokens.accentInk,
            ),
          ),
        ),
        const SizedBox(width: 15),
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
                            child: Text(
                              settings.profileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: WorkoutType.display(
                                size: 23,
                                weight: FontWeight.w700,
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
                GestureDetector(
                  onTap: () => _submitName(settings),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l.profileSaveName,
                        style: WorkoutType.mono(
                          size: 11,
                          weight: FontWeight.w600,
                          color: tokens.accentText,
                        ),
                      ),
                    ),
                  ),
                ),
              ] else if (trainingLine != null) ...[
                const SizedBox(height: 3),
                Text(
                  trainingLine,
                  key: const Key('profile-training-line'),
                  style: WorkoutType.mono(size: 11, color: tokens.faint),
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
      spacing: 4,
      runSpacing: 4,
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
          child: GestureDetector(
            onTap: () => showWriteFailures(context, settings.setAccent(color)),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    border: Border.all(
                      color: isSelected ? tokens.text : Colors.transparent,
                      width: 2,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: tokens.bg,
                              spreadRadius: 2,
                              blurRadius: 0,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// The sync server row. Signed in with sync on, its status (dot + label)
/// follows the PowerSync status stream; otherwise it reads "Not connected".
///
/// The status sits in the row's right slot when it fits there on one line.
/// Otherwise ("Offline · synchronisiert vor 3 Std" at large text) it moves to
/// its own line under the title, where it wraps at spaces rather than
/// ellipsizing away the last sync time.
class _SyncRow extends StatelessWidget {
  const _SyncRow({
    required this.live,
    required this.expired,
    required this.title,
    required this.sub,
  });

  final bool live;

  /// The session ended server-side: say so rather than a generic error.
  final ValueListenable<bool> expired;
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    if (!live) {
      return _layout(context, l.syncNotConnected, tokens.faint, false);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: expired,
      builder: (context, isExpired, _) => StreamBuilder<SyncStatus>(
        stream: db.statusStream,
        initialData: db.currentStatus,
        builder: (context, snap) {
          final s = snap.data;
          final state = syncDotStateFor(
            connected: s?.connected ?? false,
            syncing: (s?.uploading ?? false) || (s?.downloading ?? false),
            hasError: s?.uploadError != null || s?.downloadError != null,
          );
          if (isExpired) {
            return _layout(context, l.syncSessionExpired, tokens.danger, false);
          }
          final color = switch (state) {
            SyncDotState.syncing || SyncDotState.synced => tokens.accentText,
            SyncDotState.offline => tokens.faint,
            SyncDotState.error => tokens.danger,
          };
          final label = syncStatusLabel(
              l,
              state,
              s?.lastSyncedAt ?? context.read<SyncHealth>().lastSyncedAt,
              DateTime.now());
          return _layout(
              context, label, color, state == SyncDotState.syncing);
        },
      ),
    );
  }

  Widget _layout(
      BuildContext context, String label, Color color, bool pulsing) {
    final tokens = context.tokens;
    final style =
        WorkoutType.mono(size: 11, weight: FontWeight.w600, color: tokens.dim);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final needed = _dot + _gap + painter.width;
      final lineHeight = painter.preferredLineHeight;
      painter.dispose();
      final slot = (constraints.maxWidth - 2 * _Row._hPad) * _Row._rightShare;
      final fits = needed <= slot;
      final status = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            fits ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: fits ? null : lineHeight,
            child: Center(
              widthFactor: 1,
              child: _SyncDot(color: color, pulsing: pulsing),
            ),
          ),
          const SizedBox(width: _gap),
          Flexible(
            child: fits
                ? Text(label, maxLines: 1, style: style)
                : FitLabel(label, maxLines: 3, style: style),
          ),
        ],
      );
      return _Row(
        icon: WIcons.cloud,
        title: title,
        sub: sub,
        right: fits ? status : null,
        below: fits ? null : status,
      );
    });
  }

  static const _dot = 7.0;
  static const _gap = 6.0;
}

/// 7px dot; pulses (opacity loop) while [pulsing], skipped under reduced motion.
class _SyncDot extends StatefulWidget {
  const _SyncDot({required this.color, required this.pulsing});
  final Color color;
  final bool pulsing;

  @override
  State<_SyncDot> createState() => _SyncDotState();
}

class _SyncDotState extends State<_SyncDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
    lowerBound: 0.35,
    upperBound: 1.0,
  );

  void _sync() {
    final reduced = MediaQuery.of(context).disableAnimations;
    if (widget.pulsing && !reduced) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
      _c.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant _SyncDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
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
