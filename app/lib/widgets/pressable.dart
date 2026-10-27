import 'package:flutter/widgets.dart';

/// Compatibility wrapper for callers of the former press-scale feedback.
/// The accepted controls stay fixed under touch and keep native ink feedback.
class PressableScale extends StatelessWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.pressedScale = 0.98,
  });

  final Widget child;
  final double pressedScale;

  @override
  Widget build(BuildContext context) => child;
}
