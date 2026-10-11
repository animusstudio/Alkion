import 'dart:async';

import 'package:flutter/material.dart';

import '../capture/session_capture_hooks.dart';
import '../data/day_template_repository.dart';
import '../l10n/app_localizations.dart';
import '../sync/db.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/pending_input.dart';
import '../widgets/pressable.dart';
import '../widgets/w_dialog.dart';
import 'day_editor.dart';
import 'editor_guard.dart';
import 'exercise_editor.dart';
import 'exercise_library_tab.dart';
import 'split_tab.dart';
import 'targets_tab.dart';

// ── Editor-route state ────────────────────────────────────────────────────

/// Describes which in-place editor is currently open.
/// [kind] is `'day'` or `'exercise'`; [id] is the row id (null = new).
/// Built fresh for every open, so an editor still fading out can never
/// answer for, or close, the one that replaced it.
class _EditorRoute {
  _EditorRoute({required this.kind, required this.id});
  final String kind; // 'day' | 'exercise'
  final String? id;

  /// Bound by this route's editor to report unsaved edits.
  final EditorGuard guard = EditorGuard();
}

/// The Plan header's eyebrow: "N training days", or empty while the day
/// count ([dayCount] null) hasn't arrived — never a transient "0".
String planEyebrow(AppLocalizations l, int? dayCount) =>
    dayCount == null ? '' : l.planDaysEyebrow(dayCount);

// ── PlanScreen ────────────────────────────────────────────────────────────

/// The Plan tab: a header + Split|Exercises segmented toggle + in-place
/// editor routing — all within the one IndexedStack slot (no root Navigator
/// push).
///
/// Body routing via [_editor]:
///   - null              → list level: shows SplitTab or LibraryTab
///   - kind=='day'       → DayEditor
///   - kind=='exercise'  → ExerciseEditor
///
/// [_activeTab] tracks 'split' | 'exercises' while at the list level.
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});

  @override
  State<PlanScreen> createState() => PlanScreenState();
}

class PlanScreenState extends State<PlanScreen> {
  /// Currently open in-place editor (null = list view).
  _EditorRoute? _editor;

  /// Active sub-tab while at the list level.
  String _activeTab = 'split';

  // The header's eyebrow needs the day count regardless of which sub-tab is
  // active, so it watches the same repository stream SplitTab does rather
  // than being fed one by SplitTab (which isn't even mounted on Exercises or
  // Targets). Cached once here, not created in build.
  late final DayTemplateRepository _dayRepo = DayTemplateRepository(db);
  late final Stream<int> _dayCountStream =
      _dayRepo.watchDays().map((days) => days.length);

  /// True while [requestClose] runs: a second call is refused rather than
  /// stacking a second prompt.
  bool _closing = false;

  /// An open editor with unsaved edits holds off a data capture: its edits
  /// are settled only by Save or by discarding them, never automatically.
  Object? _unsavedForm;

  @override
  void initState() {
    super.initState();
    _unsavedForm =
        UnsavedEditors.instance.register('plan', () => hasUnsavedEdits);
  }

  @override
  void dispose() {
    final form = _unsavedForm;
    if (form != null) UnsavedEditors.instance.unregister(form);
    super.dispose();
  }

  /// Opens an editor. Ignored while one is open: the list can then only be
  /// reached by a tap that fell through to the outgoing list while the new
  /// editor was still loading.
  void _openEditor(String kind, String? id) {
    if (_editor != null) return;
    setState(() => _editor = _EditorRoute(kind: kind, id: id));
  }

  /// Closes [route]'s editor if it is still the open one, so a late Save or
  /// Delete never closes an editor opened since.
  void _closeEditor(_EditorRoute route) {
    if (!identical(_editor, route)) return;
    setState(() => _editor = null);
  }

  /// Whether the open editor would lose edits if closed now.
  bool get hasUnsavedEdits => _editor?.guard.isDirty() ?? false;

  /// Closes the open editor, asking first if it holds unsaved edits.
  /// Returns true if the editor closed.
  Future<bool> requestClose() async {
    final route = _editor;
    if (route == null || _closing) return false;
    _closing = true;
    try {
      // A typed value still in a focused stepper counts as an edit.
      commitPendingInput();
      if (route.guard.isDirty()) {
        final l = AppLocalizations.of(context);
        final discard = await showWConfirm(
          context,
          title: l.planDiscardTitle,
          message: route.kind == 'day'
              ? l.planDiscardDayMessage
              : l.planDiscardExerciseMessage,
          cancelLabel: l.commonKeepEditing,
          confirmLabel: l.commonDiscard,
          destructive: true,
        );
        // Keep editing, a dismissed dialog, or an editor that changed or
        // closed meanwhile: leave everything as it is.
        if (discard != true || !mounted || !identical(_editor, route)) {
          return false;
        }
      }
      _closeEditor(route);
      return true;
    } finally {
      _closing = false;
    }
  }

  /// Consumes a back press when the in-tab editor is open. Returns true if
  /// handled; the editor then closes, or asks first, on its own.
  bool handleBack() {
    if (_editor == null) return false;
    unawaited(requestClose());
    return true;
  }

  // ── Derived title ─────────────────────────────────────────────────────────

  String _titleOf(AppLocalizations l) {
    if (_editor == null) return l.planTitle;
    if (_editor!.kind == 'day') {
      return _editor!.id != null ? l.planEditDay : l.planNewDay;
    }
    return _editor!.id != null ? l.planEditExercise : l.planNewExercise;
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, WorkoutTokens tokens) {
    final l = AppLocalizations.of(context);
    final topPad = MediaQuery.paddingOf(context).top;

    return Container(
      color: tokens.bg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // Stretch, or the min-width title block is centred instead of sitting
        // left like History's and Progress's headers.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top safe-area + title block
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8 + topPad, 16, 12),
            child: _editor != null
                ? Row(
                    children: [
                      _BackButton(
                        tokens: tokens,
                        onBack: () => unawaited(requestClose()),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _titleOf(l),
                          style: WorkoutType.display(
                            size: 19,
                            weight: FontWeight.w700,
                            color: tokens.text,
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StreamBuilder<int>(
                        stream: _dayCountStream,
                        builder: (context, snap) => Text(
                          planEyebrow(l, snap.data),
                          style: WorkoutType.mono(
                            size: 11.5,
                            color: tokens.faint,
                            letterSpacing: 0.06 * 11.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        l.planTitle,
                        style: WorkoutType.display(
                          size: 28,
                          weight: FontWeight.w700,
                          color: tokens.text,
                          letterSpacing: 28 * -0.02,
                        ),
                      ),
                    ],
                  ),
          ),

          // Segmented toggle — shown only at list level
          if (_editor == null)
            _SegmentedToggle(
              activeTab: _activeTab,
              tokens: tokens,
              onSelect: (tab) => setState(() => _activeTab = tab),
            ),

          // Bottom border
          Divider(height: 1, thickness: 1, color: tokens.line),
        ],
      ),
    );
  }

  // ── Body ──────────────────────────────────────────────────────────────────

  Widget _buildBody() {
    final Widget body;
    final editor = _editor;
    if (editor != null) {
      if (editor.kind == 'day') {
        body = DayEditor(
          id: editor.id,
          onBack: () => _closeEditor(editor),
          guard: editor.guard,
        );
      } else {
        body = ExerciseEditor(
          id: editor.id,
          onBack: () => _closeEditor(editor),
          guard: editor.guard,
        );
      }
    } else if (_activeTab == 'split') {
      body = SplitTab(onOpenEditor: (id) => _openEditor('day', id));
    } else if (_activeTab == 'targets') {
      body = const TargetsTab();
    } else {
      body = LibraryTab(onOpenEditor: (id) => _openEditor('exercise', id));
    }

    return AnimatedSwitcher(
      duration: Motion.of(context, const Duration(milliseconds: 220)),
      switchInCurve: Motion.curve,
      switchOutCurve: Motion.curve,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(anim),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey(
          _editor == null ? 'list-$_activeTab' : 'editor-${_editor!.kind}-${_editor!.id}',
        ),
        child: body,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ColoredBox(
      color: tokens.bg,
      child: Column(
        children: [
          _buildHeader(context, tokens),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────

class _BackButton extends StatelessWidget {
  const _BackButton({required this.tokens, required this.onBack});
  final WorkoutTokens tokens;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label: l.commonBack,
      excludeSemantics: true,
      onTap: onBack,
      child: GestureDetector(
        onTap: onBack,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: tokens.line),
                color: tokens.surface,
              ),
              child: Transform.rotate(
                angle: 3.14159, // 180° = point left
                child: Icon(WIcons.chevron, size: 18, color: tokens.dim),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SegmentedToggle extends StatelessWidget {
  const _SegmentedToggle({
    required this.activeTab,
    required this.tokens,
    required this.onSelect,
  });

  final String activeTab;
  final WorkoutTokens tokens;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          _SegBtn(
            label: l.planTabSplit,
            active: activeTab == 'split',
            tokens: tokens,
            onTap: () => onSelect('split'),
          ),
          const SizedBox(width: 6),
          _SegBtn(
            label: l.planTabExercises,
            active: activeTab == 'exercises',
            tokens: tokens,
            onTap: () => onSelect('exercises'),
          ),
          const SizedBox(width: 6),
          _SegBtn(
            label: l.planTabTargets,
            active: activeTab == 'targets',
            tokens: tokens,
            onTap: () => onSelect('targets'),
          ),
        ],
      ),
    );
  }
}

class _SegBtn extends StatelessWidget {
  const _SegBtn({
    required this.label,
    required this.active,
    required this.tokens,
    required this.onTap,
  });

  final String label;
  final bool active;
  final WorkoutTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: PressableScale(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                // 36 tall at 1.0×; grows with a large text size.
                constraints: const BoxConstraints(minHeight: 36),
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(36 * 0.6),
                  color: active ? tokens.surface3 : Colors.transparent,
                  border: Border.all(
                      color: active ? tokens.lineStrong : tokens.line),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: tokens.lineStrong,
                            blurRadius: 0,
                            spreadRadius: 0,
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: FitLabel(
                  label,
                  textAlign: TextAlign.center,
                  style: WorkoutType.mono(
                    size: 12.5,
                    weight: FontWeight.w700,
                    color: active ? tokens.text : tokens.faint,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
