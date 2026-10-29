import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../contracts.dart';
import '../ports.dart';

/// One fresh client per foreground request: no shared cookies, connections or
/// automatic retry state. Construction does not open sockets.
final class IoAnimusHttpPort implements AnimusHttpPort {
  final _pending = <_Request>{};
  bool _closed = false;

  @override
  Future<AnimusHttpResponse> get({
    required Uri uri,
    required Map<String, String> headers,
    required int maxResponseBytes,
    required Duration timeout,
  }) {
    if (_closed) {
      return Future.error(
        const AnimusHttpFailure(AnimusHttpFailureKind.closed),
      );
    }
    if (maxResponseBytes < 1 ||
        maxResponseBytes > AnimusDefinitionReadContract.maxResponseBytes ||
        timeout <= Duration.zero ||
        headers.keys.any((key) => key.toLowerCase() == 'cookie')) {
      return Future.error(
        const AnimusHttpFailure(AnimusHttpFailureKind.invalidResponse),
      );
    }
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = timeout
      ..maxConnectionsPerHost = 1
      ..userAgent = null;
    final pending = _Request(client);
    _pending.add(pending);
    pending.timer = Timer(
      timeout,
      () => pending.fail(AnimusHttpFailureKind.timeout),
    );
    unawaited(_read(pending, uri, headers, maxResponseBytes));
    return pending.result.future.whenComplete(() => _pending.remove(pending));
  }

  Future<void> _read(
    _Request pending,
    Uri uri,
    Map<String, String> headers,
    int limit,
  ) async {
    try {
      final request = await pending.client.getUrl(uri);
      pending.request = request;
      if (pending.done) {
        request.abort();
        return;
      }
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if (pending.done) return;
      // Only representation metadata is needed. In particular, Set-Cookie and
      // error payloads never become retained transport state.
      final metadata = <String, String>{};
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentEncodingHeader,
      ]) {
        final values = response.headers[name];
        if (values != null) metadata[name] = values.join(',');
      }
      if (response.statusCode != HttpStatus.ok) {
        pending.succeed(
          AnimusHttpResponse(
            statusCode: response.statusCode,
            headers: metadata,
            body: const [],
          ),
        );
        return;
      }
      if (response.contentLength > limit) {
        pending.fail(AnimusHttpFailureKind.responseTooLarge);
        return;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (pending.done) return;
        if (chunk.length > limit - bytes.length) {
          pending.fail(AnimusHttpFailureKind.responseTooLarge);
          return;
        }
        bytes.add(chunk);
      }
      pending.succeed(
        AnimusHttpResponse(
          statusCode: response.statusCode,
          headers: metadata,
          body: bytes.takeBytes(),
        ),
      );
    } on TimeoutException {
      pending.fail(AnimusHttpFailureKind.timeout);
    } on SocketException {
      pending.fail(AnimusHttpFailureKind.offline);
    } on HandshakeException {
      pending.fail(AnimusHttpFailureKind.offline);
    } catch (_) {
      // Native exceptions can contain URLs, headers or response fragments.
      pending.fail(AnimusHttpFailureKind.invalidResponse);
    }
  }

  @override
  Future<void> cancel() async {
    for (final pending in _pending.toList()) {
      pending.fail(AnimusHttpFailureKind.cancelled);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final pending in _pending.toList()) {
      pending.fail(AnimusHttpFailureKind.closed);
    }
  }
}

final class _Request {
  _Request(this.client);

  final HttpClient client;
  final result = Completer<AnimusHttpResponse>();
  HttpClientRequest? request;
  Timer? timer;
  bool get done => result.isCompleted;

  void fail(AnimusHttpFailureKind kind) {
    if (done) return;
    result.completeError(AnimusHttpFailure(kind));
    _release();
  }

  void succeed(AnimusHttpResponse response) {
    if (done) return;
    result.complete(response);
    _release();
  }

  void _release() {
    timer?.cancel();
    request?.abort();
    client.close(force: true);
  }
}
