import 'package:flutter/foundation.dart';
import '../store/local_store.dart';
import '../settings/settings_service.dart';
import 'unit_format.dart';

enum Unit { kg, lb }

/// Unbound instances are display-only; durable use requires explicit local binding.
class UnitService extends ChangeNotifier {
  UnitService() : _preferences = null;
  UnitService.local(LocalDatabase database)
    : _preferences = LocalPreferences(database, 'units');
  final LocalPreferences? _preferences;
  Unit _unit = Unit.kg;
  Unit get unit => _unit;
  static const double lbFactor = 2.2046226;
  Future<void> load() async {
    final p = _preferences;
    if (p == null) return;
    _unit = (await p.load())['unit'] == 'lb' ? Unit.lb : Unit.kg;
    notifyListeners();
  }

  bool _unboundOwed = false;

  /// Switches the display unit at once and persists it. The returned write
  /// may fail (the store needs recovery); a caller that does not await it
  /// still leaves it owed, so the next change or flush retries it.
  Future<void> setUnit(Unit u) {
    _unit = u;
    final p = _preferences;
    final Future<void> write;
    if (p == null) {
      _unboundOwed = true;
      write = Future<void>.error(const StoreException('unbound_preferences'));
    } else {
      write = p.save({'unit': u.name});
    }
    // Handled here so a caller that ignores it raises no unhandled error;
    // callers that listen still receive the failure.
    write.ignore();
    notifyListeners();
    return write;
  }

  Future<void> flushPersistence() async {
    if (_unboundOwed) throw const StoreException('unbound_preferences');
    await _preferences?.flushPersistence();
  }

  /// Convert a kg value to the given [unit].
  static double fromKg(double kg, Unit unit) =>
      unit == Unit.lb ? kg * lbFactor : kg;

  /// Convert a value in the given [unit] back to kg.
  static double toKg(double v, Unit unit) => unit == Unit.lb ? v / lbFactor : v;

  /// Format a weight in kg for display in the current unit.
  ///
  /// kg:  integer values shown bare ("80"), non-integer up to 2 dp ("72.25").
  /// lb:  converted and rounded to whole number ("220").
  String fmtWt(double kg) => fmtDisplay(fromKg(kg, _unit), _unit);

  /// Format a value already in [unit] for display: kg up to two decimals
  /// (trailing zeros trimmed), lb as a whole number. The set-weight rule,
  /// [fmtLoad].
  static String fmtDisplay(double v, Unit unit) => fmtLoad(v, unit);

  /// Format a bodyweight in kg for display in the current unit: one decimal,
  /// ".0" trimmed ([fmtBodyweight]).
  String fmtBw(double kg) => fmtBodyweight(fromKg(kg, _unit));

  /// Format a training volume in kg for display in the current unit
  /// ([fmtVolume]): "850kg", "1.5t", "3.3k lb".
  String fmtVol(double kg) => fmtVolume(kg, _unit);

  /// The current unit label ("kg" or "lb").
  String get uLabel => _unit == Unit.lb ? 'lb' : 'kg';
}
