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
  test(
    'actual UI metadata preserves absent, empty and text without inventing a null clear',
    () {
      final capture = uploadMap(
        jsonDecode(
          File(
            'test/fixtures/animus_workout_send_ui/finish-null-notes.request.json',
          ).readAsStringSync(),
        ),
      );
      // Measured by production Go PrepareCommand from the exact UI capture.
      // Only notes omission changes; this is not a corrected HTTP200 fixture.
      final original = AnimusCommandBytes(capture);
      expect(original.canonical.length, 7419);
      expect(
        original.canonicalHash,
        '91fb381e8185f8484387689529eb0dbe7b4ec350a267caf74e5d2822be2381f2',
      );
      final corrected = uploadMap(jsonDecode(jsonEncode(capture)));
      (uploadMap(corrected['workout'])['workout'] as Map).remove('notes');
      final omitted = AnimusCommandBytes(corrected);
      expect(omitted.canonical.length, 7415);
      expect(
        omitted.canonicalHash,
        '880f76fd6b3053ee558e4610c66bffdddb032744d00802e1c3a3e22947b8a550',
      );
      final metadata = uploadMap(uploadMap(capture['workout'])['workout']);
      expect(metadata['notes'], uploadValue(null));
      final absent = <String, dynamic>{
        'split_label': uploadMap(metadata['split_label'])['value'],
      };
      expect(nativeWorkoutMetadata(absent).containsKey('notes'), isFalse);
      for (final value in ['', 'Saved note']) {
        final mapped = nativeWorkoutMetadata({...absent, 'notes': value});
        expect(mapped['notes'], uploadValue(value));
      }
      for (final value in [null, 3, false]) {
        expect(
          () => nativeWorkoutMetadata({...absent, 'notes': value}),
          throwsFormatException,
        );
      }
    },
  );
}
