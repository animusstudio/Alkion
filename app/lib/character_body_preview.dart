// Isolated synthetic renderer checkpoint. Does not open app startup/storage.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'data/body_workload.dart';
import 'l10n/app_localizations.dart';
import 'settings/settings_service.dart';
import 'ui/body_figure.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'ui/character_body.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  runApp(
    ChangeNotifierProvider(
      create: (_) => SettingsService(),
      child: const CharacterBodyPreview(),
    ),
  );
}

class CharacterBodyPreview extends StatefulWidget {
  const CharacterBodyPreview({super.key});

  @override
  State<CharacterBodyPreview> createState() => _CharacterBodyPreviewState();
}

class _CharacterBodyPreviewState extends State<CharacterBodyPreview> {
  final controller = CharacterBodyController();
  bool appControls = false;
  CharacterBodyStyle style = CharacterBodyStyle.male;
  CharacterBodyStatus status = CharacterBodyStatus.loading;
  bool dark = true;
  bool compact = false;
  bool visible = true;
  bool reduced = false;
  bool coloured = false;
  bool alternateAccent = false;
  int generation = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildTheme(
      dark ? Brightness.dark : Brightness.light,
      alternateAccent ? accents[4] : defaultWorkoutAccent,
    ),
    home: Builder(
      builder: (context) {
        final t = context.tokens;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Body renderer preview'),
            actions: [
              TextButton(
                onPressed: () => setState(() => appControls = !appControls),
                child: Text(appControls ? 'Raw renderer' : 'App controls'),
              ),
            ],
          ),
          body: SafeArea(
            child: appControls
                ? MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      disableAnimations:
                          reduced || MediaQuery.disableAnimationsOf(context),
                    ),
                    child: const _AppBodyControls(),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text('Synthetic artwork · ${status.name}'),
                        const SizedBox(height: 12),
                        Center(
                          child: GestureDetector(
                            onHorizontalDragUpdate: (event) =>
                                controller.rotateBy(event.delta.dx * .009),
                            child: SizedBox(
                              width: compact ? 128 : 280,
                              height: compact ? 212 : 464,
                              child: CharacterBody(
                                key: ValueKey(generation),
                                style: style,
                                scores: coloured
                                    ? const {
                                        WorkloadMuscle.chest: 1,
                                        WorkloadMuscle.quads: .5,
                                      }
                                    : const {},
                                neutral: t.text,
                                accent: t.accentText,
                                background: t.bg,
                                brightness: Theme.of(context).brightness,
                                visible: visible,
                                reducedMotion:
                                    reduced ||
                                    MediaQuery.disableAnimationsOf(context),
                                compact: compact,
                                controller: controller,
                                onStatus: (value) =>
                                    setState(() => status = value),
                                fallback: Center(
                                  child: Text(
                                    status == CharacterBodyStatus.loading
                                        ? 'Loading artwork'
                                        : 'Artwork unavailable',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton(
                              onPressed: () => setState(() {
                                style = style == CharacterBodyStyle.male
                                    ? CharacterBodyStyle.female
                                    : CharacterBodyStyle.male;
                              }),
                              child: Text(
                                style.name == 'male' ? 'Female' : 'Male',
                              ),
                            ),
                            TextButton(
                              onPressed: controller.front,
                              child: const Text('Front'),
                            ),
                            TextButton(
                              onPressed: controller.back,
                              child: const Text('Back'),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                controller.paused
                                    ? controller.resume()
                                    : controller.pause();
                              }),
                              child: Text(
                                controller.paused ? 'Rotate' : 'Pause',
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() => dark = !dark),
                              child: Text(dark ? 'Light' : 'Dark'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => compact = !compact),
                              child: Text(compact ? 'Enlarge' : 'Compact'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => coloured = !coloured),
                              child: const Text('Workload'),
                            ),
                            TextButton(
                              onPressed: () => setState(
                                () => alternateAccent = !alternateAccent,
                              ),
                              child: const Text('Accent'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => reduced = !reduced),
                              child: Text(
                                reduced ? 'Motion allowed' : 'Reduce motion',
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => visible = !visible),
                              child: Text(
                                visible ? 'Hide motion' : 'Show motion',
                              ),
                            ),
                            TextButton(
                              onPressed: controller.retry,
                              child: const Text('Retry'),
                            ),
                            TextButton(
                              onPressed: () => setState(() {
                                generation++;
                                status = CharacterBodyStatus.loading;
                              }),
                              child: const Text('Recreate'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

// Production body controls in the same competing scroll axes as Today. The
// second page and long list make pager/scroll behavior inspectable without data.
class _AppBodyControls extends StatefulWidget {
  const _AppBodyControls();
  @override
  State<_AppBodyControls> createState() => _AppBodyControlsState();
}

class _AppBodyControlsState extends State<_AppBodyControls> {
  int page = 0;
  final workload = calculateWorkoutWorkload(
    mode: WorkoutWorkloadMode.planned,
    exercises: const [
      WorkloadExerciseInput(
        muscleGroup: 'chest',
        sets: [
          WorkloadSetInput(completed: false, isWarmup: false),
          WorkloadSetInput(completed: false, isWarmup: false),
        ],
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('App controls · page ${page + 1}/2'),
      const Text(
        'Drag body to rotate. Tap for detail. Swipe beside it to page.',
      ),
      SizedBox(
        height: 300,
        child: PageView(
          onPageChanged: (value) => setState(() => page = value),
          children: [
            Row(
              children: [
                BodyFigure(workload: workload, visible: page == 0),
                const Expanded(
                  child: Center(child: Text('Swipe here for page 2')),
                ),
              ],
            ),
            const Center(child: Text('Page 2 · swipe back')),
          ],
        ),
      ),
      const SizedBox(
        height: 1000,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Text('Vertical scroll end'),
        ),
      ),
    ],
  );
}
