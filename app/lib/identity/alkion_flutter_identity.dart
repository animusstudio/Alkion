import 'dart:io';

import 'package:flutter/services.dart';

import 'alkion_identity.dart';

/// UI startup guard kept outside the core used by direct-Dart recovery tools.
abstract final class AlkionFlutterIdentity {
  /// [isAndroid] lets host tests exercise the actual platform-channel guard.
  static Future<void> verifyPlatformIdentity({bool? isAndroid}) async {
    if (!(isAndroid ?? Platform.isAndroid)) return;
    final native = await const MethodChannel(
      'dev.animusstudio.alkion/identity',
    ).invokeMapMethod<String, dynamic>('identity');
    AlkionIdentity.current.requireNativeIdentity(native);
  }
}
