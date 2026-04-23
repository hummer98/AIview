# Changelog

All notable changes to AIview will be documented in this file.

## [0.4.0] - 2026-04-24

### Added

- `⌘↑` / `⌘↓` keyboard shortcuts to navigate between sibling folders

### Changed

- Thumbnail disk cache reverted to per-folder `.aiview/` storage (from centralized `~/Library/Application Support/AIview/DiskCache/`)
  - Cache lives alongside the images: shared across machines via NAS, travels with external drives, disappears with the folder
  - File naming simplified to `<original>.jpg` (e.g., `sunset.heic` → `.aiview/sunset.heic.jpg`)
  - Removed identity-key / LRU eviction / shard directories / backup-exclusion attributes
  - Existing central cache is removed at first launch

### Fixed

- Release workflow: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` now synced from git tag (previously shipped with stale values)

### Developer

- Design philosophy for thumbnail cache placement documented in `CLAUDE.md`

## [0.3.0] - 2026-04-22

First signed + notarized public release.

### Added

- Developer ID signed + Apple notarized macOS distribution
- Homebrew Cask support: `brew tap hummer98/aiview && brew install --cask aiview`
- App icon (provisional AIv typography) with SVG master and PNG generator
- Bounded concurrency + window-based priority for thumbnail generation
- Disk-backed thumbnail cache with inode-based keys and LRU-capped storage
- Cache / queue / disk-IO observability metrics (⌘⇧D to dump)

### Fixed

- Favorites filter toggle now preserves current index via URL anchor
- Thumbnail `.loading` state deferred until after disk cache lookup
- Thumbnail cancellation reaches DispatchQueue and ImageLoader
- `MainWindowView` `@MainActor` annotations for Swift 5.10 compat

### Developer

- GitHub Actions release workflow with notarization + GitHub Release
- Homebrew tap auto-update workflow (SSH deploy key)
- Xcode 26.3 / macOS 15 runner

## [0.2.0] - 2026-01-17

### Added

- Folder reload functionality with Cmd+R keyboard shortcut
- Reload button in folder selection view

### Developer

- Enhanced SDD workflow with agents and new commands
- Added reload functionality tests

## [0.1.0] - 2026-01-14

Initial release of AIview - a macOS image viewer application.

### Added

- Core image viewing functionality with keyboard navigation
- Thumbnail carousel for quick image browsing
- Slideshow mode with configurable interval
- Privacy mode (Space key toggle)
- Favorites management with subdirectory scanning support
- File path header with copy-to-clipboard functionality
- Recent folders tracking
- Filter images by rating (1-5 stars)
- Support for common image formats

### Fixed

- Position indicator now visible during slideshow
- Privacy mode activation with Space key during slideshow
- Thumbnail loading persistence issue resolved
- Recent folders update issue fixed
- Thumbnail carousel scroll blocking fixed
- Shift+number key filtering now works correctly

### Developer

- CI/CD configuration with GitHub Actions
- Comprehensive test suite (unit and E2E tests)
- Task runner for common development operations
