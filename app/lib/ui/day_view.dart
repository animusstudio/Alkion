import 'package:flutter/material.dart';

import '../data/models.dart';

/// Read-only overview of one training day (see the training day view plan).
///
/// Interface stub so navigation (T3) and the screen (T2) can be built in
/// parallel; T2 replaces the body.
class DayView extends StatefulWidget {
  const DayView({
    super.key,
    required this.id,
    required this.onEdit,
    required this.onClose,
    this.onStart,
  });

  /// The day template id.
  final String id;

  /// Opens the editor for this day.
  final VoidCallback onEdit;

  /// Leaves the view (Back), or reacts to the day no longer existing.
  final VoidCallback onClose;

  /// Starts (or resumes) a workout from this day; null hides Start.
  final ValueChanged<DayTemplate>? onStart;

  @override
  State<DayView> createState() => _DayViewState();
}

class _DayViewState extends State<DayView> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
