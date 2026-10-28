# Flexible training prescriptions

Date: 2026-10-28. Lane: Full. Status: **Proposed; awaiting owner approval.**
Base: `29f136a`. Branch: `feat/training-prescriptions-20261028`.
Contract: [specification](../specs/2026-10-28-flexible-training-prescriptions.md).
Boundary: [repository guidance](../../AGENTS.md).

## Outcome and decisions

Make fixed reps and optional RIR normal paths, and move optional exercise
prescriptions/starting weight into a collapsed Advanced accordion. Keep exercise
dataset work independent. Existing rep bounds represent fixed reps when equal;
an explicit persisted RIR policy distinguishes Off from inheritance. This store
compatibility change uses the full lane; no speculative training engine is added.

Acceptance A1–A7 is defined in the spec. Main risks are unintended inheritance,
fabricated actual RIR, nulls materialized by editor defaults, and compatibility
across stores/drafts/backups. Preserve the current visual system and essential
local action/recovery boundaries.

## Tasks

1. **T1 — RIR policy and compatibility (A3, A6).** Full-lane implementer owns
   `app/lib/store/`, `domain/`, relevant `data/`, `export/`, `transfer/`, `recovery/` and their
   focused tests/contracts. Introduce the forward migration without replacing
   version-1 history; carry policy through immutable actions and supported backup/
   transfer paths. Resolve RIR as an optional pair, removing only the synthetic
   fallback. Keep unknown/partial legacy evidence untouched. Prove populated-v1
   and current-v3 upgrade, prior-v3-backup restore, failure rollback/reopen,
   idempotency and isolation. Preserve policy in native output/backup and refuse
   unrepresentable compatibility transfer export; test preservation/refusal.
   Keep the legacy `full_v1.dart` projection policy frozen.
   Coordinate the nullable resolved-slot API with T3 before committing a coherent
   compiling task. Do not add compatibility fields to frozen legacy services.
2. **T2 — Exercise and routine editors (A1–A3, A5, A7).** Standard Flutter
   implementer owns `ui/exercise_editor.dart`, `ui/day_editor.dart`,
   `ui/editor_guard.dart`, shared prescription controls/formatting as needed,
   localization sources/generated output and focused UI/layout tests. Implement
   Advanced, truly optional defaults, fixed/range choice and Off/inherit/target
   RIR. Do not materialize hidden values. Update every changed field's dirty and
   pending-action handling. Keep actual storage/action contracts from T1.
3. **T3 — Workout and summary consumers (A2–A4, A6).** Standard Flutter
   implementer owns `session/`, prescription consumers in Today/Plan and focused
   controller/draft/resume/widget tests. Distinguish target from observation;
   new sets use null actual RIR, logging never requires it, and Off/no-target
   avoids automatic prompting. Retain optional actual-RIR entry/clear. Read old
   and new drafts without changing already recorded sets or in-flight targets;
   cover added sets/exercises and resumed sessions as well as fresh starts.
4. **T4 — Integrated qualification and acceptance (A1–A7).** Coordinator runs
   integrated checks and one batched native/layout visual inspection in disposable
   storage. Reviewer independently checks final acceptance and evidence. Update
   `docs/alkion/acceptance.md` and current contract docs with bounded results.
   Report Android interaction as unrun if no explicit disposable device is used.

Tasks run sequentially because they share models and session callers. Implementers
do not re-delegate. Route full work to `gpt-6.1-sol` xhigh, standard code to
`gpt-6.1-sol` high; independent review high for full and medium for standard work.
Independent design review precedes implementation; every task and the integrated
change receive independent review, with fix-diff rechecks only.

## Checks and delivery

- Focused real-SQLite migration/domain/recovery tests for T1; editor/save/discard,
  fixed/range and RIR matrix for T2; fresh/log/add/resume/draft tests for T3.
- Run Flutter/Dart through `make -C app`; use `fmt FORMAT_FILES=...` only on owned
  files. Integrated `make -C app analyze`, `make -C app format`,
  `make -C app test TEST=--concurrency=2` and `make -C app build`.
- Record commands/results at exact commits once; a failed
  or unavailable gate stays open. Do not treat host tests as Android evidence.
- Inspect both themes, narrow/enlarged text, Advanced open/closed and fixed/range/
  RIR states in one batched pass; one correction/confirmation pass if needed.
- Stage by filename and commit on this branch. No public push is authorized.
  Exact outgoing-range review and owner approval precede any public publication;
  no tag, release, deployment or dataset integration is part of this plan.

## State and next

- Planning: source/callers/tests and parallel checkout state inspected; proposal
  written in an isolated current-Alkion worktree. Independent design review PASS
  after export compatibility, current-v3 upgrade and transport-scope corrections;
  reviewer `prescription_design_review`, 2026-10-28, no remaining findings.
- T1–T4: Not started. No runtime files changed.
- Checks: local Markdown references/whitespace PASS on the final proposal files;
  `git diff --check` PASS. No runtime checks needed for this docs-only proposal.
- Next: obtain owner approval of this concrete scope before T1.
