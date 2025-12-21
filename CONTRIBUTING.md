# Contributing to AIview

Thank you for your interest in contributing to AIview!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/AIview.git`
3. Open `AIview.xcodeproj` in Xcode
4. Create a feature branch: `git checkout -b feature/your-feature-name`

## Development Setup

### Requirements

- macOS 14.0+
- Xcode 15.0+

### Building

```bash
open AIview.xcodeproj
# Build with ⌘B, Run with ⌘R
```

### Running Tests

```bash
# In Xcode: ⌘U
# Or via command line:
xcodebuild test -project AIview.xcodeproj -scheme AIview
```

## Code Style

- Follow Swift API Design Guidelines
- Use SwiftUI for new UI components
- Prefer async/await over completion handlers
- Use `Task.isCancelled` checks in long-running operations

## Pull Request Process

1. Ensure your code builds without warnings
2. Run all tests and ensure they pass
3. Update documentation if needed
4. Create a Pull Request with a clear description

### PR Title Format

Use conventional commit style:

- `feat: Add new feature`
- `fix: Fix bug description`
- `docs: Update documentation`
- `refactor: Refactor code`
- `test: Add tests`

## Reporting Issues

When reporting bugs, please include:

- macOS version
- Steps to reproduce
- Expected vs actual behavior
- Screenshots if applicable

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
