import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'config.dart';

/// Both intents complete through the same validated OIDC transaction.
enum AnimusAuthIntent { signIn, createAccount }

/// Changes to a local generation or any remote setup create a fresh namespace.
final class AnimusScope {
  AnimusScope({
    required this.installationId,
    required this.profileId,
    required this.generation,
    required this.config,
  }) {
    if (!isCanonicalAnimusUuid(installationId) ||
        !isCanonicalAnimusUuid(profileId) ||
        generation < 1) {
      throw ArgumentError('Invalid Animus local scope');
    }
  }

  final String installationId;
  final String profileId;
  final int generation;
  final AnimusConfig config;

  String get storageKey =>
      'alkion.animus.v1.${sha256.convert(utf8.encode(jsonEncode([installationId, profileId, generation, config.fingerprint])))}';

  @override
  bool operator ==(Object other) =>
      other is AnimusScope && storageKey == other.storageKey;

  @override
  int get hashCode => storageKey.hashCode;

  @override
  String toString() => 'AnimusScope';
}

/// Only a signature/issuer/audience/nonce-validated OIDC adapter creates this.
/// Display labels are not identity and cannot establish workout authorization.
final class AnimusIdentity {
  AnimusIdentity({
    required this.issuer,
    required this.subject,
    this.displayName,
    this.email,
  }) {
    if (subject.isEmpty || subject.length > 255) {
      throw ArgumentError('Invalid Animus subject');
    }
  }

  final Uri issuer;
  final String subject;
  final String? displayName;
  final String? email;

  bool sameAccount(AnimusIdentity other) =>
      issuer.toString() == other.issuer.toString() && subject == other.subject;

  @override
  String toString() => 'AnimusIdentity';
}

/// Foreground bearer material. Never log/serialize into app data or receipts.
final class AnimusAuthSession {
  const AnimusAuthSession({
    required this.identity,
    required this.accessToken,
    required this.expiresAt,
  });

  final AnimusIdentity identity;
  final String accessToken;
  final DateTime expiresAt;

  @override
  String toString() => 'AnimusAuthSession(redacted)';
}

/// Public TrainingRecord GET subset. No body is retained after validation.
abstract final class AnimusDefinitionReadContract {
  static const requiredCapability = 'workouts:read';
  static const admissionHeader = 'X-Hub-Read-Admission';
  static const kind = 'exercise';
  static const member = 'definition';
  static const maxResponseBytes = 64 * 1024;
  static const maxJsonDepth = 32;
  static const timeout = Duration(seconds: 15);
  static const recordMembers = {
    'definition',
    'plan',
    'slot',
    'workout',
    'workout_set',
    'bodyweight',
    'muscle_target',
  };
}
