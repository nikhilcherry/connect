import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme.dart';
import 'home_shell.dart';

/// Last onboarding screen: shown once the RC has been checked and the tag is made.
class OnboardingCompleteScreen extends StatelessWidget {
  const OnboardingCompleteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(),
            const Icon(Icons.verified, size: 72, color: DL.success),
            const SizedBox(height: 24),
            Text(tr('Onboarding completed'), style: DLText.display, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(tr('Your RC is verified and your tag is ready.'),
                style: DLText.body.copyWith(color: DL.muted), textAlign: TextAlign.center),
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const HomeShell()), (r) => false),
              child: Text(tr('Go to Connect')),
            ),
          ]),
        ),
      ),
    );
  }
}
