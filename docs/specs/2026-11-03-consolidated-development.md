# Consolidated development baseline

Status: Approved by owner direction to merge current work, 2026-11-03.

## Outcome

Combine the completed usability/history, catalog UI, offline exercise media and
foreground server-recovery changes into one clean development baseline.

## Decisions and boundaries

Preserve existing commits with merge commits. The combined UI/media head is
`eaaef35068c801047161ab4f59e12c4e9745d562`; the recovery head is
`d087c80da76357346e8d626040ac5b22ab3bda17`. Both descend from published
`09cc85c0b934ee82c9318fd2db402df70c95f8fb`.

The public delivery base subsequently advanced to
`9366452b51e8d9f43a96ed361241ba90337dbc33` with the catalog staging guidance
refresh. Preserve that documentation by merging it into the consolidation; the
two reviewed feature inputs and their common base above remain unchanged.

Resolve overlapping startup, localization, recovery and acceptance changes by
retaining both features and their documented restrictions. Follow root and app
AGENTS.md. No new product scope, automatic sending, live migration, device
operation or release is authorized by this consolidation.

Old design branches remain historical references. Performance experiment
instrumentation is preserved separately rather than enabled in ordinary builds.

## Acceptance

- A1: Both input heads are ancestors of the consolidated branch.
- A2: Existing offline startup and profile/history workflows remain usable.
- A3: Recovery retains uncertain intent, review barriers and schema compatibility.
- A4: Catalog UI and bundled media remain available with their notices.
- A5: Analyzer, full host tests and affected asset checks pass; unrelated existing
  limitations are reported explicitly. Host evidence does not qualify devices.
- A6: Independent integration and exact outgoing-range review pass before public
  publication. Publication remains subject to exact-range owner approval.
