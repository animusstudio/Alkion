import 'dart:io';

/// One identity drives storage and all variant-scoped platform identifiers.
enum AlkionVariant {
  dev('dev.animusstudio.alkion.dev', 'Alkion Dev', 'alkion.dev.'),
  supported('dev.animusstudio.alkion', 'Alkion', 'alkion.');

  const AlkionVariant(
    this.applicationId,
    this.displayName,
    this.preferencePrefix,
  );
  final String applicationId;
  final String displayName;
  final String preferencePrefix;

  String get credentialPrefix => '${preferencePrefix}auth.';
  String get notificationChannel => '${preferencePrefix}workout_session';
  String get addRestAction => '${preferencePrefix}add_30s';

  void requireNativeIdentity(Map<String, dynamic>? native) {
    if (native == null ||
        native['applicationId'] != applicationId ||
        native['flavor'] != name ||
        native['displayName'] != displayName) {
      throw const FormatException('Alkion installation identity mismatch');
    }
  }
}

/// Android flavors are checked against the installed package before startup.
/// Linux keeps its existing development identity, independent of flavor defines.
abstract final class AlkionIdentity {
  static final current = forPlatform(
    isAndroid: Platform.isAndroid,
    flavor: const String.fromEnvironment(
      'FLUTTER_APP_FLAVOR',
      defaultValue: 'dev',
    ),
  );
  static String get applicationId => current.applicationId;
  static const packageName = 'alkion';
  static String get displayName => current.displayName;
  static const endorsement = 'Alkion, by Animus';
  static String get preferencePrefix => current.preferencePrefix;
  static String get credentialPrefix => current.credentialPrefix;
  static String get notificationChannel => current.notificationChannel;
  static String get addRestAction => current.addRestAction;

  static AlkionVariant forPlatform({required bool isAndroid, String? flavor}) {
    if (!isAndroid) return AlkionVariant.dev;
    return switch (flavor) {
      'dev' => AlkionVariant.dev,
      'supported' => AlkionVariant.supported,
      _ => throw const FormatException(
        'An explicit Alkion Android flavor is required',
      ),
    };
  }

  static Never unavailable(String capability) =>
      throw UnsupportedError('Alkion: $capability is unavailable');
}
