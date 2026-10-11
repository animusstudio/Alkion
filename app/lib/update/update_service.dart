import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../capture/preference_writes.dart';
import '../capture/source_write_gate.dart';

/// Parsed available update.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.sizeBytes,
  });
  final String version; // no leading v
  final String notes;
  final String apkUrl;
  final int sizeBytes;
}

({int major, int minor, int patch})? _parse(String raw) {
  // Tolerate leading 'v', and a trailing '+build' or '-suffix'.
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  s = s.split('+').first.split('-').first;
  final parts = s.split('.');
  if (parts.length != 3) return null;
  final n = parts.map(int.tryParse).toList();
  if (n.any((x) => x == null)) return null;
  return (major: n[0]!, minor: n[1]!, patch: n[2]!);
}

/// Pure: is [remote] a strictly newer semver than [local]? Malformed → false.
bool isNewer(String remote, String local) {
  final r = _parse(remote), l = _parse(local);
  if (r == null || l == null) return false;
  if (r.major != l.major) return r.major > l.major;
  if (r.minor != l.minor) return r.minor > l.minor;
  return r.patch > l.patch;
}

/// Pure throttle gate for the auto-check.
bool shouldAutoCheck({
  required bool enabled,
  required int lastCheckMs,
  required int nowMs,
}) =>
    enabled && (nowMs - lastCheckMs) > 24 * 60 * 60 * 1000;

const _etagKey = 'update.etag';
const _releasesUrl =
    'https://api.github.com/repos/psychonaut0/workout-tracker/releases/latest';

class UpdateService {
  UpdateService({http.Client? client, bool? isAndroidOverride})
      : _client = client ?? http.Client(),
        _isAndroid = isAndroidOverride ?? Platform.isAndroid;

  final http.Client _client;
  final bool _isAndroid;

  /// Checks GitHub for a newer release. Returns null when up-to-date, off
  /// Android, or on 304. On a real error: [force] (manual button) rethrows so
  /// the UI can show "couldn't check"; the auto path (force:false) swallows it.
  ///
  /// The manual ([force]) path never sends `If-None-Match`: it always
  /// re-evaluates against a fresh body so a previously-deferred ("Later")
  /// update can never be hidden behind a 304. The once/day auto-check keeps the
  /// ETag — it stays cheap and won't re-nag about a release the user deferred.
  Future<UpdateInfo?> checkForUpdate({bool force = false}) async {
    if (!_isAndroid) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final etag = prefs.getString(_etagKey);
      final res = await _client.get(
        Uri.parse(_releasesUrl),
        headers: {
          'Accept': 'application/vnd.github+json',
          if (!force && etag != null) 'If-None-Match': etag,
        },
      );
      if (res.statusCode == 304) return null;
      if (res.statusCode != 200) return null;
      final newEtag = res.headers['etag'];
      if (newEtag != null) {
        try {
          await writePreferences(
              'prefs.update_etag', (p) => p.setString(_etagKey, newEtag));
        } on SourceGateException {
          // Not cached while a data capture holds the source; the next
          // check simply sends no If-None-Match.
        }
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String?;
      if (tag == null) return null;
      final info = await PackageInfo.fromPlatform();
      if (!isNewer(tag, info.version)) return null;

      final assets = (json['assets'] as List?) ?? const [];
      final apk = assets.whereType<Map<String, dynamic>>().firstWhere(
            (a) => (a['name'] as String? ?? '').endsWith('.apk'),
            orElse: () => const {},
          );
      final url = apk['browser_download_url'] as String?;
      if (url == null) return null;

      final v =
          (tag.startsWith('v') || tag.startsWith('V')) ? tag.substring(1) : tag;
      return UpdateInfo(
        version: v,
        notes: (json['body'] as String?) ?? '',
        apkUrl: url,
        sizeBytes: (apk['size'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // Manual button surfaces "couldn't check"; auto-check stays silent.
      if (force) rethrow;
      return null;
    }
  }
}
