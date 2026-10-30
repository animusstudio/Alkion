# Native finish rejection capture

Exact synthetic app-generated request and actual API reply bodies captured on
2026-10-30. Definition create returned 200; finish returned 400 with
`malformed_value`. The finish incorrectly supplies explicit null notes when its
original local finish input has no notes member. Missing, empty and populated
strings are distinct; explicit null is unsupported by the public workout patch.
These bodies retain their captured bytes. They contain no origin, credentials or
owner data. Tests may substitute UUIDs consistently and must account for the
mapping. The rejected finish is evidence, not a corrected-success golden.

Production typed command preparation measured the original finish at 7,419
canonical bytes (SHA-256
`91fb381e8185f8484387689529eb0dbe7b4ec350a267caf74e5d2822be2381f2`).
Removing only `workout.workout.notes` produces 7,415 canonical bytes (SHA-256
`880f76fd6b3053ee558e4610c66bffdddb032744d00802e1c3a3e22947b8a550`).
The pure workout application rejects the original null and accepts omission or
explicit empty text. This differential is not an HTTP success or device claim.
