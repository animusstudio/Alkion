import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';

/// A modal sheet for typing one exact number (the ruler picker's typed-entry
/// path). Modal on purpose: nothing else on screen can act while the typed
/// value is uncommitted, which rules out the act-while-editing bug class.
///
/// Resolves to [parse] of the typed text, or null when dismissed, when the
/// text is unparseable, or when it is unchanged from [initialText] — the last
/// guards a lossy seed (lb shown as whole pounds) from being written back as
/// if it were a real edit.
Future<double?> showNumberEntrySheet(
  BuildContext context, {
  required String title,
  required String initialText,
  required bool allowDecimal,
  required double? Function(String text) parse,
}) {
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => _NumberEntrySheet(
      title: title,
      initialText: initialText,
      allowDecimal: allowDecimal,
      parse: parse,
    ),
  );
}

class _NumberEntrySheet extends StatefulWidget {
  const _NumberEntrySheet({
    required this.title,
    required this.initialText,
    required this.allowDecimal,
    required this.parse,
  });

  final String title;
  final String initialText;
  final bool allowDecimal;
  final double? Function(String) parse;

  @override
  State<_NumberEntrySheet> createState() => _NumberEntrySheetState();
}

class _NumberEntrySheetState extends State<_NumberEntrySheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialText)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initialText.length,
        );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text;
    Navigator.of(
      context,
    ).pop(text == widget.initialText ? null : widget.parse(text));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(AppRadius.radius),
            border: Border.all(color: tokens.lineStrong),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: WorkoutType.mono(
                  size: 10.5,
                  color: tokens.faint,
                  letterSpacing: 0.08 * 10.5,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      label: widget.title,
                      textField: true,
                      child: TextField(
                        key: const Key('number-entry-field'),
                        controller: _ctrl,
                        autofocus: true,
                        textInputAction: TextInputAction.done,
                        keyboardType: TextInputType.numberWithOptions(
                          decimal: widget.allowDecimal,
                        ),
                        // Whole-string predicate, not an anchored
                        // FilteringTextInputFormatter.allow (that wipes the field
                        // on non-matching input — see app/AGENTS.md).
                        inputFormatters: [
                          TextInputFormatter.withFunction((oldValue, newValue) {
                            final ok = widget.allowDecimal
                                ? RegExp(
                                    r'^\d*[.,]?\d*$',
                                  ).hasMatch(newValue.text)
                                : RegExp(r'^\d*$').hasMatch(newValue.text);
                            return ok ? newValue : oldValue;
                          }),
                        ],
                        onSubmitted: (_) => _submit(),
                        style:
                            WorkoutType.display(
                              size: 30,
                              weight: FontWeight.w700,
                              color: tokens.text,
                            ).copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Semantics(
                    button: true,
                    child: GestureDetector(
                      key: const Key('number-entry-done'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _submit,
                      child: Container(
                        height: 48,
                        constraints: const BoxConstraints(minWidth: 72),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: tokens.accent,
                          borderRadius: BorderRadius.circular(
                            AppRadius.radius * 0.6,
                          ),
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            l.commonDone,
                            style: WorkoutType.body(
                              size: 15,
                              weight: FontWeight.w700,
                              color: tokens.accentInk,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
