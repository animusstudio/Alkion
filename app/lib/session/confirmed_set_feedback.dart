import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../widgets/state_motion.dart';
import 'active_session_controller.dart';

/// Observes the existing save state; never flushes or reschedules persistence.
/// A rejected log has no event. A valid durable log gets its cue only once the
/// draft has no work owed and no error. Slow/failed/background saves stay quiet.
class ConfirmedSetFeedback extends StatefulWidget {
  const ConfirmedSetFeedback({
    super.key,
    required this.controller,
    required this.event,
    required this.loggedSet,
    required this.child,
  });
  final ActiveSessionController controller;
  final int event;
  final SetState? loggedSet;
  final Widget child;
  @override
  State<ConfirmedSetFeedback> createState() => _ConfirmedSetFeedbackState();
}

class _ConfirmedSetFeedbackState extends State<ConfirmedSetFeedback>
    with WidgetsBindingObserver {
  Timer? _poll;
  int _attempts = 0;
  int? _confirmed;
  String? _candidate;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  bool get _visible =>
      _resumed &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.isCurrentOf(context) ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_visible) _poll?.cancel();
  }

  @override
  void didUpdateWidget(ConfirmedSetFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.persistenceError != null ||
        widget.controller.finishPending ||
        widget.controller.callbacksFrozen ||
        (_confirmed != null &&
            (widget.loggedSet == null ||
                !widget.loggedSet!.done ||
                jsonEncode(widget.loggedSet!.toJson()) != _candidate))) {
      _poll?.cancel();
      _confirmed = null;
    }
    if (widget.event != oldWidget.event) {
      _poll?.cancel();
      _confirmed = null;
      _attempts = 0;
      _candidate = widget.loggedSet == null
          ? null
          : jsonEncode(widget.loggedSet!.toJson());
      if (widget.event > 0 && _visible) {
        // Only this short-lived presentation observer polls; the existing
        // debounced autosave keeps its original scheduling and ownership.
        _poll = Timer.periodic(
          const Duration(milliseconds: 120),
          (_) => _check(),
        );
        _check();
      }
    }
  }

  void _check() {
    final c = widget.controller;
    final set = widget.loggedSet;
    if (!_visible ||
        ++_attempts > 40 ||
        c.persistenceError != null ||
        c.callbacksFrozen ||
        c.finishPending ||
        set == null ||
        !set.done ||
        jsonEncode(set.toJson()) != _candidate ||
        !c.draft.blocks.any((block) => block.allSets.contains(set))) {
      _poll?.cancel();
      return;
    }
    if (!c.persistenceOwed) {
      _poll?.cancel();
      if (mounted) setState(() => _confirmed = widget.event);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _poll?.cancel();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SuccessLine(key: const Key('confirmed-set-line'), event: _confirmed),
      widget.child,
    ],
  );

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
