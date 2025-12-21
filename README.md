# AIview

A high-performance image viewer for macOS, optimized for browsing large image collections (1000+ images) with instant display and smooth navigation.

## Features

- **Instant First Image Display** - Opens folders immediately without waiting for full scan
- **Smooth Navigation** - Arrow key rapid-fire without UI blocking
- **AI Prompt Extraction** - Reads Stable Diffusion prompts from PNG metadata (tEXt chunks / XMP)
- **Privacy Mode** - Instantly hide all content with spacebar
- **Smart Prefetching** - Preloads images based on navigation direction
- **Thumbnail Carousel** - Virtualized scrolling for thousands of images
- **Keyboard-Driven** - Delete, navigate, and manage images without mouse

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `←` / `→` | Previous / Next image |
| `d` | Delete current image (move to Trash) |
| `i` | Toggle image info panel (EXIF, prompts) |
| `t` | Toggle thumbnail carousel |
| `Space` | Toggle privacy mode |

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
git clone https://github.com/yourusername/AIview.git
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
│   ├── App/           # SwiftUI App, ContentView, AppState
│   ├── Domain/        # Business logic (ImageLoader, FolderScanner, CacheManager)
│   ├── Data/          # Persistence (RecentFolders, Settings, DiskCache)
│   └── Presentation/  # UI Components (ThumbnailCarousel, InfoPanel)
└── Tests/             # Unit tests
```

## Performance Design

- **Streaming folder scan** - First image displays before full enumeration
- **Priority-based prefetch queue** - P0: current, P1: adjacent, P2: nearby, P3: thumbnails
- **LRU memory cache** - Decoded images cached for instant access
- **Disk thumbnail cache** - Stored in `.aiview/` subfolder
- **Task cancellation** - Stale decoding tasks cancelled immediately

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.
