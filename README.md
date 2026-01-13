# AIview

[日本語](README-ja.md) | English

A high-performance image viewer for macOS, optimized for browsing large image collections (1000+ images) with instant display and smooth navigation.

## Features

- **Instant First Image Display** - Opens folders immediately without waiting for full scan
- **Smooth Navigation** - Arrow key rapid-fire without UI blocking
- **AI Prompt Extraction** - Reads Stable Diffusion prompts from PNG metadata (tEXt chunks / XMP)
- **Privacy Mode** - Instantly hide all content with spacebar
- **Smart Prefetching** - Preloads images based on navigation direction
- **Thumbnail Carousel** - Virtualized scrolling for thousands of images
- **Keyboard-Driven** - Delete, navigate, and manage images without mouse
- **5-Level Favorites** - Rate images ★1-★5 with persistent per-folder storage
- **Favorite Filtering** - Filter by rating with automatic subdirectory scanning
- **Slideshow** - Auto-advance with configurable interval (1-60 seconds)

## Keyboard Shortcuts

### Basic Navigation

| Key | Action |
|-----|--------|
| `←` / `→` | Previous / Next image |
| `d` | Delete current image (move to Trash) |
| `i` | Toggle image info panel (EXIF, prompts) |
| `t` | Toggle thumbnail carousel |
| `Space` | Toggle privacy mode |
| `s` | Open slideshow settings dialog |

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
- Xcode 15.0 or later (for building)

## Installation

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

```
AIview/
├── Sources/
│   ├── App/           # SwiftUI App, ContentView, AppState, AppCommands
│   ├── Domain/        # Business logic (ImageLoader, FolderScanner, CacheManager, SlideshowTimer)
│   ├── Data/          # Persistence (FavoritesStore, RecentFolders, Settings, DiskCache)
│   └── Presentation/  # UI Components (ThumbnailCarousel, InfoPanel, SlideshowSettingsDialog)
└── Tests/             # Unit tests
```

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
    ├── favorites.json    # Favorite ratings
    └── thumbnails/       # Cached thumbnails
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

Yuji Yamamoto (rr.yamamoto@gmail.com)

GitHub: [@hummer98](https://github.com/hummer98)
