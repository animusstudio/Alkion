# Alkion arm icon and README branding

Status: **Approved** by the owner's 2026-10-23 implementation request.
The README endorsement was clarified as **Alkion by Animus**.
Lane: standard. Work class: standard asset/build integration and documentation.

## Outcome

Replace the inherited Reps launcher artwork with the approved clean flexed arm
in actual character style. Introduce the retained character bust beside the
Alkion name and Animus endorsement in the root README. Keep the existing legacy
README information clearly distinguished from the current Alkion branding.

## Decisions and scope

- Use the approved character masters without generating new artwork or switching
  to sculpture, exposed muscle, engraving or the experimental coarse treatment.
- Android is the scaffolded product platform. Generate all existing legacy
  launcher densities and an adaptive icon with a transparent character foreground,
  opaque black background and preserved complete arm outline under launcher masks.
- Keep font notices with the outlined glyph assets. Only approved brand assets
  and publishable reproduction metadata enter this public repository.
- Add a repository-local bust/name/endorsement banner; preserve factual README
  content, existing legacy boundaries and the development application identity.
- Reuse the pinned launcher generator and existing local rendering tools. Keep
  generation reproducible from the retained vector source and checked-in config.
- No screen redesign, platform scaffolding, package/signing/version change,
  backend/data/sync change, device install, tag, release or deployment.
- Public publication follows exact-range independent review and owner approval.

## Acceptance

- **A1:** The normal Android manifest resolves to regenerated arm-character
  launcher resources at every existing density. No active launcher uses Reps art.
- **A2:** Adaptive foreground is transparent outside the actual glyphs; its
  composition retains the complete arm under circle and rounded-square masks.
  The opaque background remains separate. No baked rounded corners or raster
  sculpture underlays are introduced.
- **A3:** Root README presents the character bust with the exact Alkion name and
  by Animus endorsement. All images load through repository-local relative paths;
  alt text is useful and the existing legacy description remains clearly labeled.
- **A4:** Source geometry, local notices and reproducible generation instructions
  are retained. Generated outputs match their declared dimensions and references.
  No private guidance, prompts, paths, credentials or unrelated assets are copied.
- **A5:** Focused asset/resource and desktop/mobile README visual checks pass,
  together with applicable pinned-toolchain analysis/tests and an Android debug
  packaging check. Report build/device evidence honestly. No device is modified.
- **A6:** One independent task review covers the complete implementation and
  outgoing public range; fixes receive a bounded recheck before owner handoff.

## Task

**T1 — Integrate approved artwork.** Own `app/assets/icon/`, launcher config,
generated Android launcher resources, a narrow generation target/helper,
`README.md`, approved README assets and their font notices, this plan and the
public acceptance record. Avoid unrelated UI worktrees. Commit early; preserve
the original source geometry and the rejected historical material outside the
active asset set. Focused checks: source/output hashes and geometry, alpha and
safe-region bounds, native resource references, generator reproducibility,
circle/squircle visual specimens, desktop/mobile README, analysis/tests and APK
packaging through the pinned Make/FVM route. Use repository check receipts.

## Task state

T1: in progress. Source baseline `f6b54f9`.
Next: implementation, bounded validation and independent review; then prepare
the exact outgoing range for owner-run publication.
