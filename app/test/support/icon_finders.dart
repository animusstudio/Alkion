import 'package:flutter_test/flutter_test.dart';
import 'package:alkion/theme/alkion_icon.dart';

/// Matches the app's semantic glyph identity independently of SVG internals.
Finder findGlyph(AlkionGlyph glyph) => find.byWidgetPredicate(
  (widget) => widget is AlkionIcon && widget.glyph == glyph,
  description: 'AlkionIcon(${glyph.name})',
);
