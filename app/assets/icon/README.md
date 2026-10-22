# Alkion character launcher artwork

`clean-arm-characters.svg` is the approved 96-column outlined character master.
Glyph paths and their relative placement are retained. There is no sculpture
raster underneath the character form. Font notices are in
[the brand notices](../../../docs/assets/brand/fonts/SpaceMono-OFL.txt).

From the repository root:

```sh
make -C app brand-icons
```

The target uses existing Node/Playwright/Chromium to compose PNG inputs, then
runs the locked `flutter_launcher_icons` 0.14.4 through FVM 3.44.0. If these local
rendering tools live outside normal resolution, set `PLAYWRIGHT_MODULE` and
`CHROMIUM_PATH` to their installed locations. No path is baked into an asset.
No font download or image-generation service is used.

The adaptive foreground is transparent except for the actual glyphs. Its glyph
bounds fit inside the centered 66dp circle of a 108dp layer, with 2% margin.
Black is a separate opaque Android background. Generator inset is explicitly
zero: padding is applied exactly once. The same alpha artwork supplies the
Android monochrome layer. No rounded corners or circle are baked into the input.
Legacy density icons have an opaque black square and the equivalent 72dp-view
scale. The source geometry remains unchanged by both outer compositions.

`generation.json` records composition settings and input/output hashes. CPU
Chromium PNG bytes may vary with renderer versions. Android resources are
regenerated from the checked-in config and inputs; the application manifest and
existing notification initialization both continue resolving `@mipmap/ic_launcher`.
