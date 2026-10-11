/// Client of the native `reps/capture` channel.
///
/// The native side owns the source-write gate (process mutex, interprocess
/// file lock and a durable hold record checked under that same lock) and the
/// durable file primitives. Every method answers with a map carrying a
/// stable `code`; anything other than the success code a caller expects is a
/// refusal. A missing native implementation surfaces as a
/// `MissingPluginException`, never as success.
library;

import 'package:flutter/services.dart';

/// The channel every engine and isolate of the app uses.
const repsCaptureChannel = MethodChannel('reps/capture');

class RepsCapturePlatform {
  const RepsCapturePlatform({this.channel = repsCaptureChannel});

  final MethodChannel channel;

  /// Invokes [method] and returns the native result map. Throws
  /// `MissingPluginException` when no native handler is registered and
  /// `PlatformException` for a native error.
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final result = await channel.invokeMapMethod<String, Object?>(
      method,
      arguments,
    );
    if (result == null || result['code'] is! String) {
      throw PlatformException(
        code: 'malformed_result',
        message: 'no code from $method',
      );
    }
    return result;
  }
}
