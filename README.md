# Flick

Flick is a safe desktop batch file renamer and visual file organizer built with
[Bridra](https://github.com/cluion/bridra). Flutter owns the interface and a
managed Go Sidecar owns file inspection, rename planning, transactional apply,
organization planning, and undo.

## Current MVP

- Add files or scan folders through native pickers and drag and drop
- Filter folder scans with wildcard patterns and optional subfolder traversal
- Combine ordered new-name, replace, prefix, suffix, case, sequence, and trim rules
- Assign one proposed name per item with ordered List rules and TXT/CSV imports
- Target the name, extension, or both with case-sensitive and RE2 regular-expression replacement
- Include or exclude files per rule using name, extension, path, or RE2 conditions
- Preview, search, and visually sort every resulting name without touching the filesystem
- Edit individual proposed names and include or exclude selected preview items in bulk
- Reorder selected items in the processing order used by Sequence and List rules
- Export the current original-to-proposed mapping as CSV
- Detect duplicate names, existing targets, invalid names, and stale files
- Apply a batch through temporary names so swaps and case-only renames are safe
- Persist a local batch journal and undo completed batches
- Restore the last rule recipe automatically
- Arrange files in virtual folders without changing the filesystem
- Classify images, video, audio, documents, archives, and unknown files with an
  explainable content-first detector
- Preview exact final paths, occupied targets, cross-volume moves, and safely
  numbered collision results
- Apply same-volume organization plans as journaled batches and undo them safely

Flick renames regular files in place and can move them into one selected
organization root. Source-folder renaming, cross-volume copy or move, EXIF/ID3
and video metadata rules, JavaScript rules, GPS naming, and CLI automation are
planned follow-up work.

## Safety model

Preview is read-only. Rename and organization Apply both refuse plans containing
errors and check that every source file still matches its preview metadata.
Files first move to unique temporary paths, then to their final paths. The
journal is written before filesystem changes and updated through the
transaction. Undo performs the same checks and staged moves in reverse.

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

- Go module: `github.com/cluion/bridra/backend` `v0.11.0`
- Flutter package: `bridra_flutter` `^0.11.0`
- RPC protocol: `9`

Before changing framework versions:

```bash
cd backend
go run github.com/cluion/bridra/backend/cmd/bridra upgrade --plan --root ..
```
