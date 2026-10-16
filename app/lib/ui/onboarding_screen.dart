import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/motion.dart';

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
    final t = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              StaggeredEntrance(
                index: 0,
                child: Text(l.onboardingWelcome, style: t.headlineMedium),
              ),
              const SizedBox(height: 12),
              StaggeredEntrance(
                index: 1,
                child: Text(l.onboardingIntro, style: t.bodyMedium),
              ),
              const SizedBox(height: 32),
              StaggeredEntrance(
                index: 2,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _choose(OnboardingChoice.starter),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(l.onboardingAddStarter),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              StaggeredEntrance(
                index: 3,
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _choose(OnboardingChoice.empty),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(l.onboardingStartEmpty),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
