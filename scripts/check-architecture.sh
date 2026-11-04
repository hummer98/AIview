#!/bin/sh
set -eu

facade="AIview/Sources/Domain/ImageBrowserViewModel.swift"
main_window="AIview/Sources/Presentation/MainWindowView.swift"
sources="AIview/Sources"

fail() {
    echo "architecture check failed: $1" >&2
    exit 1
}

assert_max_lines() {
    file=$1
    limit=$2
    lines=$(wc -l < "$file" | tr -d '[:space:]')
    [ "$lines" -le "$limit" ] || fail "$file has $lines lines (limit: $limit)"
}

assert_no_match() {
    pattern=$1
    shift
    if rg -n "$pattern" "$@"; then
        fail "forbidden source pattern: $pattern"
    fi
}

assert_max_lines "$facade" 800
assert_max_lines "$main_window" 350

# The UI facade may accept dependencies for source-compatible injection, but it must not own
# concrete I/O services or instantiate them. BrowserSessionController is the sole session owner.
assert_no_match 'private (let|var) (folderScanner|favoritesStore|metadataExtractor|fileSystemAccess)' "$facade"
assert_no_match '(FolderScanner|FavoritesStore|MetadataExtractor|FileSystemAccess)\(' "$facade"
rg -q 'let sessionController: BrowserSessionController' "$facade" || fail "facade controller boundary is missing"
rg -q 'private let slideshowController: SlideshowController' \
    AIview/Sources/Domain/BrowserSessionController.swift || fail "slideshow controller boundary is missing"

# Removed architecture hazards must not silently return.
assert_no_match '(reloadRequested|clearThumbnailCacheRequested|openRecentFolderURL|siblingFolderDirection|static var zoomCommand)' "$sources" --glob '*.swift'
assert_no_match '(targetIndex|currentIndex)[[:space:]]*=[[:space:]]*-1' "$sources" --glob '*.swift'
assert_no_match '@unchecked Sendable' "$sources" --glob '*.swift'
assert_no_match 'Task\.detached' "$sources" --glob '*.swift'
assert_no_match 'Data\(contentsOf:' AIview/Sources/Domain/MetadataExtractor.swift
assert_no_match 'SWIFT_VERSION = 5' AIview.xcodeproj/project.pbxproj

# The localized READMEs are maintained as structural translations, and their canonical cache
# example must never drift back to the removed nested directory.
english_heading_shape=$(rg '^#{2,3} ' README.md | sed -E 's/^(#+).*/\1/' | paste -sd ' ' -)
japanese_heading_shape=$(rg '^#{2,3} ' README-ja.md | sed -E 's/^(#+).*/\1/' | paste -sd ' ' -)
[ "$english_heading_shape" = "$japanese_heading_shape" ] || fail "README heading structures differ"
assert_no_match '\.aiview/thumbnails/?' README.md README-ja.md

for linked_file in \
    CLAUDE.md \
    docs/spec/01-architecture.md \
    docs/adr/002-anonymous-usage-telemetry.html \
    docs/adr/003-browser-session-facade.html
do
    [ -f "$linked_file" ] || fail "required local documentation link is missing: $linked_file"
done

echo "architecture check passed"
