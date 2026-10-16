// One formatter per displayed quantity, plus the rounding that matches each.
//
// Every value here is already in display units except [fmtVolume], which
// takes kg like the tiles that call it. None of them ever groups a value that
// can seed an edit field: `parseNumberInput` reads ',' as the decimal
// separator, so "1,102" would commit 1.102.

import 'unit_service.dart';

/// A set weight already in [unit]: kg up to two decimals with trailing zeros
/// trimmed ("102.5", "60.25", "80"), lb as a whole number ("226").
///
/// The ruler's echo detection and the stepper's untouched-seed check compare
/// these strings, so this rule must not change.
String fmtLoad(double display, Unit unit) {
  if (unit == Unit.lb) {
    return display.round().toString();
  }
  // kg: drop trailing ".0"
  if (display == display.truncateToDouble()) {
    return display.toInt().toString();
  }
  // Up to two decimals (quarter-kilo loads), trailing zeros trimmed.
  return display.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
}

/// A bodyweight already in display units: one decimal, ".0" trimmed
/// ("82.4", "82", "181.7").
String fmtBodyweight(double display) {
  if (display == display.roundToDouble()) return display.toInt().toString();
  final s = display.toStringAsFixed(1);
  if (s.endsWith('.0')) return s.substring(0, s.length - 2);
  return s;
}

/// A training volume of [kg], shown in [unit]: whole under a thousand
/// ("850kg", "850lb"), else in tenths of a thousand with ".0" trimmed
/// ("1t", "1.5t", "3.3k lb", "13k lb").
///
/// The tenths come from integer rounding, never `toStringAsFixed`, which
/// misrounds binary half-cases (1150 would read "1.1t").
String fmtVolume(double kg, Unit unit) {
  final v = UnitService.fromKg(kg, unit).round();
  if (v < 1000) return unit == Unit.lb ? '${v}lb' : '${v}kg';
  // Rounds half away from zero, exact at .5.
  final tenths = (v / 100).round();
  final whole = tenths ~/ 10;
  final n = tenths % 10 == 0 ? '$whole' : '$whole.${tenths % 10}';
  return unit == Unit.lb ? '${n}k lb' : '${n}t';
}

/// A count as a comma-grouped whole number ("1,483", "900"), matching
/// `toLocaleString('en-US')`. Display only: never an edit seed.
String fmtCount(double v) {
  final n = v.round();
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return n < 0 ? '-${buf.toString()}' : buf.toString();
}

// The round helpers return the precision the matching formatter shows, so a
// change computed from them is the change the user reads. The first two parse
// the formatter's own string, which keeps them in step at binary half-cases
// (1.005 kg reads "1"); that string is never empty or grouped.

/// [display] rounded the way [fmtLoad] shows it.
double roundLoad(double display, Unit unit) =>
    double.parse(fmtLoad(display, unit));

/// [display] rounded the way [fmtBodyweight] shows it.
double roundBodyweight(double display) => double.parse(fmtBodyweight(display));

/// [v] rounded the way [fmtCount] shows it. Never parse [fmtCount]'s grouped
/// string.
double roundCount(double v) => v.roundToDouble();
