import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:ota_update/ota_update.dart';

import '../capture/capture_transport.dart';
import '../capture/source_write_gate.dart';

/// Progress callback: 0..100 download percent, or -1 once the OS installer is
/// launched (treat as success — the standard path doesn't emit a done event).
typedef OtaProgress = void Function(int percent);

class UpdateInstaller {
  UpdateInstaller({Stream<OtaEvent> Function(String apkUrl)? execute})
      : _execute = execute ?? _otaExecute;

  static const _channel = MethodChannel('reps/updates');

  final Stream<OtaEvent> Function(String apkUrl) _execute;

  static Stream<OtaEvent> _otaExecute(String apkUrl) =>
      OtaUpdate().execute(apkUrl, destinationFilename: 'reps-update.apk');

  Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    return (await _channel.invokeMethod<bool>('canRequestInstalls')) ?? false;
  }

  Future<void> openInstallSettings() =>
      _channel.invokeMethod('openInstallSettings');

  /// Downloads [apkUrl] and launches the installer. Yields the download percent,
  /// then -1 when installing. Throws on download/permission errors so the UI can react.
  ///
  /// The whole download and installer launch is one admitted source
  /// operation, so a data capture waits for an install already under way;
  /// while a capture has admission closed the stream fails with
  /// `admission_closed` before anything is downloaded.
  Stream<int> install(String apkUrl) {
    final out = StreamController<int>();
    out.onListen = () {
      Future<void> run() async {
        TransportAdmission.instance.ensureOpen('update.install');
        await runSourceWrite('update.install', (_) async {
          TransportAdmission.instance.ensureOpen('update.install');
          await out.addStream(_install(apkUrl));
        });
      }

      run().then((_) => out.close(), onError: (Object e, StackTrace st) {
        if (!out.isClosed) out.addError(e, st);
        return out.close();
      });
    };
    return out.stream;
  }

  Stream<int> _install(String apkUrl) async* {
    final controller = _execute(apkUrl);
    await for (final e in controller) {
      switch (e.status) {
        case OtaStatus.DOWNLOADING:
          yield int.tryParse(e.value ?? '') ?? 0;
        case OtaStatus.INSTALLING:
          yield -1; // installer launched
          return;
        case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
          throw const UpdatePermissionException();
        case OtaStatus.DOWNLOAD_ERROR:
        case OtaStatus.INTERNAL_ERROR:
        case OtaStatus.CHECKSUM_ERROR:
        case OtaStatus.INSTALLATION_ERROR:
          throw UpdateInstallException(e.status.toString());
        case OtaStatus.ALREADY_RUNNING_ERROR:
        case OtaStatus.CANCELED:
        case OtaStatus.INSTALLATION_DONE:
          return;
      }
    }
  }
}

class UpdatePermissionException implements Exception {
  const UpdatePermissionException();
}

class UpdateInstallException implements Exception {
  const UpdateInstallException(this.detail);
  final String detail;
}
