import 'package:intl/intl.dart';

/// A backup or restore instant in the user's local time with its year, for
/// example "9 Nov 2026, 14:03" in en. An unparseable stamp is shown as stored:
/// it is a manifest value, never exception text.
String fmtRecoveryInstant(String iso, String localeName) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  return fmtRecoveryDateTime(parsed, localeName);
}

/// [fmtRecoveryInstant] for an already parsed instant.
String fmtRecoveryDateTime(DateTime instant, String localeName) =>
    DateFormat.yMMMd(localeName).add_Hm().format(instant.toLocal());

/// A file size in decimal units, as Android's storage settings show them:
/// "0 B", "980 B", "12.3 kB", "1.2 MB", with the locale's decimal mark.
String fmtFileSize(int bytes, String localeName) {
  const units = ['kB', 'MB', 'GB', 'TB'];
  if (bytes < 1000) return '$bytes B';
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${NumberFormat('0.0', localeName).format(value)} ${units[unit]}';
}
