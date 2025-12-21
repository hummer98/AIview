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

### Testing
- Unit tests in `AIviewTests/` for all services and data layer
- Performance tests with baseline measurements
- No mocking framework - protocol-based dependency injection

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
