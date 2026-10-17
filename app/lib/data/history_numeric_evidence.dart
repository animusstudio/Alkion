import 'dart:typed_data';

import '../domain/evidence.dart';

/// The largest magnitude History formats, in the selected unit: 2^53 − 1.
///
/// Rounding to an integer is exact far beyond this, but `fmtVolume` divides
/// the rounded value as a double and the pound conversion multiplies doubles;
/// both are exact only within 2^53. Beyond it a value is unavailable. This is
/// a display policy, not a measured capacity.
final BigInt historyDisplayBound = BigInt.from(9007199254740991);

/// `UnitService.lbFactor` (2.2046226) as an exact ratio.
final BigInt _lbNumerator = BigInt.from(22046226);
const int _lbScale = 7;

/// History's exact value: coefficient × 10^-scale.
///
/// Only the addition, integer multiplication and comparison History needs.
/// A coefficient is never turned into text or a double before the range check.
final class HistoryDecimal implements Comparable<HistoryDecimal> {
  HistoryDecimal._(this.coefficient, this.scale);

  /// The exact value of a retained decimal.
  HistoryDecimal.of(ExactDecimal value)
    : this._(value.coefficient, value.scale);

  static final HistoryDecimal zero = HistoryDecimal._(BigInt.zero, 0);

  /// The exact binary value of [value], or null when it is not finite.
  static HistoryDecimal? ofDouble(double value) {
    if (!value.isFinite) {
      return null;
    }
    final bits = ByteData(8)..setFloat64(0, value);
    final high = bits.getUint32(0), low = bits.getUint32(4);
    final exponent = (high >> 20) & 0x7ff;
    var mantissa = (BigInt.from(high & 0xfffff) << 32) | BigInt.from(low);
    var power = -1074;
    if (exponent != 0) {
      mantissa |= BigInt.one << 52;
      power = exponent - 1075;
    }
    if (high >> 31 == 1) {
      mantissa = -mantissa;
    }
    // mantissa × 2^power; a negative power is mantissa × 5^-power / 10^-power.
    return power >= 0
        ? HistoryDecimal._(mantissa << power, 0)
        : HistoryDecimal._(mantissa * BigInt.from(5).pow(-power), -power);
  }

  final BigInt coefficient;
  final int scale;

  HistoryDecimal operator +(HistoryDecimal other) {
    final common = scale > other.scale ? scale : other.scale;
    return HistoryDecimal._(
      _rescaled(common) + other._rescaled(common),
      common,
    );
  }

  HistoryDecimal times(int factor) =>
      HistoryDecimal._(coefficient * BigInt.from(factor), scale);

  BigInt _rescaled(int to) => coefficient * BigInt.from(10).pow(to - scale);

  @override
  int compareTo(HistoryDecimal other) {
    final common = scale > other.scale ? scale : other.scale;
    return _rescaled(common).compareTo(other._rescaled(common));
  }

  /// Whether this kilogram value, shown in kg or (with [pounds]) in lb, is
  /// within [historyDisplayBound]. Exact: |c| ≤ bound × 10^s in kg, and
  /// |c| × 22046226 ≤ bound × 10^(s + 7) in lb.
  bool withinDisplayRange({bool pounds = false}) {
    final magnitude = coefficient.abs();
    return pounds
        ? magnitude * _lbNumerator <=
              historyDisplayBound * BigInt.from(10).pow(scale + _lbScale)
        : magnitude <= historyDisplayBound * BigInt.from(10).pow(scale);
  }

  /// The nearest double of this kilogram value, for the unchanged formatters.
  /// Null unless the value is within range in the selected unit.
  double? displayKg({bool pounds = false}) {
    if (!withinDisplayRange(pounds: pounds)) {
      return null;
    }
    final digits = coefficient.abs().toString().padLeft(scale + 1, '0');
    final split = digits.length - scale;
    return double.parse(
      '${coefficient.isNegative ? '-' : ''}${digits.substring(0, split)}'
      '${scale == 0 ? '' : '.${digits.substring(split)}'}',
    );
  }
}

/// Whether the kilogram double [kg] is finite and its exact value is within
/// [historyDisplayBound] in kg or, with [pounds], in lb.
bool historyDoubleFits(double kg, {bool pounds = false}) =>
    HistoryDecimal.ofDouble(kg)?.withinDisplayRange(pounds: pounds) ?? false;

/// What History's volume evidence covers.
enum HistoryVolumeState {
  /// No working sets.
  empty,

  /// Every working set is known, and there is at least one.
  full,

  /// Some but not all working sets are known.
  partial,

  /// No working set is known, and there is at least one.
  none,
}

/// Exact History volume evidence: every live working set counts once in
/// [total]; only known ones add exact load × reps to [knownSum] (kg).
final class HistoryVolumeEvidence {
  HistoryVolumeEvidence._(this.total, this.known, this.knownSum);

  static final HistoryVolumeEvidence empty = HistoryVolumeEvidence._(
    0,
    0,
    HistoryDecimal.zero,
  );

  final int total, known;
  final HistoryDecimal knownSum;

  HistoryVolumeState get state => total == 0
      ? HistoryVolumeState.empty
      : known == total
      ? HistoryVolumeState.full
      : known == 0
      ? HistoryVolumeState.none
      : HistoryVolumeState.partial;

  /// Adds one working set: its exact load × reps, or null when unknown.
  HistoryVolumeEvidence add(HistoryDecimal? contribution) =>
      HistoryVolumeEvidence._(
        total + 1,
        contribution == null ? known : known + 1,
        contribution == null ? knownSum : knownSum + contribution,
      );

  HistoryVolumeEvidence operator +(HistoryVolumeEvidence other) =>
      HistoryVolumeEvidence._(
        total + other.total,
        known + other.known,
        knownSum + other.knownSum,
      );
}
