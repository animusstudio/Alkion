# Continuing Alkion development

This branch is a clean publication snapshot of the UI/UX source through
`84aa2fd96e6bb5f310d16f6eed9bd663f2248407` (2026-10-26), with the publication
exclusions and setup guidance below. The original development commits and
reference studies remain preserved locally. The snapshot starts from the public
baseline rather than publishing that private development history. It does not
merge main or create a release.

## Fresh checkout

Clone the publication branch and provision FVM, Flutter 3.44.0, Make, Python 3
and Node.js. Android development also needs Java 21 and an Android SDK; Linux
builds need Flutter's Linux desktop prerequisites. From the repository root:

```sh
cd app
fvm install
cd ..
make -C app get-online
make -C app alkion-toolchain
make -C app analyze
make -C app test TEST=--concurrency=2
make -C app format
make -C app build
```

`fvm install` reads the committed Flutter 3.44.0 pin. `get-online` is an explicit
connected bootstrap with the committed dependency lock enforced; it does not
upgrade dependencies. After the cache is populated, use the default offline
`make -C app get`. All local Flutter/Dart execution goes through Make and FVM.
`format` checks only. Builds do not install or launch the app. See the
[app README](../../app/README.md) and [development guide](development.md).

For Android, configure Java 21 and your SDK, then select an explicit disposable
directory for debug signing:

```sh
ANDROID_USER_HOME=/absolute/disposable/alkion-debug-user make -C app build-apk
```

The default package is Alkion Dev. Keep the same disposable debug signer when
updating a test installation. Final signing, a main merge and release remain
separate owner decisions.

## Optional private body artwork

The source bodies, source-specific recipes, textures, derived binaries and masks
are not bundled. A normal source build shows the existing unavailable-artwork
fallback. Fonts, their notices and approved brand assets are included. Private
artwork remains subject to its source terms; local staging grants no rights to
publish models, derivatives or APKs containing them.

If you have the separately supplied approved assets, retain them outside the
checkout. Each style directory must contain `body.mesh.json`, `body.mesh.bin`
and `regions.png`. From the repository root:

```sh
make -C app stage-character-body \
  BODY_MALE_ASSETS=/absolute/private/male/assets \
  BODY_FEMALE_ASSETS=/absolute/private/female/assets
make -C app verify-character-body
ANDROID_USER_HOME=/absolute/disposable/alkion-debug-user \
  ALKION_PRIVATE_BODY_ASSETS=1 ALKION_BODY_PREVIEW_OFFLINE=1 \
  make -C app build-apk-dev
```

The stager checks the six approved hashes and writes only ignored build output.
The private bytes enter an APK only with `ALKION_PRIVATE_BODY_ASSETS=1`; omit it
for a source-only build even if staged files remain on disk. The isolated
synthetic preview is available through `build-character-body-preview`; see
[character-body runtime](character-body-runtime.md) for its explicit opt-ins.

The traced `body-map-study` and contour-derived `body-volume-study` reference
trees are omitted from this publication because their source reuse rights are
unresolved. They remain preserved privately; dated plans and check outcomes
describe those historical trees. The CC0 MakeHuman `body-3d-study` and generic
`body-glb-study` conversion/rendering tools remain in `docs/design/`. The latter
still requires explicit private inputs for source/pose checks and previews.
