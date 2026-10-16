import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/exercise_repository.dart';
import '../data/models.dart';
import '../data/session_repository.dart';
import '../l10n/app_localizations.dart';
import '../store/local_store.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../units/unit_service.dart';
import '../widgets/fit_label.dart';
import '../widgets/pr_badge.dart';
import '../widgets/tag.dart';

/// Post-session summary overlay.
///
/// Visual spec: README "Screens → 3. Session summary".
///
/// Shows:
/// - Success check mark
/// - `"{name} · {focus}"` title (from `split_label`)
/// - Stat tiles: Duration, Sets, Volume, PRs
/// - Top sets list with PR badges
/// - "Done" button → pops to the launcher
class SessionSummaryScreen extends StatefulWidget {
  const SessionSummaryScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<SessionSummaryScreen> createState() => _SessionSummaryScreenState();
}

class _SessionSummaryScreenState extends State<SessionSummaryScreen> {
  late final SessionRepository _sessionRepo;
  late final ExerciseRepository _exerciseRepo;

  SessionSummaryRow? _session;
  List<ExerciseBlockData>? _blocks;
  Map<String, String> _exerciseNames = {};
  bool _loading = true;

  /// Error state: [_notFound] means the session row was missing; otherwise
  /// [_loadError] (when non-null) carries the raw exception detail. Resolved to
  /// a localized message at build time so the locale is fully available.
  bool _notFound = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _sessionRepo = SessionRepository.local(context.read<LocalDatabase>());
    _exerciseRepo = ExerciseRepository.local(context.read<LocalDatabase>());
    _load();
  }

  Future<void> _load() async {
    try {
      // Read the session summary row
      final rows = await context.read<LocalDatabase>().getAll(
        'SELECT * FROM sessions WHERE id = ?',
        [widget.sessionId],
      );
      if (rows.isEmpty) {
        setState(() {
          _notFound = true;
          _loading = false;
        });
        return;
      }
      final session = SessionSummaryRow.fromRow(rows.first);

      // Read and group sets
      final sets = await _sessionRepo.setsForSession(widget.sessionId);
      final blocks = _sessionRepo.groupIntoBlocks(sets);

      // Load exercise names for display
      final allExercises = await _exerciseRepo.all();
      final names = {for (final e in allExercises) e.id: e.name};

      setState(() {
        _session = session;
        _blocks = blocks;
        _exerciseNames = names;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final unit = context.watch<UnitService>();
    final l = AppLocalizations.of(context);

    final errorMessage = _notFound
        ? l.summarySessionNotFound
        : _loadError != null
        ? l.summaryLoadFailed(_loadError!)
        : null;

    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage != null
          ? _ErrorState(
              error: errorMessage,
              doneLabel: l.commonDone,
              tokens: tokens,
              onDone: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
            )
          : _SummaryBody(
              session: _session!,
              blocks: _blocks!,
              exerciseNames: _exerciseNames,
              unit: unit,
              tokens: tokens,
              onDone: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
            ),
    );
  }
}

// ── Summary body ──────────────────────────────────────────────────────────────

class _SummaryBody extends StatelessWidget {
  const _SummaryBody({
    required this.session,
    required this.blocks,
    required this.exerciseNames,
    required this.unit,
    required this.tokens,
    required this.onDone,
  });

  final SessionSummaryRow session;
  final List<ExerciseBlockData> blocks;
  final Map<String, String> exerciseNames;
  final UnitService unit;
  final WorkoutTokens tokens;
  final VoidCallback onDone;

  int get _totalSets =>
      blocks.fold(0, (n, b) => n + b.sets.where((s) => !s.isWarmup).length);

  CompatibilityCoverage get _coverage =>
      CompatibilityCoverage.sets(blocks.expand((b) => b.sets));

  int get _prCount => blocks.where((b) => b.isPr).length;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final durationMin = session.durationMin;
    final splitLabel = session.splitLabel ?? '';

    // Parse name · focus from the stored split_label (middot separator)
    final parts = splitLabel.split(' · ');
    final title = parts.isNotEmpty ? parts[0] : splitLabel;
    final focus = parts.length > 1 ? parts.sublist(1).join(' · ') : '';

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.of(context).padding.top + 24,
            16,
            MediaQuery.of(context).padding.bottom + 24,
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // ── Header (success icon + title + date) ─────────────────
              StaggeredEntrance(
                index: 0,
                child: Column(
                  children: [
                    // Success icon with a one-shot accent glow flash on mount.
                    _SuccessHeaderFlash(
                      tokens: tokens,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: tokens.accent,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          WIcons.check,
                          size: 36,
                          color: tokens.accentInk,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Title ──────────────────────────────────────────
                    FitLabel.rich(
                      TextSpan(
                        style: WorkoutType.display(
                          size: 22,
                          weight: FontWeight.w700,
                          color: tokens.text,
                        ),
                        children: [
                          TextSpan(text: title),
                          if (focus.isNotEmpty) ...[
                            TextSpan(
                              text: ' · $focus',
                              style: WorkoutType.display(
                                size: 22,
                                weight: FontWeight.w600,
                                color: tokens.faint,
                              ),
                            ),
                          ],
                        ],
                      ),
                      maxLines: 3,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),

                    Text(
                      session.date,
                      style: WorkoutType.mono(size: 11, color: tokens.faint),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── Stat tiles ───────────────────────────────────────────
              StaggeredEntrance(
                index: 1,
                child: _StatTiles(
                  durationMin: durationMin,
                  totalSets: _totalSets,
                  volumeKg: _coverage.unavailable
                      ? null
                      : _coverage.knownSubtotal,
                  prCount: _prCount,
                  unit: unit,
                  tokens: tokens,
                ),
              ),
              if (!_coverage.complete)
                Text(
                  l.alkionKnownSubtotal(_coverage.known, _coverage.total),
                  style: WorkoutType.mono(size: 10, color: tokens.faint),
                ),
              const SizedBox(height: 28),

              // ── Top sets list ────────────────────────────────────────
              if (blocks.isNotEmpty)
                StaggeredEntrance(
                  index: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l.summaryTopSets,
                        style: WorkoutType.mono(
                          size: 10,
                          weight: FontWeight.w600,
                          color: tokens.faint,
                          letterSpacing: 0.08 * 10,
                        ),
                      ),
                      const SizedBox(height: 10),
                      for (final block in blocks)
                        _TopSetRow(
                          block: block,
                          name:
                              exerciseNames[block.exerciseId] ??
                              block.exerciseId,
                          unit: unit,
                          tokens: tokens,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 32),

              // ── Done button ──────────────────────────────────────────
              StaggeredEntrance(
                index: 3,
                child: GestureDetector(
                  onTap: onDone,
                  child: Container(
                    height: 52,
                    decoration: BoxDecoration(
                      color: tokens.accent,
                      borderRadius: BorderRadius.circular(AppRadius.radius),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      l.commonDone,
                      style: WorkoutType.display(
                        size: 16,
                        weight: FontWeight.w700,
                        color: tokens.accentInk,
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

// ── Success header flash ──────────────────────────────────────────────────────

/// Wraps the success icon and fades a one-shot accent glow out around it on
/// first mount.
class _SuccessHeaderFlash extends StatefulWidget {
  const _SuccessHeaderFlash({required this.tokens, required this.child});

  final WorkoutTokens tokens;
  final Widget child;

  @override
  State<_SuccessHeaderFlash> createState() => _SuccessHeaderFlashState();
}

class _SuccessHeaderFlashState extends State<_SuccessHeaderFlash> {
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return widget.child;
    }
    // Tween 1.0 → 0.0: glow strength fades out over 500ms on mount.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: 0.0),
      duration: const Duration(milliseconds: 500),
      child: widget.child,
      builder: (context, t, child) {
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.tokens.accent.withValues(alpha: 0.7 * t),
                blurRadius: 28 * t,
                spreadRadius: 6 * t,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }
}

// ── Stat tiles ────────────────────────────────────────────────────────────────

class _StatTiles extends StatelessWidget {
  const _StatTiles({
    required this.durationMin,
    required this.totalSets,
    required this.volumeKg,
    required this.prCount,
    required this.unit,
    required this.tokens,
  });

  final int? durationMin;
  final int totalSets;
  final double? volumeKg;
  final int prCount;
  final UnitService unit;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: CountUp(
            value: durationMin ?? 0,
            builder: (v) => _TileInner(
              label: l.summaryDuration,
              value: durationMin == null ? '—' : '${v}m',
              tokens: tokens,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: CountUp(
            value: totalSets,
            builder: (v) =>
                _TileInner(label: l.summarySets, value: '$v', tokens: tokens),
          ),
        ),
        const SizedBox(width: 12),
        _Tile(
          label: l.summaryVolume,
          value: volumeKg == null ? '—' : unit.fmtVol(volumeKg!),
          tokens: tokens,
        ),
        const SizedBox(width: 12),
        // PR count ticks up from 0 on mount.
        Expanded(
          child: CountUp(
            value: prCount,
            builder: (v) => _TileInner(
              label: l.summaryPrs,
              value: '$v',
              tokens: tokens,
              highlight: prCount > 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.tokens});

  final String label;
  final String value;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: _TileInner(label: label, value: value, tokens: tokens),
    );
  }
}

/// The tile card content without the [Expanded] wrapper, so it can be reused
/// inside an animated builder.
class _TileInner extends StatelessWidget {
  const _TileInner({
    required this.label,
    required this.value,
    required this.tokens,
    this.highlight = false,
  });

  final String label;
  final String value;
  final WorkoutTokens tokens;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(AppRadius.radius * 0.7),
        border: Border.all(color: tokens.line),
      ),
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              softWrap: false,
              style: WorkoutType.display(
                size: 20,
                weight: FontWeight.w700,
                color: highlight ? tokens.accentText : tokens.text,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 2),
          FitLabel(
            label,
            textAlign: TextAlign.center,
            style: WorkoutType.mono(size: 9.5, color: tokens.faint),
          ),
        ],
      ),
    );
  }
}

// ── Top set row ───────────────────────────────────────────────────────────────

class _TopSetRow extends StatelessWidget {
  const _TopSetRow({
    required this.block,
    required this.name,
    required this.unit,
    required this.tokens,
  });

  final ExerciseBlockData block;
  final String name;
  final UnitService unit;
  final WorkoutTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(AppRadius.radius * 0.7),
        border: Border.all(color: tokens.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: FitLabel(
              name,
              maxLines: 2,
              style: WorkoutType.body(
                size: 14,
                weight: FontWeight.w600,
                color: tokens.text,
              ),
            ),
          ),
          const SizedBox(width: 12),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: block.coverage.complete
                      ? unit.fmtWt(block.topWeight)
                      : '—',
                  style: WorkoutType.mono(
                    size: 14,
                    weight: FontWeight.w700,
                    color: tokens.text,
                  ),
                ),
                TextSpan(
                  text: unit.uLabel,
                  style: WorkoutType.mono(size: 10, color: tokens.faint),
                ),
                TextSpan(
                  text: block.coverage.complete
                      ? ' × ${block.topReps}'
                      : ' × —',
                  style: WorkoutType.mono(size: 13, color: tokens.dim),
                ),
              ],
            ),
          ),
          if (block.isPr) ...[
            const SizedBox(width: 8),
            const PRBadge(small: true),
          ] else ...[
            const SizedBox(width: 8),
            Tag(
              label: AppLocalizations.of(context).sessionTagTop,
              tone: TagTone.solid,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Error state ───────────────────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.error,
    required this.doneLabel,
    required this.tokens,
    required this.onDone,
  });

  final String error;
  final String doneLabel;
  final WorkoutTokens tokens;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: tokens.danger),
            const SizedBox(height: 16),
            Text(
              error,
              style: WorkoutType.body(size: 14, color: tokens.dim),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: onDone,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 32),
                decoration: BoxDecoration(
                  color: tokens.accent,
                  borderRadius: BorderRadius.circular(AppRadius.radius),
                ),
                alignment: Alignment.center,
                child: Text(
                  doneLabel,
                  style: WorkoutType.mono(
                    size: 14,
                    weight: FontWeight.w700,
                    color: tokens.accentInk,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
