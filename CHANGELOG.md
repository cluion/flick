# Changelog

All notable changes to Flick are documented in this file.

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
