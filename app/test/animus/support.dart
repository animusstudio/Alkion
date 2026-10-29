import 'package:alkion/animus/config.dart';
import 'package:alkion/animus/contracts.dart';

Map<String, String> syntheticAnimusValues({
  AnimusPlatform platform = AnimusPlatform.linux,
}) => {
  'ALKION_ANIMUS_ENABLED': 'true',
  'ALKION_ANIMUS_API_ORIGIN': 'https://api.example.test',
  'ALKION_ANIMUS_ISSUER': 'https://identity.example.test/application/o/alkion/',
  'ALKION_ANIMUS_CLIENT_ID': 'alkion-synthetic',
  'ALKION_ANIMUS_REDIRECT_URI': platform == AnimusPlatform.linux
      ? 'http://127.0.0.1:43819/oauth2redirect'
      : 'dev.animusstudio.alkion.dev:/oauth2redirect',
  'ALKION_ANIMUS_DATA_SPACE_ID': '11111111-1111-4111-8111-111111111111',
  'ALKION_ANIMUS_READ_ADMISSION': '22222222-2222-4222-8222-222222222222',
  'ALKION_ANIMUS_PROBE_RECORD_ID': '33333333-3333-4333-8333-333333333333',
};

AnimusConfig syntheticAnimusConfig({
  AnimusPlatform platform = AnimusPlatform.linux,
}) => AnimusConfig.fromEnvironment(
  syntheticAnimusValues(platform: platform),
  platform: platform,
)!;

AnimusScope syntheticAnimusScope({
  AnimusConfig? config,
  String installationId = '44444444-4444-4444-8444-444444444444',
  String profileId = '55555555-5555-4555-8555-555555555555',
  int generation = 1,
}) => AnimusScope(
  installationId: installationId,
  profileId: profileId,
  generation: generation,
  config: config ?? syntheticAnimusConfig(),
);
