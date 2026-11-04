# Import Reps data

Open **Profile → Data → Import Reps data**, choose an explicitly supplied Reps
full or history export, and review the preview before selecting **Import data**.
The import uses the profile already open in Alkion. There is no separate mode,
profile switch or persistent header.

A full export includes exercise definitions, training days and their exercises,
workouts and sets, bodyweight entries, muscle targets and exported preferences.
A history export contains its supplied workouts, exercise blocks and sets only.
The preview shows the actual dataset counts and source calendar range. It never
reconstructs missing plans, bodyweight, notes or timezone instants.

The **Apply exported preferences** option is off initially. Enabling it applies
only supported, validated preferences from a full export. Without it, the
current preferences remain selected; the original exported settings are still
preserved as evidence.

An optional reviewed mapping sidecar records exact, approximate or unresolved
catalog choices. Approximation and its rationale appear in the preview and in
an imported exercise's History details. Source names and measurements stay
unchanged. A compatible mapping keeps duplicate imported choices out of the
catalog picker; unresolved source exercises remain available. Missing catalog
content is not fabricated.

Choosing a file stages its exact bytes before validation. Only **Import data**
selects source records. Identical-file retry is idempotent. History refuses a different artifact in
its occupied source namespace; mixing full/history exports is also refused.
The full reader retains its existing reimport and correction-preservation
contracts. No automatic overlap matching between full and history is claimed. Imported workouts do not
become native finish or send intents. Finish or discard an active workout
before importing.

After import, settings, catalog choices, History and other screens refresh in
the same profile. A later app launch loads the same mapping metadata.

## Retiring the former separate profile

A successful full import also retires the earlier separate history profile,
when present. This internal compatibility step verifies its fixed location,
marker, parent/profile identities and exclusive closed ownership. It first
creates and verifies an Alkion backup in the current profile's private
`retired-history-backups` directory, then removes only the marked old profile.
Unknown files, links, a mismatched marker or an active owner block removal and
preserve the old bytes. The current profile and selected source files are never
cleanup targets. An interrupted or refused import does not trigger cleanup.

## Evidence limits

Automated checks use synthetic files and disposable local stores. Personal
exports, mapping sidecars and populated stores remain outside repositories and
APK assets. Host checks do not establish phone installation, performance or
owner-storage qualification.
