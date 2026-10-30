import 'dart:typed_data';

import 'contracts.dart';

/// Bound to one immutable local/config scope. Construction must perform no I/O.
/// All methods are called only for explicit foreground connection work.
abstract interface class AnimusAuthPort {
  /// Browser code + PKCE S256. Null is user cancellation. The result is staged,
  /// never a retained/authorized connection until explicit account confirmation.
  Future<AnimusAuthSession?> authorize({
    AnimusAuthIntent intent = AnimusAuthIntent.signIn,
  });

  /// Revalidates retained material for this scope; never called at app startup.
  Future<AnimusAuthSession?> restore();

  /// Retains only this adapter's staged session after account/space confirmation.
  Future<void> retain(AnimusAuthSession session);

  /// A coordinated single exchange; caller bounds API 401 handling to one retry.
  Future<AnimusAuthSession?> refresh();

  /// Local cancellation/secret removal; remote revocation is not implied.
  Future<void> disconnect();
  Future<void> cancel();
  Future<void> close();
}

/// One bounded opaque session envelope per scope, held only in the OS key store.
/// No plaintext, SQLite, preferences or file fallback is permitted.
abstract interface class AnimusSecretStore {
  Future<void> checkAvailability(AnimusScope scope);
  Future<String?> read(AnimusScope scope);
  Future<void> write(AnimusScope scope, String value);
  Future<void> delete(AnimusScope scope);
}

final class AnimusSecretStoreUnavailable implements Exception {
  const AnimusSecretStoreUnavailable();
  @override
  String toString() => 'Animus secure storage unavailable';
}

enum AnimusHttpFailureKind {
  offline,
  timeout,
  cancelled,
  responseTooLarge,
  invalidResponse,
  closed,
}

final class AnimusHttpFailure implements Exception {
  const AnimusHttpFailure(this.kind);
  final AnimusHttpFailureKind kind;
  @override
  String toString() => 'Animus HTTP failure: ${kind.name}';
}

final class AnimusHttpResponse {
  AnimusHttpResponse({
    required this.statusCode,
    required Map<String, String> headers,
    required List<int> body,
  }) : headers = Map.unmodifiable(headers),
       body = Uint8List.fromList(body).asUnmodifiableView();

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;

  @override
  String toString() => 'AnimusHttpResponse($statusCode, body redacted)';
}

/// Dedicated foreground transport. No cookies, redirects, automatic retries,
/// certificate bypass, background work, or response/header logging.
abstract interface class AnimusHttpPort {
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  });
  Future<void> cancel();
  Future<void> close();
}

/// Bounded foreground action transport. It has no automatic retry policy.
abstract interface class AnimusUploadHttpPort implements AnimusHttpPort {
  Future<AnimusHttpResponse> post({
    required Uri uri,
    required Map<String, String> headers,
    required List<int> body,
    required int maxResponseBytes,
    required Duration timeout,
  });
}
