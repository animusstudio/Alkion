import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/motion.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/plan_form.dart';

enum OnboardingChoice { empty, starter }

/// First-launch screen: lets the user start with an empty library or seed a
/// starter set of exercises; muscle targets require a separate explicit choice. Everything seeded is
/// editable/deletable later. [onChosen] performs the seeding + marks onboarding
/// complete; this widget only collects the choice.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onChosen});

  final Future<void> Function(OnboardingChoice choice) onChosen;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;

  Future<void> _choose(OnboardingChoice choice) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onChosen(choice);
    } finally {
      // On success the shell replaces this widget; the mounted guard makes a
      // failed seed re-enable the buttons so the user can retry.
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          'Alkion',
          style: WorkoutType.body(
            size: 18,
            weight: FontWeight.w700,
            color: tokens.text,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    StaggeredEntrance(
                      index: 0,
                      child: Text(
                        l.onboardingWelcome,
                        style: WorkoutType.display(
                          size: 28,
                          weight: FontWeight.w700,
                          color: tokens.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    StaggeredEntrance(
                      index: 1,
                      child: Text(
                        l.onboardingIntro,
                        style: WorkoutType.body(size: 16, color: tokens.dim),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l.alkionLocalOnly,
                      style: WorkoutType.body(size: 14, color: tokens.dim),
                    ),
                    const SizedBox(height: 32),
                    StaggeredEntrance(
                      index: 2,
                      child: PrimaryBtn(
                        l.onboardingAddStarter,
                        enabled: !_busy,
                        onTap: () => _choose(OnboardingChoice.starter),
                      ),
                    ),
                    const SizedBox(height: 12),
                    StaggeredEntrance(
                      index: 3,
                      child: PrimaryBtn(
                        l.onboardingStartEmpty,
                        enabled: !_busy,
                        secondary: true,
                        onTap: () => _choose(OnboardingChoice.empty),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
