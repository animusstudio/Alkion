// Explicit disposable native trial. This is never the normal app entry point.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'animus/connection.dart';
import 'catalog/catalog.dart';
import 'catalog_ui/catalog_trial_scope.dart';
import 'identity/alkion_identity.dart';
import 'l10n/app_localizations.dart';
import 'main.dart' show AlkionApp, AlkionRuntime;
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'theme/typography.dart';
import 'widgets/fit_label.dart';

const catalogTrialApplicationId = 'dev.animusstudio.alkion.catalogtrial.dev';
const _catalogAsset = 'assets/catalog_trial/catalog.dev.json';
const _manifestAsset = 'assets/catalog_trial/manifest.dev.json';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  runApp(const CatalogTrialBootstrap());
}

Future<CatalogBundle> _loadCatalog() async {
  if (!kDebugMode ||
      !const bool.fromEnvironment('ALKION_CATALOG_TRIAL') ||
      !Platform.isAndroid ||
      (await PackageInfo.fromPlatform()).packageName !=
          catalogTrialApplicationId) {
    throw const FormatException('An isolated native trial build is required');
  }
  final manifest = jsonDecode(await rootBundle.loadString(_manifestAsset));
  if (manifest is! Map<String, dynamic> ||
      manifest['format'] != 'alkion-catalog-trial-manifest' ||
      manifest['schema_version'] != 1 ||
      manifest['private_trial_only'] != true ||
      manifest['redistribution_cleared'] != false ||
      manifest['media_included'] != false ||
      manifest['projection_sha256'] is! String) {
    throw const FormatException('Unsupported trial manifest');
  }
  final data = await rootBundle.load(_catalogAsset);
  final bundle = CatalogBundle.fromBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    expectedSha256: manifest['projection_sha256'] as String,
  );
  if (bundle.catalogRevision != manifest['catalog_revision'] ||
      bundle.searchRevision != manifest['search_revision']) {
    throw const FormatException('Trial revision mismatch');
  }
  return bundle;
}

class CatalogTrialBootstrap extends StatefulWidget {
  const CatalogTrialBootstrap({super.key});

  @override
  State<CatalogTrialBootstrap> createState() => _CatalogTrialBootstrapState();
}

class _CatalogTrialBootstrapState extends State<CatalogTrialBootstrap> {
  CatalogBundle? _bundle;
  CatalogTrialState? _trial;
  AlkionRuntime? _runtime;
  Directory? _temporary;
  bool _failed = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bundle = await _loadCatalog();
      if (mounted) setState(() => _bundle = bundle);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _start() async {
    final bundle = _bundle;
    if (bundle == null || _starting) return;
    setState(() => _starting = true);
    Directory? temporary;
    AlkionRuntime? runtime;
    try {
      // This fresh app-sandbox cache directory is the only selected store root.
      // Never query default support storage or enumerate earlier trial roots.
      temporary = await Directory.systemTemp.createTemp('alkion-catalog-trial-');
      runtime = await AlkionRuntime.open(
        Directory('${temporary.path}/${AlkionIdentity.applicationId}'),
        connectionFactory: (_, _) => AnimusConnectionController(),
      );
      if (!mounted) {
        await runtime.close();
        await temporary.delete(recursive: true);
        return;
      }
      setState(() {
        _temporary = temporary;
        _runtime = runtime;
        _trial = CatalogTrialState(bundle);
      });
    } catch (_) {
      await runtime?.close();
      if (temporary != null) await temporary.delete(recursive: true);
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    final runtime = _runtime;
    final temporary = _temporary;
    final trial = _trial;
    if (runtime != null && temporary != null) {
      unawaited(() async {
        await runtime.close();
        trial?.dispose();
        await temporary.delete(recursive: true);
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    if (runtime != null) {
      return CatalogTrialScope(
        state: _trial!,
        child: AlkionApp(runtime: runtime),
      );
    }
    return MaterialApp(
      theme: buildTheme(Brightness.dark, defaultWorkoutAccent),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          final l = AppLocalizations.of(context);
          return Scaffold(
            backgroundColor: context.tokens.bg,
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FitLabel(
                          l.catalogTrialTitle,
                          maxLines: 3,
                          style: WorkoutType.display(
                            size: 28,
                            color: context.tokens.text,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _failed ? l.catalogTrialUnavailable : l.catalogTrialNotice,
                          style: WorkoutType.body(
                            size: 16,
                            color: context.tokens.dim,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (!_failed && (_bundle == null || _starting))
                          const LinearProgressIndicator(),
                        if (!_failed && _bundle != null && !_starting)
                          FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: _start,
                            child: FitLabel(
                              l.catalogTrialStart,
                              maxLines: 2,
                              style: WorkoutType.body(
                                size: 16,
                                color: context.tokens.onAction,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
