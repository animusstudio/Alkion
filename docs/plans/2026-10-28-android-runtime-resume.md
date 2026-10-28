# Preserve the Android runtime across Activity recreation

Date: 2026-10-28. Lane: standard Android lifecycle correction.
Status: Approved by owner; implementation in progress.
Base: f2a6e73. Owner reported repeatable profile_in_use after background/reopen.

## Outcome and evidence

Reopening Alkion must reuse the process's existing Flutter runtime and local
store owner when Android recreates its Activity. Preserve all local files,
workout state, restore gates and existing cross-isolate/process lock refusal.
The exact installed error was reproduced on a fresh Android emulator: initial
local setup succeeds, Activity destruction/reopen in the surviving PID fails
with profile_in_use. Immediate ordinary resume alone does not reproduce it.

The current native host destroys its Activity-owned Flutter engine. Raw native
ownership handles and asynchronous SQLite workers can outlive root Dart
teardown in that process. A finalizer-only fix does not establish prompt worker
quiescence or immediate ownership release; do not rely on GC timing.

## Decision and scope

Use one lazily created, application-context Flutter engine per app process,
following the pinned Flutter embedding's supported external-engine lifecycle.
Keep the existing Dart runtime/store alive together through Activity recreation;
ordinary process death still releases native resources normally.

- Register the body factory and application-context identity channel once per
  engine. Reuse that factory for lifecycle calls; never destroy its views merely
  because one Activity is destroyed.
- Give body views an explicitly mutable context. Rebase it on Flutter-view
  attach and reset to application context on detach; pause detached views.
  Keep renderer, geometry, gestures and scores unchanged.
- Keep Documents attached to the current Activity. Cancel/close an old adapter
  on detach, rebind on the new attachment, and guard stale cleanup so it cannot
  clear a newer channel handler or pause the current host.
- Keep one current Activity owner and serialize engine/adapter attachment on
  Android's main thread. Preserve ActivityAware plugin attachment.
- Never clear locks, force-unlock by age, weaken flock, delete user data, change
  schemas, introduce a second writer, or change onboarding/auth product behavior.
  No dependency, public push or production-provider work.

## Acceptance

A1. The captured baseline fails after actual same-process Activity recreation.
The corrected app immediately reopens repeatedly in the same PID with one Dart
runtime/store owner and no profile_in_use or new preflight screen.
A2. Normal Home/resume, root Back/reopen and cold process restart open normally.
An active synthetic draft remains usable across recreation.
A3. Native body factory/view attachment stays coherent with the current Activity;
detached views pause and drop old Activity contexts. Geometry/material unchanged.
A4. Document picker cancellation/interruption after recreation has one bounded
outcome; a stale host cannot remove the new handler. Existing originals remain.
A5. Existing store ownership/exclusive publication checks still pass; no store
or recovery semantics change. Independent review passes the complete fix.

## Task and checks

T1 — One coherent native lifecycle correction and its focused checks.
Work class: standard; implement Sol high, independent review Sol medium.
Own MainActivity, a small engine-scoped native holder if needed, body-view
attach/detach hooks and applicable existing source/native checks. No Dart store
or ownership changes without a new justified proposal.

Use existing Make/FVM and disposable debug signing. Capture actual emulator
commands/stdout/stderr/exit codes with explicit serial. No retired campaign
framework, test provider or broad new harness. Run three immediate forced
recreation cycles, ordinary resume/root return, synthetic draft and picker
cancel checks. Use existing body host/bridge tests and focused ownership/runtime
regressions, plus analyzer and normal APK build. Keep graphics/device limits
explicit; no physical-model performance claim from an emulator.

One independent review of the coherent diff; fixes get fix-only rechecks.
Record execution once at source/artifact hashes. Build the optimized private
Alkion Dev APK with the existing approved assets/signer for the owner-authorized
phone update, without uninstalling or clearing data.

## State

Read-only diagnosis and baseline reproduction complete. Owner approved the
focused fix and data-preserving phone update on 2026-10-28. Next: native implementation,
scratch verification, independent review, then data-preserving phone update.

