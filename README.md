# MediaTagger

Native macOS app (SwiftUI, Apple Silicon, macOS 14+) for viewing and editing
audio/video file metadata. Reads and writes a wide range of containers using
dependency-free Swift parsers — no `ffmpeg`, no `taglib`.

## Layout

Three-pane `NavigationSplitView`:

1. **Sidebar** ([SidebarView](MediaTagger/Views/SidebarView.swift)) — folder
   navigator rooted at a user-chosen folder.
2. **File list** ([FileListView](MediaTagger/Views/FileListView.swift)) — media
   files in the selected folder with their `TITLE` tag. Supports multi-selection
   for batch editing.
3. **Detail pane** ([DetailPane](MediaTagger/Views/DetailPane.swift)) —
   - [PlayerView](MediaTagger/Views/PlayerView.swift): inline AVKit transport
     for supported formats.
   - [MetadataEditorView](MediaTagger/Views/MetadataEditorView.swift): cover
     art plus editable `KEY` / `value` rows (single selection).
   - [BatchEditorView](MediaTagger/Views/BatchEditorView.swift): batch-edit
     panel (multi-selection).

State: [AppState](MediaTagger/Models/AppState.swift) (`@MainActor`
`ObservableObject`).

## Supported formats

Routing lives in
[MetadataService](MediaTagger/Services/MetadataService.swift). Each format has
its own dependency-free parser/writer:

| Format                              | Container / tag scheme               | Read | Write | Implementation |
|-------------------------------------|--------------------------------------|:----:|:-----:|----------------|
| FLAC                                | Vorbis Comment + PICTURE             |  ✅  |  ✅   | [FlacFile](MediaTagger/Services/FlacFile.swift) |
| MP3                                 | ID3v2.3 / 2.4                        |  ✅  |  ✅   | [ID3v2File](MediaTagger/Services/ID3v2File.swift) |
| MP4 / M4A / M4B / M4V / MOV / ALAC  | iTunes-style `moov/udta/meta` atoms  |  ✅  |  ✅   | [MP4File](MediaTagger/Services/MP4File.swift) |
| AIFF / AIF / AIFC                   | ID3 chunk in IFF container           |  ✅  |  ✅   | [AIFFFile](MediaTagger/Services/AIFFFile.swift) |
| MKV / MKA / WebM                    | Matroska EBML Tags + Attachments     |  ✅  |  ✅   | [MatroskaFile](MediaTagger/Services/MatroskaFile.swift) |
| AVI                                 | RIFF `INFO` chunk                    |  ✅  |  ✅   | [AVIFile](MediaTagger/Services/AVIFile.swift) |
| DSF                                 | DSD Stream File + ID3v2              |  ✅  |  ✅   | [DSFFile](MediaTagger/Services/DSFFile.swift) |
| DFF                                 | DSDIFF + ID3 chunk                   |  ✅  |  ✅   | [DFFFile](MediaTagger/Services/DFFFile.swift) |
| Anything else                       | Read via `AVAsset`                   |  ✅  |  ❌   | — |

Writers prefer in-place updates (e.g. FLAC padding, ID3v2 padding) and fall
back to atomic rewrites when the new tag area doesn't fit.

## Playback

[PlayerView](MediaTagger/Views/PlayerView.swift) wraps `AVPlayerView` directly
via `NSViewRepresentable`. Only formats that AVFoundation can demux on macOS
are playable: `mp3`, `m4a`, `m4b`, `aac`, `alac`, `wav`, `aiff`/`aif`/`aifc`,
`flac`, `mp4`, `m4v`, `mov`. For other containers (`mkv`, `webm`, `ogg`,
`opus`, `dsf`, `dff`, `avi`) the editor still works, but the player shows a
"Playback not supported" placeholder — AVFoundation lacks the demuxers for
those containers.

## Batch editing

[BatchOperations](MediaTagger/Services/BatchOperations.swift) defines a
declarative `BatchPlan` applied to all selected files:

- Derive `TITLE` from filename (strip leading track numbers, replace `_`,
  collapse whitespace, trim).
- Set `ALBUM`, `ALBUMARTIST`, `ARTIST`, `DATE`, `GENRE`,
  `DISCNUMBER`, `DISCTOTAL`.
- Renumber `TRACKNUMBER` (configurable start, zero-padding, optional
  `TRACKTOTAL`).
- Apply or clear cover art across the whole selection.

## Build

The Xcode project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from [project.yml](project.yml):

```sh
brew install xcodegen
xcodegen generate
open MediaTagger.xcodeproj
```

Then ⌘R. Targets `arm64` only, macOS 14+.

VS Code tasks are also provided:

- `MediaTagger: Generate Xcode Project`
- `MediaTagger: Generate App Icon`
- `MediaTagger: Build (Debug)`
- `MediaTagger: Run`
- `MediaTagger: Test`
- `MediaTagger: Clean`

### Tests

```sh
xcodebuild -project MediaTagger.xcodeproj -scheme MediaTagger \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
```

The [MediaTaggerTests](MediaTaggerTests) target covers each format parser plus
round-trip read/write tests for FLAC and ID3v2, and the batch-operation
pipeline.

## Sandbox

The app runs sandboxed with
`com.apple.security.files.user-selected.read-write` and
`com.apple.security.files.bookmarks.app-scope`. The chosen root folder is
persisted as a security-scoped bookmark in `UserDefaults` so it survives
relaunches — see [SecurityScope](MediaTagger/Services/SecurityScope.swift).

## Roadmap

- VLCKit / mpv integration to play unsupported containers (MKV, WebM, Opus, …).
- Undo/redo across the editor.
- Tag-mapping UI for non-standard fields per container.
