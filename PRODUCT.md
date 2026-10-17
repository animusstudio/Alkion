# Product

<!-- impeccable:product-schema 1 -->

## Platform

android

## Users

People who plan and record strength-training workouts. The immediate operating context is the owner's own Android phone; synthetic Linux workflows support development and do not establish Android qualification.

## Product Purpose

Alkion is an offline-first workout planner and logger. It lets a person manage exercises and training days, record sets, resume an interrupted workout, and review workout and bodyweight history without requiring an account or network connection. Optional Animus sync is a later workstream; it is not implemented in the current app.

## Positioning

The app keeps the local workout workflow available without an account. A later optional sync path is intended to complement local use, not replace it.

## Operating Context

People use Alkion on an Android phone before, during and after strength training. A workout can be minimized and resumed. The app also supports reviewing history and progress, editing plans and exercises, managing preferences, and using existing export and recovery flows. Current synthetic Linux tests exercise account-free local workflows; Android, owner storage and sync are not qualified by those tests.

## Capabilities and Constraints

- Current workflows include first-use selection of an empty or starter library; Today, Progress, History and Plan navigation; workout entry/resume/finish; exercise and training-day editing; bodyweight measurements; unit, language, theme and appearance settings; and existing transfer, export, backup and recovery surfaces.
- The current app is local and account-free. Opening signup/login, account attachment and Animus transport belong to a later sync workstream.
- Keep exact recorded values, ordering, dates, units and evidence distinctions. Missing or incomplete information must not be presented as a zero or as a medical conclusion.
- The Android installation and owner-storage route remain unqualified. Synthetic Linux tests establish only the tested synthetic Linux behavior.
- Flutter is the existing client implementation. No new runtime, backend or dependency is selected by this product record.

## Brand Commitments

The product name is Alkion, with the existing “Alkion, by Animus” endorsement. The owner selected the established Reps specimen and Animus branding as the UI reference. No new product identity or visual direction is in scope.

## Evidence on Hand

The repository contains the Flutter app, synthetic fixtures, focused widget/workflow tests, and a public workout-tracker visual handoff. Linux synthetic workflows are tested. No real personal data is included in the design fixtures. Android/device, owner-storage, and sync qualification evidence is not yet available.

## Product Principles

- Keep essential workout use available offline and without an account.
- Preserve user-owned workout history and exact recorded values.
- Make incomplete evidence and failed or interrupted operations understandable.
- Add optional sync only through its separate reviewed workstream.

## Accessibility & Inclusion

Use Android-sized touch targets, respect system text scaling and reduced-motion settings, and retain the supported English, German, Spanish and Italian translations. Keep dark and light appearance readable.
