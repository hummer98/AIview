# AIview

[日本語](README-ja.md) | English

A high-performance image viewer for macOS, optimized for browsing large image collections (1000+ images) with instant display and smooth navigation.

## Features

- **Instant First Image Display** - Opens folders immediately without waiting for full scan
- **Smooth Navigation** - Arrow key rapid-fire without UI blocking
- **AI Prompt Extraction** - Reads prompts and generation parameters (model, seed, steps, etc.) from ImageIO metadata or bounded PNG text chunks (tEXt / iTXt / zTXt), detecting Stable Diffusion WebUI, SwarmUI, and ComfyUI formats
- **Privacy Mode** - Instantly hide all content with spacebar
- **Smart Prefetching** - Preloads images based on navigation direction
- **Thumbnail Carousel** - Virtualized scrolling for thousands of images
- **Keyboard-Driven** - Delete, navigate, and manage images without mouse
- **5-Level Favorites** - Rate images ★1-★5 with persistent per-folder storage
- **Favorite Filtering** - Filter by rating with automatic subdirectory scanning
- **Slideshow** - Auto-advance with configurable interval (1-60 seconds)
- **Thumbnail Activity Indicator** - Toolbar icon visible only while thumbnail generation is in flight
- **Window State Restoration** - Reopens all windows you had open at quit, with their folder, position, and size
- **Resume Last Viewed Image** - Remembers the last image you viewed per folder and offers to jump back to it next time (toggleable in settings)
- **Actionable Error Feedback** - Folder, favorite, image-load, and delete failures show recovery-oriented messages; cancellations stay silent

## Keyboard Shortcuts

### Basic Navigation

| Key | Action |
|-----|--------|
| `←` / `→` | Previous / Next image |
| `d` | Delete current image (move to Trash) |
| `i` | Toggle image info panel (EXIF, prompts, generation parameters) |
| `t` | Toggle thumbnail carousel |
| `Space` | Toggle privacy mode |
| `s` | Open slideshow settings dialog |

### Zoom

Zoom the main image with a trackpad pinch, or via the View menu / shortcuts, centered on the cursor position. Drag or two-finger scroll to pan while zoomed in. Switching images resets to fit.

| Key | Action |
|-----|--------|
| `⌘+` | Zoom in |
| `⌘−` | Zoom out |
| `⌘0` | Actual size (100%) |
| `⌘9` | Zoom to fit (fit to window) |

### Favorites

| Key | Action |
|-----|--------|
| `1` - `5` | Set favorite rating ★1-★5 (same key to toggle off) |
| `0` | Clear favorite rating |

### Filtering (with Shift)

| Key | Action |
|-----|--------|
| `Shift+1` | Filter ★1+ (scans subdirectories) |
| `Shift+2` | Filter ★2+ (scans subdirectories) |
| `Shift+3` | Filter ★3+ (scans subdirectories) |
| `Shift+4` | Filter ★4+ (scans subdirectories) |
| `Shift+5` | Filter ★5+ (scans subdirectories) |
| `Shift+0` | Clear filter and exit subdirectory mode |

### Slideshow

| Key | Action |
|-----|--------|
| `↑` / `↓` | Increase / Decrease interval by 1 second |
| `Space` | Pause slideshow and activate privacy mode |
| `Escape` | Stop slideshow |
| `←` / `→` | Manual navigation (resets timer) |

## Supported Formats

- JPEG (.jpg, .jpeg)
- PNG (.png)
- HEIC (.heic)
- WebP (.webp)
- GIF (.gif)

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later (only required when building from source)

## Installation

### Homebrew (Recommended)

```bash
brew tap hummer98/aiview
brew install --cask aiview
```

The binary is signed with a Developer ID certificate and notarized by Apple, so macOS Gatekeeper will not show a warning on first launch.

**Requirements**:
- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac (universal binary; current builds are tested primarily on Apple Silicon)

To upgrade:

```bash
brew update
brew upgrade --cask aiview
```

To uninstall (with `--zap` to also remove preferences and caches):

```bash
brew uninstall --zap --cask aiview
```

### From Source

```bash
git clone https://github.com/hummer98/AIview.git
cd AIview
open AIview.xcodeproj
```

Build and run with Xcode (⌘R).

### Using Task (optional)

If you have [Task](https://taskfile.dev/) installed:

```bash
task build
task run
```

## Architecture

### Layer responsibilities

```
AIview/
├── Sources/
│   ├── App/           # SwiftUI App, shared services, window sessions, focused commands
│   ├── Domain/        # Session controller, state machine, loaders, caches, slideshow
│   ├── Data/          # Persistence (FavoritesStore, RecentFolders, Settings, DiskCache)
│   └── Presentation/  # Composed views, keyboard routing, dialogs, toolbar/status
└── Tests/             # Unit tests
```

`ImageBrowserViewModel` is a UI facade over one scene-local `BrowserSessionController`; it does not own scanners, persistence, or metadata extraction. `BrowserSessionState` is the single value that atomically commits the displayed URL, index, image, and load identity. `SlideshowController` owns slideshow state and its timer. Process-global `AppServices` is limited to intentionally shared repositories and the telemetry coordinator.

### Data flow

```text
focused menu / keyboard / dialog
  → BrowserWindowSession (scene-local task ownership)
  → ImageBrowserViewModel (UI facade)
  → BrowserSessionController
  → FolderScanner / ImageLoader / FavoritesStore / MetadataExtractor
  → BrowserSessionState atomic commit
  → SwiftUI observation
```

### Concurrency and state ownership

- Every window owns an independent folder, selection, dialogs, zoom requests, metrics, and operation tasks.
- Async commits must match the current browser session and operation/load identity. Replaced or closed scenes cancel their owned tasks; cancellation is not shown as an error.
- Actors isolate persistence and scanning. Typed locks protect synchronous caches and registries. Production code has no `Task.detached` or `@unchecked Sendable` escape hatch.
- The process-global telemetry coordinator owns at most one request/retry task, and analytics OFF cancels routine communication immediately.

The binding implementation principles and complete flow are documented in [`CLAUDE.md`](CLAUDE.md) and [`docs/spec/01-architecture.md`](docs/spec/01-architecture.md).

## Performance Design

- **Streaming folder scan** - First image displays before full enumeration (batch size: 50)
- **Priority-based prefetch queue** - P0: current, P1: adjacent, P2: nearby, P3: thumbnails
- **LRU memory cache** - Decoded images cached for instant access (configurable: 128-4096 MB)
- **Disk thumbnail cache** - Stored in `.aiview/` subfolder
- **Task cancellation** - Stale decoding tasks cancelled immediately
- **Directional prefetching** - 12 images forward, 3 backward based on navigation direction

## Data Storage

AIview stores per-folder data in a hidden `.aiview/` directory:

```
your-image-folder/
├── image1.png
├── image2.jpg
└── .aiview/
    ├── favorites.json    # Favorite ratings + last viewed image
    ├── image1.png.jpg    # Cached thumbnail for image1.png
    └── image2.jpg.jpg    # Cached thumbnail for image2.jpg
```

## Distribution

AIview is distributed via [Homebrew Cask](https://github.com/hummer98/homebrew-aiview). Releases are fully automated:

1. A maintainer pushes a `vX.Y.Z` tag to this repository.
2. [`.github/workflows/release.yml`](.github/workflows/release.yml) builds, signs (Developer ID), notarizes, and attaches `.dmg` / `.zip` / `.sha256` to a GitHub Release.
3. [`.github/workflows/update-tap.yml`](.github/workflows/update-tap.yml) updates the Cask formula in [`hummer98/homebrew-aiview`](https://github.com/hummer98/homebrew-aiview) automatically.

For the one-time setup required to enable this pipeline (Apple Developer Program, App Store Connect API Key, GitHub Secrets, etc.), see [`docs/signing-setup.md`](docs/signing-setup.md).

For day-to-day release procedure, see [`docs/release.md`](docs/release.md).

Tracking issue: [#1 - Distribution automation](https://github.com/hummer98/AIview/issues/1).

## Privacy

Pressing `Space` enables the scene-local privacy overlay. Enabling it also cancels pending last-viewed writes and metadata/prompt extraction, and clears metadata already held by the info panel.

AIview sends a usage ping at most once per UTC day at launch. The client sends a stable, high-entropy random install UUID (a **pseudonymous identifier**), the app and macOS versions, CPU architecture, and locale. The server adds a country code supplied by Cloudflare; it does not store the source IP. It stores one row per install containing those fields, first/last-seen timestamps, and an active-day count. File paths, image contents, prompts, user names, and other personal content are never sent.

You can turn routine analytics off under **Settings → Display → Privacy → "Send anonymous usage statistics"**. Disabling it immediately cancels any in-flight ping or retry, and no further routine analytics requests are made while it remains off. Server records expire 400 days after the last successful ping.

**Delete and reset pseudonymous ID** asks the server to delete the current UUID, then creates a new local UUID only after the server confirms success. A failed deletion keeps the old UUID so you can retry. This explicit deletion request is available even while routine analytics is off; it is the only analytics-server request initiated in that state.

Application diagnostics use Apple's privacy-aware Unified Logging. File paths, names, URLs, metadata, and error details are private; extracted AI prompts are never logged. Navigation diagnostics remain only in a bounded in-memory, non-content event history and are not written to a plaintext incident file.

Details: [ADR 002](docs/adr/002-anonymous-usage-telemetry.html).

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

Yuji Yamamoto (rr.yamamoto@gmail.com)

GitHub: [@hummer98](https://github.com/hummer98)
