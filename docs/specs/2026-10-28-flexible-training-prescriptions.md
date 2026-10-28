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
Day weekday assignment is optional, with flexible training as the initial path.

Inspected baseline: `29f136a`. Exercise/slot rep and RIR bounds are already
nullable, and equal rep bounds can represent fixed reps. However, exercise
creation starts with populated prescription values, editors expose two rep/RIR
bounds, summaries always print rep ranges, resolution supplies RIR 1 when absent,
and new working sets record RIR 1 without user input. A null slot RIR also inherits
exercise defaults, so clearing bounds cannot reliably express an opt-out.
Weekday storage is already nullable; the day editor nevertheless always exposes
seven weekday chips. Today recommends the next day by saved order/history, not
by calendar weekday. Profile-scoped revisioned local preferences already exist.

## Product decisions

- Add **Profile → Training preferences**, one optional entry using the existing
  settings components. Do not require a setup questionnaire or a new destination.
  Its compact choices are:

  | Preference | Initial choice | Effect on new items |
  | --- | --- | --- |
  | Rep entry | Fixed reps | Initial slot rep controls when no exercise defaults exist |
  | RIR controls | Off | RIR stays behind More options; Show offers target controls |

  Scheduling is contextual: every day permits no weekday and offers Add weekday.
  It needs no separate global disclosure preference or calendar scheduling mode.
  Existing rest
  preferences retain their values and behavior; Advanced is always initially
  collapsed and needs no additional preference.
- These are profile-scoped creation defaults, captured when an editor/new slot
  opens. Changing them affects later creation only, never saved prescriptions,
  open editors, drafts, current workouts or history. Saved values remain visible
  regardless of preferences: an existing rep range, RIR target/observation or
  assigned weekday cannot disappear behind a global Off choice. Do not introduce
  a second preferences layer for each split or exercise. Local edits are ordinary
  prescription/day data, without a live global inheritance chain.
- The normal day editor shows name, exercises and sets/reps. An unscheduled day
  offers **Add weekday**; an assigned weekday is visible with Change/Remove.
  The picker opens with nothing selected when the day has no assignment.
  Picking/removing a weekday is an explicit dirty-tracked edit; merely revealing
  or dismissing the picker preserves null. Day order and manual workout choice
  remain available; Today retains its current next-in-order recommendation.
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
  choices plus an unset state. A new slot without rep defaults starts at fixed 8
  or range 8–12 according to Rep entry; either uses the existing three-set fallback.
  The default preference is fixed. Valid exercise defaults take precedence;
  existing complete range prescriptions retain their range. Changing modes is an
  explicit edit, reflected in Save and discard handling.
- RIR means repetitions in reserve. An optional short explanation is available;
  understanding it is never a prerequisite for creating a routine or logging.
  Exercise RIR defaults start unset and are explicitly enabled/cleared.
- Routine RIR has three semantics: **Use exercise default**, **Off**, and an
  explicit target (single value or range). Inheritance with no exercise target
  resolves to no RIR; there is no hardcoded RIR target. Off suppresses inherited
  targets even if the exercise default changes later. With RIR controls Off, new
  slots use saved Off policy; Show initializes Use exercise default, resolving to
  no target if the exercise lacks one. Never invent a numeric RIR to populate it.
  Keep these semantics out of the normal path: **More options → Add RIR target**
  reveals controls when absent, and Remove explicitly saves Off. Existing targets
  stay visible and editable. Advanced options can return to Use exercise default.
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

The two preferences use the existing local semantic-settings snapshot, its
revision/retry/flush behavior and native backup. Missing keys get the initial
choices; changing one preference preserves the other settings. They do not
introduce new workout/outbox fields. New slots persist the resulting RIR policy
and concrete rep values so future preference changes cannot reinterpret them.
Exercise creation still saves unset prescription defaults, regardless of these
preferences. Scheduling continues to use the existing nullable weekday field.

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
**A8.** Preference changes persist/retry/reopen and survive native backup/restore
within the current profile. A second profile is unaffected. Missing preference
keys get simple defaults; unrelated settings retain their values. Creation uses
the captured defaults, while existing days/slots, open editors, active/resumed
workouts, actual RIR and history do not change or become hidden.
**A9.** Create/save/reopen a day without choosing a weekday. Add, change and remove
one explicitly; null and assigned values survive unrelated edits and restore.
Revealing the picker is not dirty. Assigned weekdays remain visible regardless of
training preferences. Rotation/manual choice still work as before.

## Non-goals

No exercise catalog, search, equipment identity or dataset work. This first slice
does not introduce supersets, circuits, drop sets, per-set varying prescriptions,
timed/distance training, split presets or a calendar-based recommendation engine.
Optional weekday disclosure does not change rotation. No automatic
progression redesign, historical observation rewrite, account/sync/backend work,
release or publication. These need their own concrete product scope.
