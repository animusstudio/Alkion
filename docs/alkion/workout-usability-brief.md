# Workout usability alignment

Parent: [development](development.md). Direction: [approved design](../specs/2026-11-01-usability-and-history-test.md).

Operate mode: a person holding an Android phone between sets must find an exercise,
adjust its current set, log it, rest and resume with the established focused card.
The existing live-workout reference and shared rulers govern the visual hierarchy.
One focused set, compact other rows, last-session context and pinned Log/Finish
remain consistent across legacy and catalog exercises. Missing values stay unset.

Workout actions belong to the workout menu; setup/order/removal to the exercise;
correction/warm-up/deletion to the set. Logged deletion confirms and offers Undo.
Catalog selection begins with results. Views and filters have separate scope.
Training preferences own RIR, rep presentation and rest; Appearance owns units.

Source baseline `09cc85c` confirms the missing-value typed-entry path and sampled
preferences. The installed owner APK was unavailable for comparison. Host tests
and native captures are separate evidence; the acceptance record owns results.
