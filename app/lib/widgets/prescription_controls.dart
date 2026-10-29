import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/icons.dart';
import '../theme/typography.dart';
import 'fit_label.dart';
import 'plan_form.dart';
import 'pending_input.dart';
import 'stepper.dart';

/// A disclosure changes presentation only. Data changes belong to its children.
class TrainingDisclosure extends StatelessWidget {
  const TrainingDisclosure({
    super.key,
    required this.label,
    required this.expanded,
    required this.onTap,
    this.hint,
  });
  final String label;
  final String? hint;
  final bool expanded;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    expanded: expanded,
    child: InkWell(
      onTap: onTap == null
          ? null
          : () {
              commitPendingInput();
              onTap!();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FitLabel(
                    label,
                    maxLines: 2,
                    style: WorkoutType.body(
                      size: 15,
                      weight: FontWeight.w500,
                      color: context.tokens.text,
                    ),
                  ),
                  if (hint != null)
                    Text(
                      hint!,
                      style: WorkoutType.body(
                        size: 12,
                        color: context.tokens.dim,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                color: context.tokens.dim,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class TrainingAction extends StatelessWidget {
  const TrainingAction(
    this.label, {
    super.key,
    required this.onTap,
    this.icon = WIcons.plus,
  });
  final String label;
  final VoidCallback? onTap;
  final IconData icon;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    style: TextButton.styleFrom(
      foregroundColor: context.tokens.text,
      minimumSize: const Size(48, 48),
      alignment: Alignment.centerLeft,
    ),
    onPressed: onTap == null
        ? null
        : () {
            commitPendingInput();
            onTap!();
          },
    icon: Icon(icon, size: 18),
    label: FitLabel(
      label,
      maxLines: 3,
      style: WorkoutType.body(color: context.tokens.text),
    ),
  );
}

class RepControls extends StatelessWidget {
  const RepControls({
    super.key,
    required this.low,
    required this.high,
    required this.onChanged,
    required this.currentValues,
    this.enabled = true,
  });
  final int low, high;
  final void Function(int low, int high) onChanged;

  /// Read after pending typing commits, rather than using build-time values.
  final ({int low, int high}) Function() currentValues;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final range = low != high;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Field(
          label: l.trainingRepEntry,
          child: ChipSelect<bool>(
            items: const [false, true],
            selected: range,
            labelOf: (v) => v ? l.trainingRepRange : l.trainingFixedReps,
            onSelect: (v) {
              if (enabled) {
                commitPendingInput();
                final pair = currentValues();
                onChanged(
                  v && pair.low == 99 && pair.high == 99 ? 98 : pair.low,
                  v
                      ? (pair.high > pair.low
                            ? pair.high
                            : (pair.low + 4).clamp(1, 99))
                      : pair.low,
                );
              }
            },
          ),
        ),
        LayoutBuilder(
          builder: (context, box) {
            Widget step(
              String label,
              int value,
              void Function(double) change,
            ) => Field(
              label: label,
              child: WStepper(
                value: value.toDouble(),
                step: 1,
                format: (v) => v.round().toString(),
                onChanged: enabled ? change : (_) {},
                editable: enabled,
                allowDecimal: false,
                min: 1,
                max: 99,
                semanticLabel: label,
              ),
            );
            final a = step(range ? l.dayEditorRepLow : l.trainingReps, low, (
              v,
            ) {
              final n = v.round().clamp(1, 99);
              onChanged(n, range ? (high < n ? n : high) : n);
            });
            if (!range) return a;
            final b = step(l.dayEditorRepHigh, high, (v) {
              final n = v.round().clamp(1, 99);
              onChanged(low > n ? n : low, n);
            });
            if (box.maxWidth < 350 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.3) {
              return Column(children: [a, b]);
            }
            return Row(
              children: [
                Expanded(child: a),
                const SizedBox(width: 12),
                Expanded(child: b),
              ],
            );
          },
        ),
      ],
    );
  }
}
