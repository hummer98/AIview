# Project Structure

## Organization Philosophy

Layer-based architecture with clear separation of concerns. Each layer has a dedicated directory under `Sources/`, and dependencies flow inward (Presentation → Domain → Data).

## Directory Patterns

### App Layer (`/AIview/Sources/App/`)
**Purpose**: Application entry point, global state, and command handling
**Example**: `AIviewApp.swift`, `AppState.swift`, `AppCommands.swift`

### Presentation Layer (`/AIview/Sources/Presentation/`)
**Purpose**: SwiftUI views and UI components
**Example**: `MainWindowView.swift`, `ThumbnailCarousel.swift`, `InfoPanel.swift`

### Domain Layer (`/AIview/Sources/Domain/`)
**Purpose**: Business logic, ViewModels, and service orchestration
**Example**: `ImageBrowserViewModel.swift`, `ImageLoader.swift`, `FolderScanner.swift`

### Data Layer (`/AIview/Sources/Data/`)
**Purpose**: Persistence, file system access, and external data sources
**Example**: `RecentFoldersStore.swift`, `FileSystemAccess.swift`, `DiskCacheStore.swift`

### Tests (`/AIviewTests/`)
**Purpose**: Unit and performance tests
**Pattern**: `<ClassName>Tests.swift` mirrors source files

## Naming Conventions

- **Files**: PascalCase, matches primary type name
- **Views**: Suffix with `View` (e.g., `MainWindowView`)
- **ViewModels**: Suffix with `ViewModel` (e.g., `ImageBrowserViewModel`)
- **Services/Actors**: Descriptive noun (e.g., `ImageLoader`, `CacheManager`)
- **Stores**: Suffix with `Store` (e.g., `RecentFoldersStore`)
- **Tests**: Suffix with `Tests` (e.g., `ImageLoaderTests`)

## Import Organization

```swift
// System frameworks first
import AppKit
import Foundation
import os

// No third-party dependencies
// Project modules implicit (single-module app)
```

## Code Organization Principles

- **Layer independence**: Domain layer has no SwiftUI imports
- **Protocol-based DI**: Services accept protocol-typed dependencies in init
- **Actor for concurrency**: Stateful services that handle concurrent access use `actor`
- **@MainActor for UI**: ViewModels and UI state annotated with `@MainActor`
- **Japanese documentation**: Domain concepts documented in Japanese; standard patterns in English

---
_Document patterns, not file trees. New files following patterns shouldn't require updates_
