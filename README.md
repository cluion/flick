# Flick

Flick is a safe desktop batch file renamer built with
[Bridra](https://github.com/cluion/bridra). Flutter owns the interface and a
managed Go Sidecar owns file inspection, rename planning, transactional apply,
and undo.

## Current MVP

- Add files or scan folders through native pickers and drag and drop
- Filter folder scans with wildcard patterns and optional subfolder traversal
- Combine ordered new-name, replace, prefix, suffix, case, sequence, and trim rules
- Preview every resulting name without touching the filesystem
- Detect duplicate names, existing targets, invalid names, and stale files
- Apply a batch through temporary names so swaps and case-only renames are safe
- Persist a local batch journal and undo completed batches
- Restore the last rule recipe automatically

The MVP renames regular files in place. Folder contents can be imported, but
folder renaming, EXIF/ID3/video tags, copy and move modes, JavaScript rules, GPS
naming, and CLI automation are planned follow-up work.

## Safety model

Preview is read-only. Apply refuses any plan containing an error and checks that
every source file still matches its preview metadata. Files first move to unique
temporary paths, then to their final paths. The journal is written before the
filesystem changes and updated through the transaction. Undo performs the same
checks and two-phase move in reverse.

## Development

Requirements: Go 1.25+, FVM 4.x, Flutter 3.44.6, and the native toolchain for
the selected desktop target.

```bash
fvm install
fvm flutter pub get
make doctor
make verify
make run
```

Generate typed Go and Dart RPC contracts after changing
[`schema/bridra.json`](schema/bridra.json):

```bash
make generate
make codegen-check
```

Build a desktop bundle with its Go Sidecar:

```bash
make macos-build
make linux-build
make windows-build
```

Set `BUILD_MODE=debug`, `profile`, or `release`. Successful builds write a
token-free SHA-256 manifest under `build/bridra/`.

## Bridra dependency

- Go module: `github.com/cluion/bridra/backend` `v0.8.0`
- Flutter package: `bridra_flutter` `^0.8.0`
- RPC protocol: `1`

Before changing framework versions:

```bash
cd backend
go run github.com/cluion/bridra/backend/cmd/bridra upgrade --plan --root ..
```
