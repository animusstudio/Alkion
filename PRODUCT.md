# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

People who plan and record strength-training workouts. The immediate operating context is the owner's own Android phone; synthetic Linux workflows support development and do not establish Android qualification.

## Product Purpose

Alkion is an offline-first workout planner and logger. It lets a person manage exercises and training days, record sets, resume an interrupted workout, and review workout and bodyweight history without requiring an account or network connection. Explicit configuration adds optional Animus browser sign-in, account/space confirmation and a foreground read-access check. Synchronization sending and replica downloads remain later workstreams.

## Positioning

The app keeps the local workout workflow available without an account. A later optional sync path is intended to complement local use, not replace it.

## Operating Context

People use Alkion on an Android phone before, during and after strength training. A workout can be minimized and resumed. The app also supports reviewing history and progress, editing plans and exercises, managing preferences, and using existing export and recovery flows. Current synthetic Linux tests exercise account-free local workflows; Android, owner storage and sync are not qualified by those tests.

## Capabilities and Constraints

- First use offers Start local or Restore backup, then opens the app directly. New local profiles have an empty exercise library; existing and restored exercises are preserved. Current workflows include Today, Progress, History and Plan navigation; workout entry/resume/finish; exercise and training-day editing; bodyweight measurements; unit, language, theme and appearance settings; and existing export, backup and recovery surfaces.
- Local use remains account-free. The optional Profile → Animus connection opens the external provider browser and verifies access only after explicit account/space confirmation. It does not attach local history to a server writer, send pending operations or download a replica.
- Keep exact recorded values, ordering, dates, units and evidence distinctions. Missing or incomplete information must not be presented as a zero or as a medical conclusion.
- The Android installation and owner-storage route remain unqualified. Synthetic Linux tests establish only the tested synthetic Linux behavior.
- Flutter is the existing client implementation. No new runtime, backend or dependency is selected by this product record.

## Brand Commitments

The product name is Alkion, with the existing “Alkion, by Animus” endorsement. The owner selected the established Reps specimen and Animus branding as the UI reference. No new product identity or visual direction is in scope.

## Evidence on Hand

The repository contains the Flutter app, synthetic fixtures, focused widget/workflow tests, and a public workout-tracker visual handoff. Linux synthetic local workflows and real disposable-provider/API connection boundaries are tested. The [acceptance record](docs/alkion/acceptance.md) gives their scope and current native adapter limits. No real personal data is included in design fixtures; these checks do not qualify owner storage or synchronization.

## Product Principles

- Keep essential workout use available offline and without an account.
- Preserve user-owned workout history and exact recorded values.
- Make incomplete evidence and failed or interrupted operations understandable.
- Add optional sync only through its separate reviewed workstream.

## Accessibility & Inclusion

Use Android-sized touch targets, respect system text scaling and reduced-motion settings, and retain the supported English, German, Spanish and Italian translations. Keep dark and light appearance readable.
