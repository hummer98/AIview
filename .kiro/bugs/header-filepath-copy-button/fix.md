# Bug Fix: header-filepath-copy-button

## Summary
Added a file path header overlay with copy button to ImageDisplayView, allowing users to see and copy the current image's full path.

## Changes Made

### Files Modified
| File | Change Description |
|------|-------------------|
| `AIview/Sources/Presentation/ImageDisplayView.swift` | Added `currentImagePath` parameter, file path header overlay, copy button, and toast notification |
| `AIview/Sources/Presentation/MainWindowView.swift` | Pass `currentImageURL?.path` to ImageDisplayView |

### Code Changes

**ImageDisplayView.swift**

Added new properties:
```diff
 struct ImageDisplayView: View {
     let image: NSImage?
     let isLoading: Bool
     let hasImages: Bool
     var favoriteLevel: Int = 0
     var isFilterEmpty: Bool = false
+    var currentImagePath: String? = nil
+    @State private var showCopiedToast = false
```

Added file path header overlay on image:
```diff
                 Image(nsImage: image)
                     .resizable()
                     .aspectRatio(contentMode: .fit)
                     .overlay(alignment: .topLeading) {
                         // ...existing favorite indicator...
                     }
+                    .overlay(alignment: .top) {
+                        // File path header (top center)
+                        if let path = currentImagePath {
+                            filePathHeader(path: path)
+                        }
+                    }
```

Added toast overlay and helper functions:
```swift
// Toast notification for copy confirmation
.overlay {
    if showCopiedToast {
        VStack {
            Spacer()
            Text("パスをコピーしました")
                .font(.system(size: 12))
                ...
        }
    }
}

// File path header component with copy button
private func filePathHeader(path: String) -> some View {
    HStack(spacing: 8) {
        Text(path)
            .lineLimit(1)
            .truncationMode(.middle)
        Button { copyToClipboard(path) } label: {
            Image(systemName: "doc.on.doc")
        }
    }
    .background(Color.black.opacity(0.6))
    .cornerRadius(6)
}

// Clipboard copy with toast feedback
private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    // Show toast for 1.5 seconds
}
```

**MainWindowView.swift**

Pass image path to ImageDisplayView:
```diff
 ImageDisplayView(
     image: viewModel.currentImage,
     isLoading: viewModel.isLoading,
     hasImages: viewModel.hasImages,
     favoriteLevel: viewModel.currentFavoriteLevel,
-    isFilterEmpty: viewModel.isFilterEmpty
+    isFilterEmpty: viewModel.isFilterEmpty,
+    currentImagePath: viewModel.currentImageURL?.path
 )
```

## Implementation Notes
- File path header appears at the top center of the image when an image is displayed
- Long paths are truncated in the middle with `truncationMode(.middle)`
- Copy button uses the same `doc.on.doc` icon as InfoPanel for consistency
- Toast notification appears for 1.5 seconds after copying
- Uses semi-transparent background (`Color.black.opacity(0.6)`) for readability
- Follows existing code patterns from InfoPanel's `copyToClipboard` function

## Breaking Changes
- [x] No breaking changes
- [ ] Breaking changes (documented below)

## Rollback Plan
Revert changes to:
- `AIview/Sources/Presentation/ImageDisplayView.swift`
- `AIview/Sources/Presentation/MainWindowView.swift`

## Related Commits
- *Pending commit after verification*
