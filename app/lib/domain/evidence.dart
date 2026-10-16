import 'dart:convert';
import 'dart:typed_data';

/// A preservation state, never an implicit numeric zero.
enum ValueState {
  valid,
  missing,
  nullValue,
  empty,
  invalid,
  unavailable,
  unknown,
}

final class FieldEvidence {
  const FieldEvidence(this.state, {this.raw});
  final ValueState state;
  final Object? raw;

  factory FieldEvidence.fromRow(Map<String, dynamic> row, String key) {
    if (!row.containsKey(key)) {
      return const FieldEvidence(ValueState.missing);
    }
    final value = row[key];
    if (value == null) {
      return const FieldEvidence(ValueState.nullValue);
    }
    if (value == '') {
      return const FieldEvidence(ValueState.empty, raw: '');
    }
    return FieldEvidence(ValueState.valid, raw: value);
  }

  Map<String, Object?> toJson() => {'state': state.name, 'raw': raw};
}

/// Exact decimal spelling is retained. Arithmetic never passes through double.
/// This is the decimal TEXT grammar produced by the retained kilogram stores.
final class ExactDecimal implements Comparable<ExactDecimal> {
  ExactDecimal._(this.text, this.coefficient, this.scale);
  final String text;
  final BigInt coefficient;
  final int scale;
  static final _grammar = RegExp(r'^[+-]?\d+(?:\.\d+)?$');

  static ExactDecimal? tryParse(String text) {
    if (!_grammar.hasMatch(text)) {
      return null;
    }
    final dot = text.indexOf('.');
    final scale = dot < 0 ? 0 : text.length - dot - 1;
    return ExactDecimal._(text, BigInt.parse(text.replaceAll('.', '')), scale);
  }

  static ExactDecimal parse(String text) =>
      tryParse(text) ?? (throw const FormatException('Invalid exact decimal'));

  @override
  int compareTo(ExactDecimal other) {
    final common = scale > other.scale ? scale : other.scale;
    return (coefficient * BigInt.from(10).pow(common - scale)).compareTo(
      other.coefficient * BigInt.from(10).pow(common - other.scale),
    );
  }

  /// Explicit compatibility display conversion; never use for an untouched save.
  double? get displayDouble => double.tryParse(text);
}

final class DecimalEvidence {
  const DecimalEvidence(this.state, this.raw);
  final ValueState state;
  final String? raw;
  ExactDecimal? get exact => raw == null ? null : ExactDecimal.tryParse(raw!);

  factory DecimalEvidence.fromRow(Map<String, dynamic> row, String key) {
    if (!row.containsKey(key)) {
      return const DecimalEvidence(ValueState.missing, null);
    }
    final raw = row[key];
    if (raw == null) {
      return const DecimalEvidence(ValueState.nullValue, null);
    }
    if (raw is! String) {
      return DecimalEvidence(ValueState.invalid, raw.toString());
    }
    if (raw.isEmpty) {
      return const DecimalEvidence(ValueState.empty, '');
    }
    return DecimalEvidence(
      ExactDecimal.tryParse(raw) == null
          ? ValueState.invalid
          : ValueState.valid,
      raw,
    );
  }
}

final class CalendarDay {
  CalendarDay._(this.text);
  final String text;
  factory CalendarDay(String text) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
      throw const FormatException('Calendar day required');
    }
    final parts = text.split('-').map(int.parse).toList();
    final date = DateTime.utc(parts[0], parts[1], parts[2]);
    if (parts[0] < 1 ||
        date.year != parts[0] ||
        date.month != parts[1] ||
        date.day != parts[2]) {
      throw const FormatException('Invalid calendar day');
    }
    return CalendarDay._(text);
  }
}

/// Own operation/ingestion instants require an explicit offset. Source times
/// use TimeEvidence, preserving offsetless text instead of guessing an offset.
final class OperationInstant {
  OperationInstant(this.text) {
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
    ).hasMatch(text)) {
      throw const FormatException('Explicit operation offset required');
    }
    CalendarDay(text.substring(0, 10));
    final clock = text.substring(11, 19).split(':').map(int.parse).toList();
    if (clock[0] > 23 ||
        clock[1] > 59 ||
        clock[2] > 59 ||
        DateTime.tryParse(text) == null) {
      throw const FormatException('Invalid operation instant');
    }
    if (!text.endsWith('Z')) {
      final offset = text
          .substring(text.length - 5)
          .split(':')
          .map(int.parse)
          .toList();
      if (offset[0] > 23 || offset[1] > 59) {
        throw const FormatException('Invalid offset');
      }
    }
  }
  factory OperationInstant.now() =>
      OperationInstant(DateTime.now().toUtc().toIso8601String());
  final String text;
}

enum TimeKind {
  calendarDay,
  offsetInstant,
  offsetless,
  invalid,
  missing,
  nullValue,
  empty,
  unavailable,
}

final class TimeEvidence {
  const TimeEvidence(this.kind, this.raw);
  final TimeKind kind;
  final String? raw;
  factory TimeEvidence.fromRow(Map<String, dynamic> row, String key) {
    if (!row.containsKey(key)) {
      return const TimeEvidence(TimeKind.missing, null);
    }
    final raw = row[key];
    if (raw == null) {
      return const TimeEvidence(TimeKind.nullValue, null);
    }
    if (raw == '') {
      return const TimeEvidence(TimeKind.empty, '');
    }
    if (raw is! String) {
      return TimeEvidence(TimeKind.invalid, raw.toString());
    }
    try {
      CalendarDay(raw);
      return TimeEvidence(TimeKind.calendarDay, raw);
    } on FormatException {
      /* Try instant. */
    }
    try {
      OperationInstant(raw);
      return TimeEvidence(TimeKind.offsetInstant, raw);
    } on FormatException {
      /* Preserve uncertainty. */
    }
    if (RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$',
    ).hasMatch(raw)) {
      try {
        OperationInstant('${raw}Z');
        return TimeEvidence(TimeKind.offsetless, raw);
      } on FormatException {
        return TimeEvidence(TimeKind.invalid, raw);
      }
    }
    return TimeEvidence(TimeKind.invalid, raw);
  }
}

/// Canonical local bytes only. This is deliberately not an Animus wire encoder.
Uint8List localBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(_sorted(value))));
Object? _sorted(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) {
    return value.map(_sorted).toList();
  }
  if (value is double && !value.isFinite) {
    throw const FormatException('Non-finite local value');
  }
  return value;
}
