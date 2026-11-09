import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Installs the error card in release builds only. A debug or profile build
/// keeps Flutter's own red error screen, which shows the error directly.
/// `main()` calls this before anything else, so an exception during startup
/// is covered too.
void installReleaseErrorSurface({bool release = kReleaseMode}) {
  if (release) installErrorSurface();
}

/// Replaces Flutter's default release ErrorWidget — a featureless gray box —
/// with a card that says something went wrong and copies the full details on
/// tap.
void installErrorSurface() {
  ErrorWidget.builder = _buildErrorCard;
}

/// The card's words, read from the platform locale: the card cannot rely on
/// AppLocalizations (see [_ErrorCard]).
typedef _CardText = ({String title, String hint, String copied});

const _cardText = <String, _CardText>{
  'en': (
    title: 'Something went wrong on this screen',
    hint: 'Tap to copy the error details',
    copied: 'Copied',
  ),
  'it': (
    title: 'Qualcosa è andato storto in questa schermata',
    hint: 'Tocca per copiare i dettagli dell’errore',
    copied: 'Copiato',
  ),
  'de': (
    title: 'Auf diesem Bildschirm ist etwas schiefgelaufen',
    hint: 'Tippe, um die Fehlerdetails zu kopieren',
    copied: 'Kopiert',
  ),
  'es': (
    title: 'Algo ha salido mal en esta pantalla',
    hint: 'Toca para copiar los detalles del error',
    copied: 'Copiado',
  ),
};

_CardText _textFor(Locale locale) =>
    _cardText[locale.languageCode] ?? _cardText['en']!;

Widget _buildErrorCard(FlutterErrorDetails details) {
  final message = details.exceptionAsString();
  final stack = details.stack?.toString() ?? '';
  return _ErrorCard(
    copyText: stack.isEmpty ? message : '$message\n\n$stack',
    // The binding's dispatcher is PlatformDispatcher.instance in the app.
    text: _textFor(WidgetsBinding.instance.platformDispatcher.locale),
  );
}

/// The replacement error card.
///
/// The card is deliberately dependency-free. An ErrorWidget can be inflated
/// ABOVE MaterialApp, so there may be no Theme, Directionality, MediaQuery or
/// localizations in scope: it supplies its own Directionality, hardcodes its
/// colours, and uses no design tokens, no AppLocalizations and no Scaffold. Its
/// text wraps and scrolls so it cannot overflow inside a tightly constrained
/// sliver child. If this widget threw, the user would see nothing at all —
/// which is worse than the gray box it replaces.
///
/// It shows a generic title; the raw error and stack, which can name files,
/// are never drawn and only reach the clipboard on an explicit tap.
class _ErrorCard extends StatefulWidget {
  const _ErrorCard({required this.copyText, required this.text});

  final String copyText;
  final _CardText text;

  @override
  State<_ErrorCard> createState() => _ErrorCardState();
}

class _ErrorCardState extends State<_ErrorCard> {
  bool _copied = false;
  Timer? _reset;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.copyText));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final hint = _copied ? text.copied : text.hint;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Semantics(
        button: true,
        label: '${text.title}. $hint',
        excludeSemantics: true,
        onTap: _copy,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _copy,
          child: Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF2A1416),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    text.title,
                    softWrap: true,
                    style: const TextStyle(
                      color: Color(0xFFFFB4AB),
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hint,
                    softWrap: true,
                    style: const TextStyle(
                      color: Color(0xFFD9A5A0),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
