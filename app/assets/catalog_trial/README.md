# Private catalog assets

This public placeholder contains no catalog corpus. Ordinary Flutter builds
declare this README alone. `make -C app stage-catalog` projects an explicit
hash-pinned private input into ignored `*.dev.json` files, and
`make -C app stage-catalog-dev` admits them for the guarded private Dev build.
The directory keeps its historical name because staged inputs and packaged Dev
APKs use this path. Staging does not grant publication or redistribution rights.
