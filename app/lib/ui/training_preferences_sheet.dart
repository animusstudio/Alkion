import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../widgets/fit_label.dart';
import '../theme/typography.dart';
import '../widgets/plan_form.dart';
import '../widgets/stepper.dart';
import '../widgets/pending_input.dart';
import '../widgets/prescription_controls.dart';

Future<void> showTrainingPreferencesSheet(
  BuildContext context,
  SettingsService settings,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: context.tokens.surface,
  barrierColor: context.tokens.overlay,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
  ),
  sheetAnimationStyle: AnimationStyle(
    duration: Motion.of(context, Motion.base),
    reverseDuration: Motion.of(context, Motion.fast),
  ),
  builder: (_) => ListenableBuilder(
    listenable: settings,
    builder: (_, _) => TrainingPreferencesSheet(settings: settings),
  ),
);

class TrainingPreferencesSheet extends StatefulWidget {
  const TrainingPreferencesSheet({super.key, required this.settings});
  final SettingsService settings;
  @override
  State<TrainingPreferencesSheet> createState() =>
      _TrainingPreferencesSheetState();
}

class _TrainingPreferencesSheetState extends State<TrainingPreferencesSheet> {
  /// The longest rest either global default can be set to, in seconds.
  static const maxRestSeconds = 900;

  /// Writes started and not yet settled. [SettingsService] queues every
  /// change in order, so a tap while an earlier write is running is kept,
  /// not dropped.
  int _writes = 0;
  Object? _error;
  bool get _saving => _writes > 0;

  void _write(Future<void> Function() write) {
    setState(() => _writes++);
    Future<void> started;
    try {
      started = write();
    } catch (e) {
      started = Future<void>.error(e);
    }
    started
        .then(
          (_) {
            // A later write landing means every earlier queued one landed too.
            if (mounted) setState(() => _error = null);
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = e);
          },
        )
        .whenComplete(() {
          _writes--;
          if (mounted) setState(() {});
        });
  }

  Widget _restStepper(
    String label,
    int seconds,
    Future<void> Function(int) save,
  ) {
    final l = AppLocalizations.of(context);
    final blocked = _error != null;
    return AbsorbPointer(
      absorbing: blocked,
      child: ExcludeFocus(
        excluding: blocked,
        child: Opacity(
          opacity: blocked ? .5 : 1,
          child: WStepper(
            value: seconds.toDouble(),
            step: 15,
            format: (v) => l.exerciseEditorRestSeconds(v.round()),
            formatForEdit: (v) => v.round().toString(),
            min: 0,
            max: maxRestSeconds.toDouble(),
            allowDecimal: false,
            editable: !blocked,
            semanticLabel: label,
            onChanged: (v) {
              if (_error != null) return;
              _write(() => save(v.round()));
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FitLabel(
                l.trainingPreferences,
                maxLines: 2,
                style: WorkoutType.display(
                  size: 22,
                  color: context.tokens.text,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l.trainingPreferencesHint,
                style: WorkoutType.body(color: context.tokens.dim),
              ),
              const SizedBox(height: 24),
              Field(
                label: l.trainingRepEntry,
                child: ChipSelect<RepEntry>(
                  enabled: !_saving && _error == null,
                  items: RepEntry.values,
                  selected: widget.settings.repEntry,
                  labelOf: (v) => v == RepEntry.fixed
                      ? l.trainingFixedReps
                      : l.trainingRepRange,
                  onSelect: (v) {
                    if (!_saving && _error == null) {
                      commitPendingInput();
                      _write(() => widget.settings.setRepEntry(v));
                    }
                  },
                ),
              ),
              Field(
                label: l.trainingRirControls,
                child: ChipSelect<RirControls>(
                  enabled: !_saving && _error == null,
                  items: RirControls.values,
                  selected: widget.settings.rirControls,
                  labelOf: (v) =>
                      v == RirControls.off ? l.trainingRirOff : l.trainingShow,
                  onSelect: (v) {
                    if (!_saving && _error == null) {
                      commitPendingInput();
                      _write(() => widget.settings.setRirControls(v));
                    }
                  },
                ),
              ),
              Field(
                label: l.trainingMuscleTargets,
                glitch: true,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AbsorbPointer(
                    absorbing: _saving || _error != null,
                    child: Toggle(
                      enabled: !_saving && _error == null,
                      value: widget.settings.muscleTargetsEnabled,
                      semanticLabel: l.trainingMuscleTargets,
                      onChanged: (value) {
                        if (_saving || _error != null) return;
                        commitPendingInput();
                        _write(
                          () => widget.settings.setMuscleTargetsEnabled(value),
                        );
                      },
                    ),
                  ),
                ),
              ),
              Field(
                label: l.profileCompoundRest,
                child: _restStepper(
                  l.profileCompoundRest,
                  widget.settings.restCompoundSeconds,
                  widget.settings.setRestCompoundSeconds,
                ),
              ),
              Field(
                label: l.profileIsolationRest,
                child: _restStepper(
                  l.profileIsolationRest,
                  widget.settings.restIsolationSeconds,
                  widget.settings.setRestIsolationSeconds,
                ),
              ),
              if (_saving) const LinearProgressIndicator(),
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l.editorSaveFailed,
                    style: WorkoutType.body(color: context.tokens.danger),
                  ),
                ),
                TrainingAction(
                  l.trainingRetry,
                  onTap: () => _write(widget.settings.flushPersistence),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
