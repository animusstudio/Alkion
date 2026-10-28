import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'fit_label.dart';

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
    barrierColor: context.tokens.overlay,
    useSafeArea: true,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
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
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(AppRadius.sheet),
            border: Border.all(color: tokens.lineStrong),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FitLabel(
                widget.title,
                maxLines: 2,
                style: WorkoutType.display(
                  size: 22,
                  weight: FontWeight.w500,
                  color: tokens.text,
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
                            WorkoutType.mono(
                              size: 28,
                              weight: FontWeight.w400,
                              color: tokens.text,
                            ).copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: tokens.sunken,
                          constraints: const BoxConstraints(minHeight: 48),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                            borderSide: BorderSide(color: tokens.lineStrong),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AppRadius.control,
                            ),
                            borderSide: BorderSide(
                              color: tokens.focus,
                              width: 2,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    key: const Key('number-entry-done'),
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(72, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      backgroundColor: tokens.action,
                      foregroundColor: tokens.onAction,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                    ),
                    child: Text(
                      l.commonDone,
                      style: WorkoutType.body(
                        size: 14,
                        weight: FontWeight.w500,
                        color: tokens.onAction,
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
