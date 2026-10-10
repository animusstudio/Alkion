import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../capture/preference_writes.dart';
import 'unit_format.dart';

/// Weight unit the user has selected. Everything is stored internally in kg;
/// this service converts at the view layer only.
enum Unit { kg, lb }

/// Reactive unit service backed by shared_preferences.
class UnitService extends ChangeNotifier {
  Unit _unit = Unit.kg;

  Unit get unit => _unit;

  /// lb conversion factor: 1 kg = 2.2046226 lb.
  static const double lbFactor = 2.2046226;

  /// Read the persisted unit preference. Defaults to kg.
  /// Call once at startup before providing the service.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('unit');
    _unit = stored == Unit.lb.name ? Unit.lb : Unit.kg;
    notifyListeners();
  }

  /// Switch the active unit and persist. Notifies listeners only when changed.
  ///
  /// The write runs in the background, after any earlier unit write, as one
  /// admitted source operation; [flushPersistence] awaits it and reports its
  /// failure. A write refused because a data capture holds the source
  /// changes nothing on disk, and the shown unit goes back to the stored one.
  /// Choosing the shown unit again after its write failed retries the write.
  void setUnit(Unit u) {
    if (u == _unit && _lastError == null) return;
    final previous = _unit;
    _unit = u;
    final write = _persisted.then((_) => writePreferences(
        'prefs.unit', (prefs) => prefs.setString('unit', u.name)));
    _persisted = write.then((_) {
      _lastError = null;
    }, onError: (Object e, StackTrace st) {
      if (isAdmissionRefusal(e)) {
        // Nothing was written: show the stored unit again.
        _lastError = null;
        if (_unit == u) {
          _unit = previous;
          notifyListeners();
        }
        return;
      }
      _lastError = (e, st);
    });
    notifyListeners();
  }

  /// Completes once every unit write started so far has finished. Throws
  /// the error of the latest write if it failed (a refused write that was
  /// undone is not an error); never completes before that write is durable.
  Future<void> flushPersistence() async {
    var pending = _persisted;
    while (true) {
      await pending;
      // A change made while waiting is part of this flush.
      if (identical(pending, _persisted)) break;
      pending = _persisted;
    }
    final error = _lastError;
    if (error != null) Error.throwWithStackTrace(error.$1, error.$2);
  }

  Future<void> _persisted = Future.value();
  (Object, StackTrace)? _lastError;

  /// Convert a kg value to the given [unit].
  static double fromKg(double kg, Unit unit) =>
      unit == Unit.lb ? kg * lbFactor : kg;

  /// Convert a value in the given [unit] back to kg.
  static double toKg(double v, Unit unit) =>
      unit == Unit.lb ? v / lbFactor : v;

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
