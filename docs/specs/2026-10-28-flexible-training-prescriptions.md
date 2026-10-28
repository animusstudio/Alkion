# Flexible training prescriptions

Date: 2026-10-28. Status: Proposed. Lane: Full, because explicit RIR opt-out
needs persisted semantics and forward-compatible store/recovery handling.
Implementation is gated on owner approval of the [plan](../plans/2026-10-28-flexible-training-prescriptions.md).
Boundaries: [repository guidance](../../AGENTS.md).

## Outcome and observed behavior

Support ordinary fixed-rep training such as 3×8 alongside ranges such as 3×8–12,
without requiring knowledge of RIR. Creating an exercise should capture its
identity; reusable prescription defaults and starting weight are optional.
Exercise dataset/search changes are a separate workstream.

Inspected baseline: `29f136a`. Exercise/slot rep and RIR bounds are already
nullable, and equal rep bounds can represent fixed reps. However, exercise
creation starts with populated prescription values, editors expose two rep/RIR
bounds, summaries always print rep ranges, resolution supplies RIR 1 when absent,
and new working sets record RIR 1 without user input. A null slot RIR also inherits
exercise defaults, so clearing bounds cannot reliably express an opt-out.

## Product decisions

- Exercise create/edit keeps its current identity fields. A collapsed **Advanced**
  accordion contains starting weight, default prescription and related training
  settings. Its helper explains that these are optional and adjustable in a
  routine. Existing training controls outside these groups retain their roles.
- Opening/closing Advanced changes no saved data and does not mark the editor
  dirty. New exercises save absent defaults as null. Existing nulls, zero warmups,
  exact weight evidence and untouched values retain their distinctions. Each
  optional default can be cleared independently; zero is not an absence sentinel.
- A routine slot offers **Fixed reps** and **Rep range**. Fixed reps has one value;
  it writes equal low/high bounds and renders 3×8, never 3×8–8. Ranges retain two
  ordered values and render 3×8–12. Optional exercise rep defaults offer the same
  choices plus an unset state. A new slot without rep defaults starts at fixed 8;
  existing complete range prescriptions retain their range. Changing modes is an
  explicit edit, reflected in Save and discard handling.
- RIR means repetitions in reserve. An optional short explanation is available;
  understanding it is never a prerequisite for creating a routine or logging.
  Exercise RIR defaults start unset and are explicitly enabled/cleared.
- Routine RIR has three semantics: **Use exercise default**, **Off**, and an
  explicit target (single value or range). Inheritance with no exercise target
  resolves to no RIR; there is no hardcoded RIR target. Off suppresses inherited
  targets even if the exercise default changes later. New slots default to Off;
  people deliberately reusing exercise defaults can select inheritance.
- Targets and observations are separate. Every new actual set starts with null
  RIR, including when a target exists. Logging without RIR is valid. Off/no-target
  workouts do not automatically open the RIR prompt. An optional set action can
  still add, edit or clear actual RIR; existing recorded values stay visible.
  A target may offer the existing optional prompt but never blocks logging.
- Summaries in the day editor, routine/Today surfaces, workout block and any other
  prescription consumer share fixed/range and optional-RIR presentation rules.
  Preserve established components, typography, themes and logging controls.

## Persistence and compatibility

Add an explicit slot RIR policy using a forward store migration. Null/legacy
policy means the prior inheritance behavior; new explicit policies express Off
and Target. Do not encode Off as RIR zero, negative bounds or rep sentinels.
Policy must flow through models, drafts, dirty snapshots, prepared domain actions,
revision payloads, projection and export/restore. Retain the policy in local
action/outbox evidence for a future mapping; implementing that mapping is out of scope.
Old immutable operations, source bytes and revisions remain byte-identical.
No new sender or protocol claim follows from a local field.

Keep the frozen `reps-export/1` input/projection policy unchanged. Existing Alkion
domain output and native backup carry the new policy with their schema/version
metadata, and supported native restore preserves it. Compatibility transfer
export must refuse a policy it cannot represent, with an explanation and a native
backup alternative; it must never silently drop Off and re-enable inherited RIR
on reimport. Do not add a new interchange format or legacy decoder behavior merely
to keep the compatibility export available.

Old slots retain explicit RIR targets and inheritance; only the undocumented
hardcoded RIR-1 fallback disappears. Complete existing rep prescriptions are not
converted on opening/saving. Partial, inverted, out-of-range or unknown inputs
retain their raw evidence on untouched save; show an unavailable/repair state
where necessary, rather than constructing a target from unrelated bounds.
Do not rewrite existing set observations or in-flight workout prescriptions.
Old drafts with required numeric RIR bounds remain readable; new drafts can
represent absent targets. Resume preserves set IDs/order, exact observations,
pending intent and timers. Backup/restore preserves the policy and absent values;
older exports without it retain legacy semantics. Unsupported newer stores or
unknown policy values retain bytes and fail closed rather than silently enabling
RIR. Migration admission, rollback and repeated-open behavior must be exercised
on disposable populated version-1 and current version-3 stores, including restore
of a prior version-3 backup, without editing their recorded migration digests.

## Acceptance

**A1.** Create an exercise without expanding Advanced: all optional training
defaults and starting weight remain absent after save/reopen. Expand/collapse and
an unrelated name edit preserve existing exact values and nulls.
**A2.** Create, edit, save and reopen fixed 3×8 and ranged 3×8–12 slots/defaults.
Their summaries agree across planning, Today and a started/resumed workout.
**A3.** Off survives save/reopen and wins over present or later exercise RIR
defaults. Inherit and explicit targets remain distinguishable and work as chosen.
No target is invented when both levels lack one.
**A4.** A new working set never claims observed RIR before user entry. Off/no-target
logging needs only the existing log action; optional manual RIR entry/clear works.
Warmups, target-enabled optional prompting and existing recorded RIR still work.
**A5.** Mode/value edits trigger discard protection; opening Advanced does not.
Keyboard edits commit before save, and pending/retried actions retain their exact
intent through these new fields.
**A6.** Upgrade/reopen, backup/restore, old export import and old/new draft resume
preserve IDs, exact evidence, explicit targets, policy and atomic data/outbox
writes. Failed/repeated migration and two-profile cases neither partially apply
nor cross profiles. Unknown/newer values retain the existing recovery boundary.
Native output retains policy; compatibility export refuses unrepresentable
policies before producing a misleading artifact. Legacy decoding stays frozen.
**A7.** EN/DE/ES/IT, both themes, 320/412dp, large text, 48dp touch targets,
expanded/selected accessibility semantics and Android Back remain usable.

## Non-goals

No exercise catalog, search, equipment identity or dataset work. This first slice
does not introduce supersets, circuits, drop sets, per-set varying prescriptions,
timed/distance training, split presets or calendar/rotation redesign. No automatic
progression redesign, historical observation rewrite, account/sync/backend work,
release or publication. These need their own concrete product scope.
