/// Development identities; release identity and transport remain unselected.
abstract final class AlkionIdentity {
  static const applicationId = 'dev.animusstudio.alkion.dev';
  static const packageName = 'alkion';
  static const displayName = 'Alkion Dev';
  static const endorsement = 'Alkion, by Animus';
  static const preferencePrefix = 'alkion.dev.';
  static const credentialPrefix = 'alkion.dev.auth.';

  static Never unavailable(String capability) =>
      throw UnsupportedError('Alkion development: $capability is unavailable');
}
