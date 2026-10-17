import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// A segmented RIR (Reps In Reserve) picker for values 0–5 ([rirMin] to
/// [rirMax]).
///
/// Selected segment = neutral action background and its contrasting text.
/// Unselected = surface background + dim text. A value outside the range
/// (old free-text data, a restore) selects nothing and is never rewritten.
///
/// One row of six when each chip's slot is at least 48dp wide, otherwise two
/// rows of three with a 3dp gap between them: rows stay balanced, never 5+1.
/// The slots tile each row, a slot being maxWidth/6 wide in one row and
/// maxWidth/3 in two, so at the default [height] a picker at least 144dp
/// wide always gets slots of at least 48×48dp.
///
/// Hosts leave out the RIR row entirely for warm-up sets; the picker has no
/// disabled state.
///
/// Button keys: `rir-<n>` (e.g. `rir-0`, `rir-1`, ...).
///
/// Taps do NOT bubble to enclosing widgets: each chip is a [GestureDetector]
/// with [HitTestBehavior.opaque], and the picker itself absorbs taps that
/// land between chips, so a tap in the row gap never reaches a host's own
/// tap (the live `SetLine` would turn the logged set back into the live card).
///
/// Visual spec: `docs/design_handoff_workout_tracker/design/app/screen-log.jsx`
/// `RirPicker`.
class RirPicker extends StatelessWidget {
  const RirPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.height = 48,
  });

  /// Currently selected RIR value (0–5), or null for no selection.
  final int? value;

  final ValueChanged<int> onChanged;

  /// Chip height. Defaults to 48, the height every host uses.
  final double height;

  static const double _minSlot = 48;
  static const double _gap = 3;
  static const int _count = rirMax - rirMin + 1;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    Widget chip(int r, {required bool lastInRow}) {
      final selected = value == r;
      return Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          key: Key('rir-$r'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.lightImpact();
            onChanged(r);
          },
          child: Container(
            height: height,
            margin: EdgeInsets.only(right: lastInRow ? 0 : _gap),
            decoration: BoxDecoration(
              color: selected ? tokens.action : tokens.surface2,
              border: Border.all(
                color: selected ? tokens.action : tokens.lineStrong,
              ),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            alignment: Alignment.center,
            child: Text(
              '$r',
              style: WorkoutType.mono(
                size: 12,
                weight: FontWeight.w700,
                color: selected ? tokens.onAction : tokens.dim,
              ),
            ),
          ),
        ),
      );
    }

    Widget row(int first, int last) => Row(
      children: [
        for (var r = first; r <= last; r++)
          Expanded(child: chip(r, lastInRow: r == last)),
      ],
    );

    // The absorber must stay out of the semantics tree: no extra tap node.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: () {},
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth / _count >= _minSlot) return row(rirMin, rirMax);
          final split = rirMin + (_count + 1) ~/ 2;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row(rirMin, split - 1),
              const SizedBox(height: _gap),
              row(split, rirMax),
            ],
          );
        },
      ),
    );
  }
}
