// A minimal ZIP writer for receiving-side tests: it builds well-formed
// archives the way a sender would, and deliberately malformed ones
// (traversal names, symbolic-link entries, lying sizes, duplicates).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One entry to write. Overrides make the archive lie about it.
class ZipTestEntry {
  ZipTestEntry(
    this.name,
    this.data, {
    this.deflate = false,
    this.unixMode,
    this.declaredSize,
    this.crcOverride,
  });

  final String name;
  final List<int> data;
  final bool deflate;

  /// Unix mode stored in the high 16 bits of the external attributes (for
  /// example `0xA1FF` for a symbolic link).
  final int? unixMode;

  /// Uncompressed size written instead of the real one.
  final int? declaredSize;
  final int? crcOverride;
}

const zipSymlinkMode = 0xA1FF;

List<int>? _table;

int crc32Of(List<int> data) {
  final table = _table ??= List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

Uint8List buildZip(List<ZipTestEntry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  for (final e in entries) {
    final name = utf8.encode(e.name);
    final compressed = e.deflate
        ? ZLibCodec(raw: true).encode(e.data)
        : List<int>.of(e.data);
    final crc = e.crcOverride ?? crc32Of(e.data);
    final size = e.declaredSize ?? e.data.length;
    final method = e.deflate ? 8 : 0;
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, 0x0800); // UTF-8 names
    u16(out, method);
    u16(out, 0);
    u16(out, 0);
    u32(out, crc);
    u32(out, compressed.length);
    u32(out, size);
    u16(out, name.length);
    u16(out, 0);
    out.add(name);
    out.add(compressed);

    u32(central, 0x02014b50);
    u16(central, (3 << 8) | 20); // made by Unix
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, method);
    u16(central, 0);
    u16(central, 0);
    u32(central, crc);
    u32(central, compressed.length);
    u32(central, size);
    u16(central, name.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, (e.unixMode ?? 0x81A4) << 16);
    u32(central, offset);
    central.add(name);
  }
  final cdOffset = out.length;
  final cd = central.toBytes();
  out.add(cd);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, cd.length);
  u32(out, cdOffset);
  u16(out, 0);
  return out.toBytes();
}

/// Every file of the capture directory [dir] as archive entries (manifest
/// first), the way a sender lays them out.
List<ZipTestEntry> entriesOf(Directory dir, {bool deflate = false}) {
  final files =
      dir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  String rel(File f) => f.path.substring(dir.path.length + 1);
  final manifest = files.firstWhere((f) => rel(f) == 'manifest.json');
  return [
    ZipTestEntry('manifest.json', manifest.readAsBytesSync(), deflate: deflate),
    for (final f in files)
      if (rel(f) != 'manifest.json')
        ZipTestEntry(rel(f), f.readAsBytesSync(), deflate: deflate),
  ];
}
