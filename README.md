# MediaTagger

Native macOS app (SwiftUI, Apple Silicon, macOS 14+) for viewing and editing
audio file metadata — focused on FLAC.

## Layout

Three-pane `NavigationSplitView`:

1. **Sidebar** ([SidebarView](MediaTagger/Views/SidebarView.swift)) — folder
   navigator rooted at a user-chosen folder.
2. **File list** ([FileListView](MediaTagger/Views/FileListView.swift)) — media
   files in the selected folder with their `TITLE` tag.
3. **Property grid** ([MetadataEditorView](MediaTagger/Views/MetadataEditorView.swift))
   — cover art + editable `KEY` / `value` rows.

State: [AppState](MediaTagger/Models/AppState.swift) (`@MainActor`
`ObservableObject`).

## FLAC engine

[FlacFile](MediaTagger/Services/FlacFile.swift) is a dependency-free Swift
implementation that:

- Parses the metadata block chain after the `fLaC` marker.
- Reads/writes `VORBIS_COMMENT` (block type 4, little-endian).
- Reads/writes `PICTURE` (block type 6, big-endian).
- Writes in-place when the new metadata fits in the existing area
  (using padding); otherwise rewrites the file atomically.

Other formats (`mp3`, `m4a`, …) are read via `AVAsset` in
[MetadataService](MediaTagger/Services/MetadataService.swift). Writing for
non-FLAC formats is intentionally not implemented in stage 1.

## Build

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd MediaTagger
xcodegen generate
open MediaTagger.xcodeproj
```

Then ⌘R. Targets `arm64` only, macOS 14+.

To run tests:

```sh
xcodebuild -project MediaTagger.xcodeproj -scheme MediaTagger \
  -destination 'platform=macOS,arch=arm64' test
```

## Sandbox

Read/write access to user-chosen folders uses
`com.apple.security.files.user-selected.read-write` plus a security-scoped
bookmark stored in `UserDefaults` so the chosen root persists across launches.

## Stage 2 (planned)

- Multi-file selection in the file list.
- Batch operations:
  - Set `TITLE` from filename with cleanup rules
    (strip leading track number, replace `_` with space, trim, etc.).
  - Set `ALBUM`, `ALBUMARTIST`, `DISCNUMBER`, `DISCTOTAL`.
  - Renumber `TRACKNUMBER` based on file order.
  - Apply a single cover image to a whole album.
- Tag-writing backend for MP3 (ID3v2) and M4A (iTunes atoms).
- Undo/redo across the editor.
