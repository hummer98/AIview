# Technology Stack

## Architecture

Clean Architecture with layer separation:
- **App Layer**: SwiftUI entry point, state coordination, commands
- **Presentation Layer**: SwiftUI views for UI components
- **Domain Layer**: Business logic, ViewModels, services
- **Data Layer**: Persistence, file system access, caching

## Core Technologies

- **Language**: Swift 5.9+
- **Framework**: SwiftUI with AppKit integration (NSImage, CGImage)
- **Runtime**: macOS native (Xcode project)
- **Concurrency**: Swift Concurrency (async/await, actors, Task)

## Key Libraries

- **ImageIO**: Hardware-accelerated image decoding with downsampling
- **os.Logger**: Unified logging with categories per subsystem
- **XCTest**: Unit and performance testing

## Development Standards

### Type Safety
- Swift strict concurrency checking
- `@MainActor` for UI state, `actor` for thread-safe services
- `Sendable` conformance for cross-actor data

### Code Quality
- SwiftLint for style enforcement
- SwiftFormat for consistent formatting
- Japanese comments for domain concepts, English for standard patterns

### Testing Strategy

**Test Categories**:
| Category | Location | Purpose | Execution |
|----------|----------|---------|-----------|
| Unit Tests | `AIviewTests/` | Services, ViewModels, Data layer | `task test:unit` (every commit) |
| UI Tests | `AIviewUITests/` | User interaction flows | `task test:ui` (every commit) |
| Performance Tests | `AIviewUITests/ScrollPerformanceUITests` | Scroll/memory benchmarks | `task test:perf` (manual only) |

**Default Test Suite** (`task test`):
- Runs Unit + UI tests
- Performance tests are **excluded** from default suite (time-intensive, 100 images × 5 iterations)
- Skipped via Xcode scheme `SkippedTests` configuration

**Performance Tests** (`task test:perf`):
- Run manually when optimizing image loading, caching, or scroll behavior
- Individual test commands available:
  - `task test:perf:nocache` - Cold cache performance
  - `task test:perf:cache` - Warm cache performance
  - `task test:perf:memory` - Memory usage during bulk load
  - `task test:perf:keynav` - Key navigation responsiveness

**Testing Principles**:
- No mocking framework - protocol-based dependency injection
- Test environment via `AIVIEW_TEST_FOLDER` and `AIVIEW_UI_TEST_MODE` env vars
- Performance baselines tracked via XCTest metrics (CPU, clock, memory)

## Development Environment

### Required Tools
- Xcode (latest stable)
- Task runner (`task` CLI for build automation)

### Common Commands
```bash
# Dev: task dev
# Build: task build
# Test: task test
# Lint: task lint
# Format: task format
```

## Key Technical Decisions

- **Swift Concurrency over GCD**: Better cancellation, priority control, and type safety
- **Actor isolation for ImageLoader/CacheManager**: Prevents race conditions in concurrent image loading
- **ImageIO over NSImage(contentsOf:)**: Enables progressive decoding and memory-efficient downsampling
- **In-memory cache with disk persistence**: Fast access for prefetched images, persistence for thumbnails
- **Observable macro over ObservableObject**: Simpler reactive state without Combine

---
_Document standards and patterns, not every dependency_
