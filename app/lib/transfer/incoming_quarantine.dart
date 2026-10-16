import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/evidence.dart';
import '../store/local_store.dart';
import 'json_span_reader.dart';

const incomingQuarantineVersion = 'alkion-incoming-quarantine/1';
const draftFileName = 'workout-draft.json';
const finishedFileName = 'workout-last-finished.json';

/// Legacy queue evidence supplied explicitly. A failed read is never empty.
sealed class QueueRead {
  const QueueRead();
}

final class QueueAbsent extends QueueRead {
  const QueueAbsent();
}

final class QueueUnreadable extends QueueRead {
  const QueueUnreadable(this.reason);
  final String reason;
}

/// Ordered entries exactly as exported; each is uncertain until reviewed.
final class QueueBytes extends QueueRead {
  const QueueBytes(this.bytes);
  final Uint8List bytes;
}

/// Optional role-specific semantic check supplied by the caller, for example
/// "expired" for a finished snapshot. It sees bytes only and cannot delete.
typedef IncomingClassifier = String? Function(String role, Uint8List bytes);

final class QuarantineReceipt {
  const QuarantineReceipt(this.setId, this.items, this.queueState);
  final String setId;
  final List<Map<String, Object?>> items;
  final String queueState;
  bool get replayBlocked => queueState != 'absent' && queueState != 'empty';
}

/// Preserves exact incoming bytes and ordered uncertain queue evidence in one
/// transaction before any loader is allowed to read the directory. It never
/// discovers a root, follows a link, deletes, rewrites or replays anything.
final class IncomingQuarantine {
  IncomingQuarantine(this.db);
  final LocalDatabase db;

  Future<QuarantineReceipt> capture(
    Directory explicit, {
    required QueueRead queue,
    IncomingClassifier? classify,
  }) async {
    if (FileSystemEntity.typeSync(explicit.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const StoreException('incoming_directory_required');
    }
    final entries = explicit.listSync(followLinks: false)
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    final items = <Map<String, Object?>>[];
    final blobs = <String, Uint8List>{};
    for (final entry in entries) {
      final name = p.basename(entry.path);
      final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        items.add({'name': name, 'role': 'unsafe', 'type': type.toString()});
        continue;
      }
      final bytes = await File(entry.path).readAsBytes();
      final role = name == draftFileName
          ? 'draft'
          : name == finishedFileName
          ? 'finished'
          : name.endsWith('.tmp')
          ? 'orphan_temp'
          : 'unknown';
      final digest = sha256.convert(bytes).toString();
      blobs[digest] = bytes;
      items.add({
        'name': name,
        'role': role,
        'length': bytes.length,
        'sha256': digest,
        'classification': _classify(role, bytes, classify),
      });
    }
    final queueEvidence = _queue(queue);
    final setId =
        'inc-${sha256.convert(utf8.encode(jsonEncode([items, queueEvidence['state'], queueEvidence['sha256']]))).toString().substring(0, 40)}';
    await db.writeTransaction((tx) async {
      for (final item in items) {
        final digest = item['sha256'] as String?;
        if (digest == null) continue;
        await tx.putArtifact(
          id: 'inc-$digest',
          bytes: blobs[digest]!,
          digest: digest,
          parserVersion: incomingQuarantineVersion,
          format: 'incoming',
          disposition: 'quarantined-before-loader',
        );
      }
      final queueBytes = queue is QueueBytes ? queue.bytes : null;
      if (queueBytes != null) {
        final digest = sha256.convert(queueBytes).toString();
        await tx.putArtifact(
          id: 'inc-$digest',
          bytes: Uint8List.fromList(queueBytes),
          digest: digest,
          parserVersion: incomingQuarantineVersion,
          format: 'incoming',
          disposition: 'quarantined-before-loader',
        );
      }
      for (var i = 0; i < items.length; i++) {
        await _review(tx, '$setId:item:$i', 'incoming_evidence', {
          'set_id': setId,
          'order': i,
          ...items[i],
        });
      }
      await _review(tx, '$setId:queue', 'queue_${queueEvidence['state']}', {
        'set_id': setId,
        ...queueEvidence,
        'entries': null,
      });
      final queueEntries = (queueEvidence['entries'] as List?) ?? const [];
      for (var i = 0; i < queueEntries.length; i++) {
        await _review(tx, '$setId:queue:$i', 'uncertain_queue_entry', {
          'set_id': setId,
          'order': i,
          'acceptance': 'uncertain',
          'replay': 'blocked_no_blind_translation',
          ...(queueEntries[i] as Map<String, Object?>),
        });
      }
    });
    return QuarantineReceipt(setId, items, queueEvidence['state'] as String);
  }

  String _classify(String role, Uint8List bytes, IncomingClassifier? custom) {
    try {
      const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException {
      return 'invalid_utf8';
    }
    try {
      readJsonSpans(bytes);
    } on TransferRejection {
      return 'malformed';
    }
    return custom?.call(role, bytes) ?? 'well_formed_json';
  }

  Map<String, Object?> _queue(QueueRead queue) => switch (queue) {
    QueueAbsent() => {'state': 'absent', 'sha256': null},
    QueueUnreadable(:final reason) => {
      'state': 'read_failed',
      'reason': reason,
      'sha256': null,
    },
    QueueBytes(:final bytes) => _queueBytes(bytes),
  };

  Map<String, Object?> _queueBytes(Uint8List bytes) {
    final digest = sha256.convert(bytes).toString();
    try {
      final root = readJsonSpans(bytes);
      if (root.kind != JsonKind.array) {
        return {'state': 'malformed', 'sha256': digest};
      }
      return {
        'state': root.items!.isEmpty ? 'empty' : 'uncertain_entries',
        'sha256': digest,
        'entries': [
          for (final item in root.items!)
            {
              'start': item.start,
              'end': item.end,
              'entry_base64': base64.encode(item.slice(bytes)),
            },
        ],
      };
    } on TransferRejection catch (e) {
      return {'state': 'malformed', 'sha256': digest, 'error': e.toJson()};
    }
  }

  Future<void> _review(
    LocalTransaction tx,
    String id,
    String category,
    Map<String, Object?> evidence,
  ) async {
    final reviewId =
        'rv-${sha256.convert(utf8.encode(id)).toString().substring(0, 40)}';
    if (await tx.getOptional(
          'SELECT 1 FROM reviews WHERE profile_id=? AND review_id=?',
          [tx.profileId, reviewId],
        ) !=
        null) {
      return;
    }
    await tx.addReview(
      id: reviewId,
      category: category,
      evidence: localBytes({'format': incomingQuarantineVersion, ...evidence}),
    );
  }

  /// Replay/completeness stays blocked while any queue evidence is unreadable,
  /// malformed or holds uncertain entries without a recorded decision.
  Future<Map<String, Object?>> replayCompleteness() async {
    final rows = await db.getAll(
      "SELECT r.category FROM reviews r LEFT JOIN review_decisions d ON d.profile_id=r.profile_id AND d.review_id=r.review_id WHERE r.profile_id=? AND d.review_id IS NULL AND r.category IN ('queue_read_failed','queue_malformed','queue_uncertain_entries','uncertain_queue_entry')",
      [db.profileId],
    );
    return {
      'replay': rows.isEmpty ? 'no_queue_evidence_blocking' : 'blocked',
      'blocking_reviews': rows.length,
      'automatic_replay': 'never',
    };
  }
}
