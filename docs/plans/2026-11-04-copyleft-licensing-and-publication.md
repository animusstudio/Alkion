# Copyleft licensing and publication snapshot

Date: 2026-11-04. Lane: **Full — licensing/publication policy.**
Status: **Approved**; independent design review PASS; owner approved on 2026-11-04.
Parent: [development](../alkion/development.md).
Acceptance: [specification A1–A7](../specs/2026-11-04-copyleft-licensing-and-publication.md).

## Outcome and key decisions

Use AGPL-3.0-only for owner-controlled code and CC BY-SA 4.0 for the
owner's exercise illustrations, with separate commercial arrangements possible.
These licenses permit compliant commercial reuse without payment or mandatory
upstream affiliation. CC image ShareAlike covers shared adaptations, not every
application displaying an unchanged independent image. Third-party and legacy
permissions remain intact; no rights in others' contributions are presumed.

The owner chose to preserve the 74 unpublished commits privately and publish a
newly licensed snapshot after the current public base. Preparation preserves
all original work; replacing local unpublished main history needs this plan's
explicit approval. Remote history is never rewritten or force-pushed.

## Ordered tasks and ownership

1. **T1 — License scope and notices (A1–A3); full-lane policy/docs.**
   Own root LICENSE, a retained legacy MIT notice, owner-artwork license/notice,
   README, a current licensing/commercial-options contract, minimal AGENTS
   alignment and current media/development/status references. Inspect provenance
   and third-party obligations; retain their exact terms and old dated records.
   Fetch official standard texts, verify their bytes, clearly scope grants and
   contributor limits. Avoid custom public license clauses or a binding sales
   agreement. Keep runtime code, metadata identity and assets unchanged.
   Check links, license text identity, scope consistency and all image hashes.
2. **T2 — Reproducible snapshot and retained history (A4–A6); full-lane
   publication/Git.** After T1 review, the coordinator owns serial Git/ref work;
   an assigned worker may prepare read-only inventory/equality evidence.
   Record exact source/base SHAs; preserve local archive refs and a verified
   Git bundle. Prepare a new single-parent candidate over public base, carrying
   the final tree plus reviewed policy changes. Compare all paths, bytes, modes,
   symlinks, lockfiles and asset manifests against the approved allowlist.
   Verify every old outgoing commit is absent from candidate ancestry; retain
   public ancestry. Fail closed on drift or dirty state. Do not publish archives.
   Only after approved evidence, replace local unpublished main with candidate
   without changing remote refs, retaining the original refs/bundle for recovery.
3. **T3 — Final qualification and publication handoff (A1–A7); full-lane review.**
   Independently review T1 and T2, recheck fix diffs and final acceptance. Reuse
   unchanged runtime receipts only after full-tree comparison, and run affected
   notice/media/build checks. Run final `outgoing` and publisher dry run against
   exact candidate/base. Present the candidate SHA, license choices, scope and
   current limits for final owner publication direction. Keep hold active until
   that direction. Follow the established public publication helper and verify
   that only remote main changes; no tags or archive branches are pushed.

Implementers do not re-delegate; coordinator serializes Git. Routing uses the
full policy/publication class for implementation and independent review.

## Required evidence and checks

- Immutable before/after refs and a verified original-history bundle, plus a
  test reopen proving original commits/tree objects are retained.
- Official text identity; retained MIT/third-party text hashes; README/notice/
  current-contract consistency; no false blanket MIT, NC or commercial-fee claim.
- Exact 760 owner image hashes and all guide asset/notices preserved;
  `python3 app/tool/prepare_exercise_artwork.py` and
  `python3 app/tool/prepare_workout_guide_media.py` remain valid.
- Whole-tree content/mode/symlink comparison with an explicit policy/docs
  allowlist and ancestry checks, including drift/dirty-state refusal before
  any local ref replacement or public action. No source history rewrite occurs
  until owner approval explicitly covers the local snapshot approach.
- Reuse at runtime tree `88b0d2e`: full Flutter suite 2,526 PASS / three optional
  skips / zero failures; analysis zero issues; format 499 unchanged files;
  catalog build guards PASS. If runtime/build inputs change, rerun only the
  affected checks via the pinned Make routes; no unrelated dependency updates.
- Exact outgoing leak scan, no-new-tags and sole-main remote-ref verification.
  Verify concrete candidate/ref-drift protection before publication; resolving
  an approved SHA and later pushing a mutable branch is not sufficient binding.
  A proposed new snapshot identity is not itself proof of rendering, Android
  performance, real recovery or release qualification.

## Owner gates and current state

The policy/snapshot implementation starts only after design review and owner
approval. Approval must cover AGPL-3.0-only, owner images CC BY-SA 4.0, retained
MIT/third-party permissions, and preservation/replacement of local unpublished
history. It grants no automatic exception to other contributors' rights.
The owner's publication hold requires final direction on the reviewed candidate
before any push. No remote force push, old-history deletion or public archive
publication is included.

Planning inspected source, license history, author labels, image notices and
current remote/local ranges. Independent design review at `34e043f`: PASS, no
findings; publisher ref-drift protection remains an implementation check under
A5/A6. Approval includes the image license and preservation/replacement of local
unpublished history. T1 implemented at `13ee92e`, with the source-file scope
clarification at `7adc207`; independent task/fix review PASS, no remaining findings.
Official AGPL/CC texts and retained MIT bytes match their sources. Both media
validators and 14 preparation tests PASS; all 760 images, 15 third-party notices
and 2,692 runtime/build/asset paths are unchanged. The sole whitespace exception
is the official CC text's extra EOF blank line, retained for byte identity.
T2 preservation and candidate qualification PASS: a complete private bundle
reopens independently, all 74 original outgoing commits are retained privately
and excluded from candidate ancestry, and the candidate has one public-base
parent with exactly the qualified source tree. Only 15 approved policy/doc paths
differ from the original main; 2,932 other paths retain bytes and modes.
Independent preliminary T2 review PASS. The actual Git-ref lock guard passes
16 rehearsal cases, including an official publisher fetch/dry run while ordinary
Git writers are excluded. Final source/candidate pins and bundle proof must be
refreshed for this receipt before the expected-old local-main transition.
T3 remains gated by final candidate qualification and owner publication direction.
Next: exact candidate handoff with publication hold active.
