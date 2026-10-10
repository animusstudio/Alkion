// Host tests for explicit capture export and receiving verification.
//
// A real CertifiedCapture is produced by the coordinator over a synthetic,
// account-free source (test/support/certified_capture_fixture.dart, whose
// gate and durable file primitives are Dart models of the native protocol).
// Export copies it into a newly published directory without replacing
// anything and re-verifies the copy from disk; the private original is never
// written. The receiving side re-runs the strict verifier and expands a ZIP
// transport only to the exact v1 layout. Nothing here sends anything over a
// network: every HTTP client creation and socket connection is counted.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:workout_tracker/capture/capture_coordinator.dart';
import 'package:workout_tracker/capture/capture_export.dart';
import 'package:workout_tracker/capture/capture_manifest.dart';

import '../support/certified_capture_fixture.dart';
import '../support/zip_writer.dart';

/// Counts every attempt to reach a network over HTTP (every HTTP client the
/// app, PowerSync or package:http could create). Sockets are covered by the
/// source check in `no_login_or_network_needed`: an `IOOverrides` zone is
/// not usable here, it changes how `FileSystemEntity.type` answers.
class _NetworkCounter {
  var requests = 0;

  Future<T> run<T>(Future<T> Function() body) => HttpOverrides.runZoned(
        body,
        createHttpClient: (context) {
          requests++;
          throw const SocketException('network disabled in this test');
        },
      );
}

/// The capture feature's own sources: none may reach for a network API.
final _featureSources = [
  'lib/capture/capture_export.dart',
  'lib/capture/capture_service.dart',
  'lib/ui/capture_screen.dart',
  'lib/ui/capture_recovery_screen.dart',
];
final _networkApi = RegExp(
    r"package:http/|HttpClient|Socket\b|WebSocket|RawSocket|InternetAddress|Uri\.(http|https)\(");

Matcher _artifact(String code) => throwsA(
    isA<CaptureArtifactException>().having((e) => e.code, 'code', code));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CertifiedCaptureFixture fixture;
  late Directory destination;

  setUp(() async {
    fixture = await CertifiedCaptureFixture.create();
    destination = await Directory.systemTemp.createTemp('reps-export-dest');
  });

  tearDown(() async {
    await fixture.dispose();
    if (await destination.exists()) await destination.delete(recursive: true);
  });

  Directory finalOf(CertifiedCapture c) =>
      Directory(p.join(destination.path, 'reps-capture-${c.captureId}'));

  /// Entries in the destination other than what a test put there.
  List<String> leftovers() => [
        for (final e in destination.listSync(followLinks: false))
          p.basename(e.path),
      ];

  test('no_login_or_network_needed', () async {
    final network = _NetworkCounter();
    await network.run(() async {
      // Account-free: no sign-in, no server URL, sync never connected.
      final certified = await fixture.certify();
      final sealedDigest = treeDigest(certified.directory);

      final attempt = await exportCapture(
        certified,
        destination: ExportDestination.directory(destination),
        files: fixture.fakeFiles.files,
      );
      expect(attempt.transportStatus, ExportTransportStatus.sent);
      expect(attempt.manifestSha256, certified.manifestSha256);
      // The copy was re-verified from disk at the destination.
      expect(attempt.receiptVerified, isTrue);
      expect(attempt.location!.path, finalOf(certified).path);

      final received = await verifyReceivedCapture(finalOf(certified));
      expect(received.captureId, certified.captureId);
      expect(received.manifestSha256, certified.manifestSha256);
      expect(received, isNot(isA<CertifiedCapture>()));
      expect(treeDigest(finalOf(certified)), sealedDigest);
      // The private original is untouched and still there.
      expect(treeDigest(certified.directory), sealedDigest);
      // The malformed draft was captured byte for byte, for later review.
      expect(
          File(p.join(finalOf(certified).path, 'manifest.json'))
              .readAsStringSync(),
          contains('"active_draft"'));
      expect(leftovers(), ['reps-capture-${certified.captureId}']);
    });
    expect(network.requests, 0);
    for (final path in _featureSources) {
      expect(File(path).readAsStringSync(), isNot(matches(_networkApi)),
          reason: '$path must not use a network API');
    }
  });

  test('cancelled_truncated_export_keeps_private_original', () async {
    final certified = await fixture.certify();
    final sealedDigest = treeDigest(certified.directory);

    // Cancelled before anything was copied.
    final early = ExportCancellation()..cancel();
    final cancelledExport = await exportCapture(
      certified,
      destination: ExportDestination.directory(destination),
      cancellation: early,
      files: fixture.fakeFiles.files,
    );
    expect(cancelledExport.transportStatus, ExportTransportStatus.cancelled);
    expect(cancelledExport.receiptVerified, false);
    expect(cancelledExport.manifestSha256, certified.manifestSha256);
    expect(leftovers(), isEmpty);
    final privateCaptureDigestAfterCancellation =
        treeDigest(certified.directory);
    expect(privateCaptureDigestAfterCancellation, sealedDigest);

    // Cancelled half way: nothing is published, the partial copy is gone.
    final midway = ExportCancellation();
    final cancelledMidway = await exportCapture(
      certified,
      destination: ExportDestination.directory(destination),
      cancellation: midway,
      files: fixture.fakeFiles.files,
      onCopied: (_) async => midway.cancel(),
    );
    expect(cancelledMidway.transportStatus, ExportTransportStatus.cancelled);
    expect(cancelledMidway.receiptVerified, false);
    expect(finalOf(certified).existsSync(), isFalse);
    expect(leftovers(), isEmpty);
    expect(treeDigest(certified.directory), sealedDigest);

    // A copy truncated on its way: the staging check refuses it.
    var truncated = false;
    final truncatedExport = await exportCapture(
      certified,
      destination: ExportDestination.directory(destination),
      files: fixture.fakeFiles.files,
      onCopied: (file) async {
        if (truncated || file.lengthSync() < 2) return;
        truncated = true;
        final bytes = file.readAsBytesSync();
        file.writeAsBytesSync(bytes.sublist(0, bytes.length - 1), flush: true);
      },
    );
    expect(truncated, isTrue);
    expect(truncatedExport.transportStatus, ExportTransportStatus.failed);
    expect(truncatedExport.receiptVerified, false);
    expect(truncatedExport.code, isNotNull);
    expect(finalOf(certified).existsSync(), isFalse);
    expect(leftovers(), isEmpty);
    expect(treeDigest(certified.directory), sealedDigest);

    // The explicit Android share transport is not available in this build:
    // no archive, no share sheet, no receipt.
    final shared = await exportCapture(
      certified,
      destination: ExportDestination.androidShare(),
      files: fixture.fakeFiles.files,
    );
    expect(shared.transportStatus, ExportTransportStatus.failed);
    expect(shared.receiptVerified, false);
    expect(treeDigest(certified.directory), sealedDigest);
  });

  test('existing_destination_never_replaced', () async {
    final certified = await fixture.certify();
    final sealedDigest = treeDigest(certified.directory);

    // Already there before the export.
    final taken = finalOf(certified)..createSync();
    File(p.join(taken.path, 'mine.txt')).writeAsStringSync('keep me');
    final before = treeDigest(destination);
    final refused = await exportCapture(
      certified,
      destination: ExportDestination.directory(destination),
      files: fixture.fakeFiles.files,
    );
    expect(refused.transportStatus, ExportTransportStatus.failed);
    expect(refused.code, 'destination_exists');
    expect(refused.receiptVerified, false);
    expect(treeDigest(destination), before);
    taken.deleteSync(recursive: true);

    // Appears while the copy is being made: publication refuses it.
    final raced = await exportCapture(
      certified,
      destination: ExportDestination.directory(destination),
      files: fixture.fakeFiles.files,
      onCopied: (_) async {
        if (finalOf(certified).existsSync()) return;
        finalOf(certified).createSync();
        File(p.join(finalOf(certified).path, 'mine.txt'))
            .writeAsStringSync('keep me');
      },
    );
    expect(raced.transportStatus, ExportTransportStatus.failed);
    expect(raced.code, 'destination_exists');
    expect(File(p.join(finalOf(certified).path, 'mine.txt')).readAsStringSync(),
        'keep me');
    expect(leftovers(), ['reps-capture-${certified.captureId}']);
    expect(treeDigest(certified.directory), sealedDigest);

    // A destination that is not an existing directory.
    final missing = await exportCapture(
      certified,
      destination:
          ExportDestination.directory(Directory(p.join(destination.path, 'no'))),
      files: fixture.fakeFiles.files,
    );
    expect(missing.transportStatus, ExportTransportStatus.failed);
    expect(missing.code, 'destination_invalid');
  });

  test('export_requires_the_sealed_verified_capture', () async {
    final certified = await fixture.certify();
    // The private capture no longer matches what was certified.
    final store = certified.directory
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((f) => p.basename(f.path) != 'manifest.json');
    store.writeAsBytesSync([...store.readAsBytesSync(), 0x20], flush: true);
    final attempt = await exportCapture(
      certified,
      destination: ExportDestination.directory(destination),
      files: fixture.fakeFiles.files,
    );
    expect(attempt.transportStatus, ExportTransportStatus.failed);
    expect(attempt.receiptVerified, false);
    expect(attempt.code, 'capture_changed');
    expect(leftovers(), isEmpty);
  });

  test('archive_paths_sizes_and_digest_rechecked', () async {
    final certified = await fixture.certify();
    final sealedDigest = treeDigest(certified.directory);
    final good = entriesOf(certified.directory);
    var serial = 0;

    Future<File> archive(List<ZipTestEntry> entries, {int? cut}) async {
      var bytes = buildZip(entries);
      if (cut != null) bytes = bytes.sublist(0, bytes.length - cut);
      final f = File(p.join(fixture.source.path, 'a${++serial}.zip'));
      await f.writeAsBytes(bytes, flush: true);
      return f;
    }

    Future<VerifiedReceivedCapture> expand(File zip) => expandCaptureArchive(
          zip,
          destination,
          files: fixture.fakeFiles.files,
        );

    // Hostile names never leave the destination.
    var traversalArchiveAccepted = false;
    for (final name in const [
      '../escape',
      'stores/../../escape',
      '/tmp/escape',
      'stores\\escape',
      'stores/nested/escape',
      './manifest.json',
      'stores/',
    ]) {
      final zip = await archive([
        ...good,
        ZipTestEntry(name, [1, 2, 3]),
      ]);
      try {
        await expand(zip);
        traversalArchiveAccepted = true;
      } on CaptureArtifactException {
        // Refused, as it must be.
      }
    }
    expect(traversalArchiveAccepted, false);
    expect(File(p.join(destination.parent.path, 'escape')).existsSync(),
        isFalse);
    expect(leftovers(), isEmpty);

    // A symbolic-link entry, even under a declared name.
    final linked = [
      for (final e in good)
        e.name == 'manifest.json'
            ? e
            : ZipTestEntry(e.name, e.data, unixMode: zipSymlinkMode),
    ];
    await expectLater(expand(await archive(linked)), _artifact('archive_entry_type'));

    // Truncated anywhere: the archive is refused.
    for (final cut in const [1, 30, 200]) {
      await expectLater(
          expand(await archive(good, cut: cut)), throwsA(isA<CaptureArtifactException>()));
    }

    // Sizes that disagree with the manifest, or a body longer than declared.
    final lying = [
      for (final e in good)
        e.name == 'manifest.json'
            ? e
            : ZipTestEntry(e.name, e.data, declaredSize: e.data.length + 1),
    ];
    await expectLater(expand(await archive(lying)), _artifact('archive_entry_size'));
    final store = good.firstWhere((e) => e.name != 'manifest.json');
    final grown = [
      for (final e in good)
        identical(e, store)
            ? ZipTestEntry(e.name, [...e.data, 0x20],
                declaredSize: e.data.length, deflate: true)
            : e,
    ];
    await expectLater(expand(await archive(grown)), throwsA(isA<CaptureArtifactException>()));

    // A body that does not match its checksum.
    final corrupt = [
      for (final e in good)
        identical(e, store) ? ZipTestEntry(e.name, e.data, crcOverride: 1) : e,
    ];
    await expectLater(expand(await archive(corrupt)), _artifact('archive_crc'));

    // Extra, missing and duplicated entries.
    await expectLater(
        expand(await archive([...good, ZipTestEntry('stores/extra.json', [1])])),
        _artifact('archive_unexpected_entry'));
    await expectLater(
        expand(await archive(good.where((e) => !identical(e, store)).toList())),
        _artifact('archive_entry_missing'));
    await expectLater(expand(await archive([...good, store])),
        _artifact('archive_entry_duplicate'));
    expect(leftovers(), isEmpty);

    // The genuine archive, stored and deflated, expands to exactly the
    // capture with the same immutable digest, once.
    final received = await expand(await archive(good));
    expect(received.manifestSha256, certified.manifestSha256);
    expect(received.captureId, certified.captureId);
    expect(treeDigest(received.directory), sealedDigest);
    final before = treeDigest(destination);
    await expectLater(expand(await archive(entriesOf(certified.directory, deflate: true))),
        _artifact('destination_exists'));
    expect(treeDigest(destination), before);
    received.directory.deleteSync(recursive: true);
    final deflated =
        await expand(await archive(entriesOf(certified.directory, deflate: true)));
    expect(deflated.manifestSha256, certified.manifestSha256);
    expect(treeDigest(deflated.directory), sealedDigest);

    // The private original never changed.
    expect(treeDigest(certified.directory), sealedDigest);

    // Receiving verification of a directory re-runs the strict verifier.
    File(p.join(deflated.directory.path, 'stores', 'extra')).writeAsStringSync('x');
    await expectLater(verifyReceivedCapture(deflated.directory),
        _artifact('unlisted_file'));
  });
}
