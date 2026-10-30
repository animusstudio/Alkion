import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/workout_translation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'all 17 actual typed canonical measurements match bytes/hash and budget',
    () {
      final root = Directory('test/fixtures/animus_workout_upload');
      final manifest =
          jsonDecode(File('${root.path}/manifest.json').readAsStringSync())
              as Map;
      var measured = 0;
      for (final raw in manifest['cases'] as List) {
        final capture = raw as Map;
        if (capture['canonical'] == null) continue;
        final golden = capture['canonical'] as Map;
        final wire = File(
          '${root.path}/${golden['request']}',
        ).readAsBytesSync();
        final encoded = AnimusCommandBytes(
          uploadMap(jsonDecode(utf8.decode(wire))),
        );
        expect(
          encoded.canonical.length,
          golden['canonical_bytes'],
          reason: capture['case'] as String,
        );
        expect(
          encoded.canonicalHash,
          golden['canonical_sha256'],
          reason: capture['case'] as String,
        );
        expect(
          encoded.withinBudget,
          (golden['canonical_bytes'] as int) <=
                  (golden['canonical_limit'] as int) &&
              wire.length <= animusWireLimit,
          reason: capture['case'] as String,
        );
        measured++;
      }
      expect(measured, 17);
    },
  );
  test(
    'typed timestamp hashing trims Dart fractional zeroes without changing frozen wire evidence',
    () {
      final request = uploadMap(
        jsonDecode(
          File(
            'test/fixtures/animus_workout_upload/10-pinned-workout-finish.request.json',
          ).readAsStringSync(),
        ),
      );
      final original = AnimusCommandBytes(request);
      (request['workout'] as Map)['finished_at'] =
          '2026-10-29T00:15:17.000000+02:00';
      final dartTime = AnimusCommandBytes(request);
      expect(dartTime.canonicalHash, original.canonicalHash);
      expect(dartTime.canonical, original.canonical);
      expect(dartTime.wireHash, isNot(original.wireHash));
    },
  );
}
