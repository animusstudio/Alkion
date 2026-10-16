// Machine calendar keys shared by storage and localized date helpers.
// Dart weekday: 1=Mon, 2=Tue, ..., 7=Sun (ISO-8601).

/// Returns the Monday 00:00 of the ISO week containing [d].
///
/// Dart weekday: 1=Mon .. 7=Sun → subtract (weekday-1) days.
DateTime weekStart(DateTime d) {
  final daysFromMonday = d.weekday - 1; // 0 for Mon, 6 for Sun
  return DateTime(d.year, d.month, d.day - daysFromMonday);
}

/// Formats [d] as a zero-padded ISO-8601 date string (`yyyy-MM-dd`).
///
/// MACHINE format — storage keys and inclusive string-compare range queries
/// depend on this exact shape. Never localize it.
String isoDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
