import 'dart:convert';
import 'dart:io';

import 'package:alkion/animus/adapters/auth_browser.dart';
import 'package:alkion/animus/adapters/secure_storage.dart';
import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';
import 'package:flutter/material.dart';

/// Explicit standalone native adapter check. It never opens an Alkion profile
/// or store, and uses only a disposable synthetic secret namespace. The browser
/// fixture returns a noncredential callback; real OIDC validation is exercised
/// separately by live_connection_integration_test.dart.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('ANIMUS_NATIVE_CHECKPOINT');
  final result = <String, Object?>{
    'version': 1,
    'secure_store': 'UNRUN',
    'generation_scope': 'UNRUN',
    'secret_cleanup': 'UNRUN',
    'browser_callback': 'UNRUN',
    'local_store_opened': false,
    'real_oidc_login': false,
  };
  if (!enabled || (!Platform.isAndroid && !Platform.isLinux)) {
    result['gate'] = 'REFUSED';
    _show(result);
    return;
  }
  final platform = Platform.isAndroid
      ? AnimusPlatform.android
      : AnimusPlatform.linux;
  const redirect = String.fromEnvironment('ANIMUS_NATIVE_REDIRECT_URI');
  const browserAddress = String.fromEnvironment('ANIMUS_NATIVE_BROWSER_URI');
  final browserUri = Uri.tryParse(browserAddress);
  if (browserUri == null ||
      browserUri.scheme != 'http' ||
      browserUri.host != '127.0.0.1' ||
      browserUri.userInfo.isNotEmpty ||
      browserUri.hasFragment) {
    result['gate'] = 'REFUSED';
    _show(result);
    return;
  }
  try {
    final config = AnimusConfig.fromEnvironment({
      'ALKION_ANIMUS_ENABLED': 'true',
      'ALKION_ANIMUS_API_ORIGIN': 'https://checkpoint.example.invalid',
      'ALKION_ANIMUS_ISSUER': 'https://checkpoint.example.invalid/oidc/',
      'ALKION_ANIMUS_CLIENT_ID': 'disposable-native-checkpoint',
      'ALKION_ANIMUS_REDIRECT_URI': redirect,
      'ALKION_ANIMUS_DATA_SPACE_ID': '00000000-0000-4000-8000-000000000011',
      'ALKION_ANIMUS_READ_ADMISSION': '00000000-0000-4000-8000-000000000012',
      'ALKION_ANIMUS_PROBE_RECORD_ID': '00000000-0000-4000-8000-000000000013',
    }, platform: platform)!;
    AnimusScope scope(int generation) => AnimusScope(
      installationId: '00000000-0000-4000-8000-000000000014',
      profileId: '00000000-0000-4000-8000-000000000015',
      generation: generation,
      config: config,
    );
    final secrets = OsAnimusSecretStore();
    try {
      await secrets.checkAvailability(scope(1));
      await secrets.write(scope(1), 'synthetic-native-checkpoint-marker');
      result['secure_store'] =
          await secrets.read(scope(1)) == 'synthetic-native-checkpoint-marker'
          ? 'PASS'
          : 'FAIL';
      result['generation_scope'] = await secrets.read(scope(2)) == null
          ? 'PASS'
          : 'FAIL';
    } on Object {
      result['secure_store'] = 'UNAVAILABLE';
    } finally {
      try {
        await secrets.delete(scope(1));
        result['secret_cleanup'] = await secrets.read(scope(1)) == null
            ? 'PASS'
            : 'FAIL';
      } on Object {
        result['secret_cleanup'] = 'UNAVAILABLE';
      }
    }
    final browser = SystemAnimusBrowser(platform: platform);
    try {
      final callback = await browser.authorize(
        authorizationUri: browserUri,
        redirectUri: config.redirectUri,
      );
      result['browser_callback'] =
          callback?.toString().split('?').first == redirect &&
              callback?.queryParameters['state'] == 'native-checkpoint' &&
              callback?.queryParameters['code'] == 'noncredential-checkpoint'
          ? 'PASS'
          : 'FAIL';
    } on Object {
      result['browser_callback'] = 'UNAVAILABLE';
    } finally {
      await browser.close();
    }
    result['gate'] =
        result['secure_store'] == 'PASS' &&
            result['generation_scope'] == 'PASS' &&
            result['secret_cleanup'] == 'PASS' &&
            result['browser_callback'] == 'PASS'
        ? 'PASS'
        : 'LIMITED';
  } on Object {
    result['gate'] = 'FAIL';
  }
  _show(result);
}

void _show(Map<String, Object?> result) {
  final text = jsonEncode(result);
  // This allowlisted receipt contains no configuration values or credentials.
  stdout.writeln('ANIMUS_NATIVE_CHECKPOINT $text');
  runApp(
    MaterialApp(
      home: Scaffold(body: SafeArea(child: SelectableText(text))),
    ),
  );
}
