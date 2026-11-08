# Import Reps data (retired)

Retired 2026-11-08 by the [legacy removal plan](../plans/2026-11-08-legacy-removal.md).
Alkion no longer has an in-app Reps importer: Profile → Data has no
**Import Reps data** entry, and the app has no import screen or in-app mapping
review. A planned external migration tool will move Reps history into Alkion;
it gets its own plan.

Until then, the host-side `make -C app alkion-import-history` route builds a
fresh Alkion profile and verified backup from an explicitly supplied history
file and optional reviewed mapping, outside the app. See
[transfer](transfer.md).

Profiles that already hold imported history and stored mappings open
unchanged. History and the catalog picker still read those stored mappings for
display; nothing is migrated or deleted.

The earlier guide, describing the 2026-11-01 in-app flow, remains in this
file's git history and in the dated [acceptance record](acceptance.md).
