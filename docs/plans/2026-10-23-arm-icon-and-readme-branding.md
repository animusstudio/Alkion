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

T1: implementation and focused verification complete at `672181e`; independent
review pending.
Source baseline `f6b54f9`; early implementation `2c0155c`.
Next: independent task/outgoing review; then prepare
the exact outgoing range for owner-run publication.

Implemented the approved 96-column character arm, separate transparent adaptive
foreground/black background, monochrome layer and all five existing Android
launcher densities. Generator inset is zero; measured glyph bounds determine a
single safe-circle composition. The README displays the 96-column character bust
and Alkion/by Animus banner, with the unchanged legacy factual body grouped under
Legacy Reps reference. Notices and public regeneration metadata are retained.

Focused source/geometry, alpha/native resource, README and reproduction checks
passed. All 20 regenerated input/resource/metadata files reproduced byte-for-byte.
Foreground alpha radii are 32.27–32.60dp inside the 33dp safe radius at every
density. The normal manifest and existing notification initialization still
resolve `@mipmap/ic_launcher`. Local README and icon-mask desktop/mobile captures
passed; one private transparency-canvas correction improved white-glyph visibility
without changing product assets. No native launcher/device behavior is claimed.

`make -C app alkion-toolchain` confirmed FVM Flutter 3.44.0 / Dart 3.12.0;
locked offline `get`, `analyze` (0 issues) and full `test TEST=--concurrency=2`
(1453 passed, 0 skipped) passed. Android debug packaging passed, followed by a
15-resource pixel comparison against the APK and adaptive-layer inspection.
Application ID/version remain `dev.animusstudio.alkion.dev` / `0.18.1+37`.
The [acceptance record](../alkion/acceptance.md) owns the final receipt summary.
