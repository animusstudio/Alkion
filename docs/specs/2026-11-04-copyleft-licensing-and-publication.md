# Copyleft licensing and preserved publication history

Date: 2026-11-04. Status: **Approved**. Lane: **Full — licensing/publication policy.**
Parent: [development](../alkion/development.md).
Implementation: [plan](../plans/2026-11-04-copyleft-licensing-and-publication.md).

## Outcome and owner direction

Allow reuse and improvements while keeping covered improvements available under
copyleft. Retain the owner's ability to offer separate commercial terms for
rights the owner controls. The owner selected AGPL for code and requested the
equivalent approach for exercise illustrations, replacing the earlier proposal
for noncommercial restrictions.

Publication is on hold. The owner selected preserving unpublished history
privately and preparing a newly licensed snapshot after the current public main.
This is a publication-history choice; no ref replacement or license grant has
yet occurred. The owner approved this spec and plan on 2026-11-04.

## Current evidence

- Public base: `9366452b51e8d9f43a96ed361241ba90337dbc33`.
- Local main: `88b0d2e4626a42ea42d89a6edbf38bf4a4b15307`, clean, 74 commits ahead.
- Both root LICENSE files are MIT, copyright 2026 psychonaut0. Public MIT grants
  remain available. Publishing the unpublished MIT-labelled intermediate
  commits would undermine the intended copyleft boundary for the new work.
- Owner illustrations: 760 WebPs in `app/assets/exercise_artwork/`, currently
  explicitly excluded from software licensing, with no artwork reuse grant.
- Workout Guide artwork has its own CC BY-SA 4.0 attribution and notices;
  bundled fonts and other dependencies retain their own terms.
- The full reviewed runtime passes 2,526 tests with three optional integration
  skips, analysis, formatting and catalog build guards. Source publication does
  not establish Android touch, performance, production recovery or release status.

## Licensing decisions

1. **Owner-controlled software: AGPL-3.0-only.** Use the unmodified official
   GNU Affero GPL version 3 text and clear scope/copyright notices. Compliant
   commercial reuse is permitted. Covered distributions and modified network
   offerings have the applicable corresponding-source obligations. This does
   not require paying, obtaining project affiliation, or submitting upstream PRs.
2. **Owner exercise illustrations: CC BY-SA 4.0.** Propose the standard image
   counterpart: credit, license link, change marking and ShareAlike for shared
   adaptations. Commercial reuse is permitted. Reusing a separate unchanged
   illustration does not itself require an application's source to be opened.
   This choice is explicit in approval; it is not an NC license or a promise
   that every commercial image user must buy permission.
3. **Separate commercial terms remain possible.** Document contact through the
   repository owner and the possibility of a separate written agreement to waive
   applicable owner-controlled copyleft/attribution conditions. Do not publish
   prices, a binding commercial contract, an automatic exception, or a purported
   exception to somebody else's rights. License-compliant users need not pay.
4. **Existing rights remain.** Preserve the exact legacy MIT text/copyright in
   a clearly scoped retained notice. Prior MIT releases and components remain
   available under those grants; current owner additions carry the new policy.
   Preserve all third-party notices and licenses byte-for-byte. Do not relabel
   guide assets, fonts, libraries, models, or trademarks as owner illustrations.
5. **Future contributions are not automatically commercially relicensable.**
   Explain that other contributors retain their copyrights; commercial
   exceptions covering their contributions require the necessary permission.
   Do not invent a contributor assignment or claim that submitting an ordinary
   AGPL contribution silently transfers commercial relicensing rights.
6. **No overclaim.** The policy grants only rights the licensor controls; it does
   not establish ownership or copyrightability by assertion, guarantee an
   exclusive product idea, or revoke compliant existing public permissions.

Sources: [GNU licensing guidance](https://www.gnu.org/licenses/gpl-howto.html),
[selling exceptions](https://www.gnu.org/philosophy/selling-exceptions.html),
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/),
[CC separate arrangements and artistic elements](https://creativecommons.org/faq/),
[changing a project's license](https://opensource.guide/legal/).

## Publication construction and preservation

- Work on the isolated licensing branch; keep canonical main and published refs
  unchanged during policy implementation and candidate preparation.
- Before any local-main replacement, preserve the original main and final
  implementation history under durable local archive refs and a verified local
  Git bundle. Verify the bundle and reopening its history. Do not publish those
  archive refs or old unpublished commits. Preserve existing worktree branches.
- Build a candidate snapshot whose sole parent is the verified public base.
  Its tree must equal the reviewed final local source plus only the approved
  licensing/documentation changes. Retain executable modes, symlinks and assets;
  do not regenerate artwork, change runtime logic, or omit features.
- Preserve old dated qualification records as history, with a current note
  identifying the snapshot as the publication boundary and explaining that
  earlier local qualification SHAs are not promised as public ancestry.
- Prove the old unpublished MIT-labelled commits are not ancestors of the
  candidate. The published base and its history remain ancestors and unchanged.
- Refuse dirty worktrees, changed main/base, missing archives, failed tree/asset
  equality or an unreviewed licensing delta. No force push or remote rewrite.
- Present the final candidate SHA, reviewed range and retained history before
  any irreversible publication. The owner's current publication hold remains
  active until explicit final publication direction.

## Acceptance

- **A1:** Readers can identify software AGPL-3.0-only, owner illustration CC BY-SA
  4.0, retained MIT and third-party exceptions without conflicting current claims.
- **A2:** Official license texts are unmodified; attribution identifies the
  owner, covered paths and stable source/license URLs. All 760 image bytes,
  semantic mappings, registrations, source manifests and reviewed data survive.
- **A3:** Commercial terms describe an option for owner-controlled exceptions;
  no false payment/upstream-affiliation requirement or automatic permission is
  added to AGPL/CC. Contributor and third-party limitations are explicit.
- **A4:** Verified archives retain original unpublished history and worktree
  branches. Candidate ancestry contains the public base and excludes all old
  unpublished MIT-labelled commits; no public history is rewritten.
- **A5:** Snapshot tree differences are limited to the approved licensing/doc
  allowlist; runtime, lockfiles, image hashes, executable modes and symlink
  targets match. Replaying snapshot creation cannot silently overwrite a newer
  ref, reuse a failed receipt or publish additional refs.
- **A6:** Missing/changed public base, dirty state, archive failure or unexpected
  tree differences stop publication with original bytes and refs retained.
- **A7:** Independent design, task, final and exact outgoing reviews pass. No
  remote update occurs while the owner hold is active; approved publication
  changes only remote main through an ordinary fast-forward, without new tags.

## Non-goals

No runtime feature, backend, data-space, profile, device, migration, installation,
signing, release, new remote, price sheet, legal-services claim, trademark grant,
custom AGPL/CC clauses or revocation of existing public MIT permissions.
