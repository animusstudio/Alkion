import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;

import 'source_write_gate.dart';
import 'startup_inventory.dart';

/// Durable stage of one capture attempt. The set is closed: a journal naming
/// any other stage is unreadable, and unreadable means recovery.
enum CaptureStage {
  preparing('preparing'),
  held('held'),
  copying('copying'),
  sealed('sealed'),
  published('published'),
  resumeAllowed('resume_allowed'),
  resumed('resumed'),
  localHold('local_hold');

  const CaptureStage(this.wire);

  /// The exact journal string.
  final String wire;

  /// Whether ordinary startup must stay held: every stage except
  /// [resumeAllowed] and [resumed].
  bool get blocksStartup => this != resumeAllowed && this != resumed;

  static CaptureStage? fromWire(Object? wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// What a capture attempt is for.
enum CaptureMode {
  rehearsal('rehearsal'),
  localHold('local_hold');

  const CaptureMode(this.wire);

  final String wire;

  static CaptureMode? fromWire(Object? wire) {
    for (final m in values) {
      if (m.wire == wire) return m;
    }
    return null;
  }
}

/// Whether ordinary sync was meant to run before the capture paused it.
/// An intent only: never credentials, an account or a server address.
enum PriorSyncIntent {
  enabled,
  disabled,
  unknown;

  static PriorSyncIntent? fromWire(Object? wire) {
    for (final i in values) {
      if (i.name == wire) return i;
    }
    return null;
  }
}

/// Digest and length of one file written into a capture.
@immutable
class CaptureFileDigest {
  const CaptureFileDigest({required this.sha256, required this.length});

  final String sha256;
  final int length;

  Map<String, Object?> toJson() => {'sha256': sha256, 'length': length};
}

/// A journal that cannot be trusted. [code] is one of
/// `journal_unreadable`, `journal_malformed`, `journal_unknown_version`,
/// `journal_unknown_stage` (reading) or `journal_unsafe_value` (writing).
@immutable
class CaptureJournalException implements Exception {
  const CaptureJournalException(this.code);

  final String code;

  @override
  String toString() => 'CaptureJournalException($code)';
}

/// The durable state of one capture attempt.
///
/// String maps hold only short identifier/version tokens (see
/// [isSafeToken]): no URL, no e-mail address, and none of the credential
/// key names in [forbiddenJournalKeys].
@immutable
class CaptureJournalState {
  const CaptureJournalState({
    required this.captureId,
    required this.installation,
    required this.producerVersion,
    required this.runtimeVersions,
    required this.storeVersions,
    required this.mode,
    required this.stage,
    required this.gateGeneration,
    required this.priorSyncIntent,
    required this.inventory,
    required this.files,
    required this.manifestSha256,
  });

  /// Lowercase UUID of this attempt.
  final String captureId;

  /// Local installation context (platform, application id, ...).
  final Map<String, String> installation;
  final String producerVersion;
  final Map<String, String> runtimeVersions;
  final Map<String, String> storeVersions;
  final CaptureMode mode;
  final CaptureStage stage;

  /// Source-write gate generation, once admission was closed.
  final int? gateGeneration;
  final PriorSyncIntent priorSyncIntent;
  final List<InventoryEntry> inventory;

  /// Per captured file path: digest and length.
  final Map<String, CaptureFileDigest> files;

  /// Digest of the final manifest, once written.
  final String? manifestSha256;

  CaptureJournalState copyWith({
    CaptureStage? stage,
    int? gateGeneration,
    PriorSyncIntent? priorSyncIntent,
    List<InventoryEntry>? inventory,
    Map<String, CaptureFileDigest>? files,
    String? manifestSha256,
  }) =>
      CaptureJournalState(
        captureId: captureId,
        installation: installation,
        producerVersion: producerVersion,
        runtimeVersions: runtimeVersions,
        storeVersions: storeVersions,
        mode: mode,
        stage: stage ?? this.stage,
        gateGeneration: gateGeneration ?? this.gateGeneration,
        priorSyncIntent: priorSyncIntent ?? this.priorSyncIntent,
        inventory: inventory ?? this.inventory,
        files: files ?? this.files,
        manifestSha256: manifestSha256 ?? this.manifestSha256,
      );

  Map<String, Object?> toJson() => {
        'format': captureJournalFormat,
        'version': captureJournalVersion,
        'capture_id': captureId,
        'installation': installation,
        'producer_version': producerVersion,
        'runtime_versions': runtimeVersions,
        'store_versions': storeVersions,
        'mode': mode.wire,
        'stage': stage.wire,
        'gate_generation': gateGeneration,
        'prior_sync_intent': priorSyncIntent.name,
        'inventory': [for (final e in inventory) e.toJson()],
        'files': {for (final f in files.entries) f.key: f.value.toJson()},
        'manifest_sha256': manifestSha256,
      };
}

const captureJournalFormat = 'reps-capture-journal';
const captureJournalVersion = 1;

/// The journal file is small; anything larger is not a journal.
const captureJournalByteLimit = 1024 * 1024;

/// Key names that never appear in a journal map.
const forbiddenJournalKeys = {
  'access_token',
  'refresh_token',
  'token',
  'password',
  'secret',
  'email',
  'server_url',
  'url',
};

const _journalKeys = {
  'format',
  'version',
  'capture_id',
  'installation',
  'producer_version',
  'runtime_versions',
  'store_versions',
  'mode',
  'stage',
  'gate_generation',
  'prior_sync_intent',
  'inventory',
  'files',
  'manifest_sha256',
};

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// The private, versioned journal of the capture coordinator. It lives in
/// the private capture directory, separate from the source stores and from
/// any final capture, and is only ever replaced through the native durable
/// primitive (flushed temporary file, rename, directory flush).
class CaptureJournal {
  CaptureJournal(
    this.file, {
    required this.base,
    CaptureFiles files = const CaptureFiles(),
  }) : _files = files;

  final File file;

  /// An existing directory above [file] (the application-support
  /// directory): every directory between it and the journal is made durable
  /// before the journal is written.
  final Directory base;
  final CaptureFiles _files;

  /// The recorded state, or null when the journal is verifiably absent.
  /// Throws [CaptureJournalException] for anything unreadable, malformed,
  /// of another version or naming an unknown stage — never null for those.
  Future<CaptureJournalState?> read() async {
    final raw = await readRawFile(file, maxBytes: captureJournalByteLimit);
    if (raw.status == RawFileStatus.absent) return null;
    if (!raw.isCaptured) {
      throw const CaptureJournalException('journal_unreadable');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw.bytes!));
    } catch (_) {
      throw const CaptureJournalException('journal_malformed');
    }
    return decodeCaptureJournal(json);
  }

  /// Validates [state] and durably replaces the journal with it. Throws
  /// [CaptureJournalException] (`journal_unsafe_value`) before writing
  /// anything unsafe, and [SourceGateException] if the durable write fails.
  Future<void> write(CaptureJournalState state) async {
    final json = state.toJson();
    try {
      decodeCaptureJournal(jsonDecode(jsonEncode(json)));
    } on CaptureJournalException {
      throw const CaptureJournalException('journal_unsafe_value');
    }
    await _files.ensureDirectory(file.parent, base: base);
    await _files.durableReplace(file, utf8.encode(jsonEncode(json)));
  }
}

/// Strictly decodes a journal document. The version is checked first, then
/// the stage, then every other field; unknown keys are malformed.
CaptureJournalState decodeCaptureJournal(Object? json) {
  Never malformed() => throw const CaptureJournalException('journal_malformed');
  if (json is! Map<String, Object?>) malformed();
  if (json['format'] != captureJournalFormat) malformed();
  if (json['version'] != captureJournalVersion) {
    throw const CaptureJournalException('journal_unknown_version');
  }
  final stage = CaptureStage.fromWire(json['stage']);
  if (stage == null) {
    throw const CaptureJournalException('journal_unknown_stage');
  }
  if (json.length != _journalKeys.length ||
      !json.keys.every(_journalKeys.contains)) {
    malformed();
  }

  Map<String, String> tokens(String key) {
    final v = json[key];
    if (v is! Map<String, Object?>) malformed();
    final out = <String, String>{};
    for (final MapEntry(key: k, value: value) in v.entries) {
      if (value is! String ||
          !isSafeToken(k) ||
          !isSafeToken(value) ||
          forbiddenJournalKeys.contains(k.toLowerCase())) {
        malformed();
      }
      out[k] = value;
    }
    return out;
  }

  final captureId = json['capture_id'];
  final producer = json['producer_version'];
  final mode = CaptureMode.fromWire(json['mode']);
  final generation = json['gate_generation'];
  final intent = PriorSyncIntent.fromWire(json['prior_sync_intent']);
  final manifest = json['manifest_sha256'];
  final inventoryJson = json['inventory'];
  final filesJson = json['files'];
  if (captureId is! String ||
      !_uuid.hasMatch(captureId) ||
      producer is! String ||
      !isSafeToken(producer) ||
      mode == null ||
      intent == null ||
      (generation != null && (generation is! int || generation < 0)) ||
      (manifest != null && (manifest is! String || !isSha256Hex(manifest))) ||
      inventoryJson is! List<Object?> ||
      filesJson is! Map<String, Object?>) {
    malformed();
  }

  final List<InventoryEntry> inventory;
  try {
    inventory = [for (final e in inventoryJson) InventoryEntry.fromJson(e)];
  } on FormatException {
    malformed();
  }
  final files = <String, CaptureFileDigest>{};
  for (final MapEntry(key: path, value: v) in filesJson.entries) {
    if (!isSafeToken(path) || v is! Map<String, Object?>) malformed();
    final digest = v['sha256'];
    final length = v['length'];
    if (v.length != 2 ||
        digest is! String ||
        !isSha256Hex(digest) ||
        length is! int ||
        length < 0) {
      malformed();
    }
    files[path] = CaptureFileDigest(sha256: digest, length: length);
  }

  return CaptureJournalState(
    captureId: captureId,
    installation: tokens('installation'),
    producerVersion: producer,
    runtimeVersions: tokens('runtime_versions'),
    storeVersions: tokens('store_versions'),
    mode: mode,
    stage: stage,
    gateGeneration: generation as int?,
    priorSyncIntent: intent,
    inventory: inventory,
    files: files,
    manifestSha256: manifest as String?,
  );
}
