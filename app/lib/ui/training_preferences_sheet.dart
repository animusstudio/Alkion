import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../settings/settings_service.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../widgets/fit_label.dart';
import '../theme/typography.dart';
import '../widgets/plan_form.dart';
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
  builder: (_) => TrainingPreferencesSheet(settings: settings),
);

class TrainingPreferencesSheet extends StatefulWidget {
  const TrainingPreferencesSheet({super.key, required this.settings});
  final SettingsService settings;
  @override
  State<TrainingPreferencesSheet> createState() =>
      _TrainingPreferencesSheetState();
}

class _TrainingPreferencesSheetState extends State<TrainingPreferencesSheet> {
  bool _saving = false;
  Object? _error;
  Future<void> _write(Future<void> Function() write) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await write();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
                  items: RepEntry.values,
                  selected: widget.settings.repEntry,
                  labelOf: (v) => v == RepEntry.fixed
                      ? l.trainingFixedReps
                      : l.trainingRepRange,
                  onSelect: (v) {
                    if (!_saving && _error == null) {
                      _write(() => widget.settings.setRepEntry(v));
                    }
                  },
                ),
              ),
              Field(
                label: l.trainingRirControls,
                child: ChipSelect<RirControls>(
                  items: RirControls.values,
                  selected: widget.settings.rirControls,
                  labelOf: (v) =>
                      v == RirControls.off ? l.trainingRirOff : l.trainingShow,
                  onSelect: (v) {
                    if (!_saving && _error == null) {
                      _write(() => widget.settings.setRirControls(v));
                    }
                  },
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
