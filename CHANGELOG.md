# Changelog

All notable changes to Flick are documented in this file.

## Unreleased

### Added

- A safe collision strategy that appends `(2)`, `(3)`, and later numbers before
  the file extension while preserving the original file
- Exact collision-resolved names and status badges in the live preview
- A preview-only visual organization workspace with virtual folders, safe folder
  name validation, drag-and-drop placement, and live final-path previews
- A Go-backed organization safety preview with stable source snapshots, folder
  creation dependencies, target-conflict detection, existing-folder reuse, and
  cross-volume classification
- Expiring organization plans and a versioned, atomically written filesystem
  operation journal that revalidates sources, destinations, and volume identity
  before any future apply step

### Changed

- Advanced the rename preview contract to RPC Protocol 4 so the selected
  collision strategy and resolved items are explicit across Flutter and Go
- Advanced the workspace contract to RPC Protocol 5 for backend-validated
  organization plans without enabling filesystem changes

## 0.3.0 - 2026-08-06

### Added

- Save and reload portable `.flicklist` workspace file lists
- Reveal preview items in the platform file manager, copy their full paths, or
  remove them directly from the workspace
- Save, duplicate, rename, delete, import, and export named rule presets
- Safe starter presets for common numbering, cleanup, camera-prefix, and
  extension workflows
- A separate recent-rule configuration history that does not affect filesystem
  rename undo history
- Versioned `.flickrecipe` rule-chain files with migration support for legacy
  unversioned recipes

### Changed

- Upgraded the Bridra Go and Flutter runtimes together from 0.10.1 to 0.11.0

## 0.2.1 - 2026-08-05

### Added

- Selected-item processing-order controls that immediately recalculate Sequence
  and List rule previews

### Changed

- Upgraded the Bridra Go and Flutter runtimes together from 0.9.0 to 0.10.1
- Clarified that preview checkboxes control rename inclusion while row selection
  controls bulk actions

### Fixed

- Prevented compact desktop windows from clipping or overflowing the empty
  preview workspace, with an 800 by 640 minimum window size on every platform

## 0.2.0 - 2026-08-02

### Added

- Per-file include/exclude controls, proposed-name overrides, and reset actions
- Multi-selection, range selection, bulk include/exclude, and keyboard editing
- Ordered List rules with newline paste and current-name population
- TXT/CSV name-list imports and original-to-proposed CSV exports
- Preview search and visual sorting by name, extension, size, modified time, or path

### Changed

- Rename previews now expose file size and modified time through RPC Protocol 3

### Fixed

- The preview header checkbox now correctly excludes all visible files
- macOS debug bundles preserve executable permissions for the Go Sidecar
- Release workflows upload platform archives and portable checksum files

## 0.1.0 - 2026-08-01

### Added

- Native file selection, folder scanning, and drag-and-drop imports
- Optional recursive folder scans with wildcard and hidden-file filters
- Ordered new-name, replace, prefix, suffix, case, sequence, and trim rules
- Rule targets for the file name, extension, or both
- Case-sensitive and RE2 regular-expression replacement
- Per-rule include and exclude conditions over names, extensions, and paths
- Read-only previews with duplicate, collision, invalid-name, and stale-file checks
- Journaled two-phase batch renaming with undo support
- Persistent restoration of the latest rename recipe
- Visible application version and Go Sidecar, Bridra, and protocol details

### Current scope

- Flick renames regular files in place
- Folder renaming, copy and move modes, metadata rules, and automated file
  organization are planned for later releases
