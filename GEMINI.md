# AIview - High-Performance macOS Image Viewer

## Project Overview
**AIview** is a native macOS image viewer application written in Swift (AppKit). It is designed for high performance when browsing folders containing thousands of images (1000-2000+).

**Key Goals:**
*   **Instant First Load:** Display the first image immediately upon opening a folder without waiting for full scan/thumbnails.
*   **Zero-Latency Navigation:** Aggressive prefetching to ensure smooth `←`/`→` navigation.
*   **GenAI Metadata:** Support for viewing generation prompts (EXIF/UserComment).

## Architecture
The project follows a **Clean Architecture** approach, separated into layers within `AIview/Sources/`:

*   **App (`AIview/Sources/App`)**: Application entry point, `AppDelegate`, `SceneDelegate`, Dependency Injection setup.
*   **Domain (`AIview/Sources/Domain`)**: Core business logic, Entities (`ImageItem`, `FolderSession`), and UseCase interfaces. **Pure Swift, no UI dependencies.**
*   **Data (`AIview/Sources/Data`)**: Concrete implementations of Domain protocols. Handles File System access, Caching, Image Decoding, and Metadata extraction.
*   **Presentation (`AIview/Sources/Presentation`)**: UI logic, ViewControllers (`ImageViewerViewController`), ViewModels, and AppKit Views.

## Key Features & Shortcuts

| Key | Action | Details |
| :--- | :--- | :--- |
| `←` / `→` | Navigate | Move to previous/next image. Supports rapid navigation. |
| `d` | Delete | Move current image to Trash. Auto-advances to next image. |
| `i` | Info | Toggle Info Panel (EXIF, GenAI Prompts). |
| `Space` | Toggle UI | Hide/Show overlays (thumbnails, info) for distraction-free viewing. |

**Other Features:**
*   **Thumbnail Carousel:** Virtualized list of thumbnails at the bottom.
*   **Recent Folders:** Persisted history of opened folders.
*   **Sandboxing:** App is sandboxed (requires User Selected File access).

## Development & Building

The project uses `go-task` (defined in `Taskfile.yml`) and `xcodebuild`.

### Common Commands

| Command | Description |
| :--- | :--- |
| `task dev` | Build and run the app (Debug configuration). |
| `task build` | Build the app (Debug). |
| `task test` | Run all unit and UI tests. |
| `task lint` | Run SwiftLint. |
| `task format` | Format code using SwiftFormat. |
| `task log` | Stream app logs (`com.aiview.app`). |
| `task log:image` | Stream ImageLoader specific logs. |

### Prerequisites
*   Xcode 15+ (Swift 5.9+)
*   `go-task` (optional, can run `xcodebuild` directly)
*   `swiftlint` & `swiftformat` (for linting)

## Development Workflow (SDD)
Follow the lightweight SDD (System Design Document) workflow for changes:
1.  **Report:** Create a bug report or feature request (e.g., `/kiro:bug-create`).
2.  **Analyze:** Investigate root cause or requirements (`/kiro:bug-analyze`).
3.  **Fix/Implement:** Write code and tests (`/kiro:bug-fix`).
4.  **Verify:** Run tests and verify manually (`/kiro:bug-verify`).

## Important Files
*   `Taskfile.yml`: Build/Test command definitions.
*   `CLAUDE.md`: Agent specific instructions and workflow details.
*   `docs/BOOT.md`: detailed requirements and architectural decisions.
*   `AIview/AIview.entitlements`: App Sandbox configuration.
