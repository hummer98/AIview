#!/usr/bin/env bash
set -euo pipefail

production_root="AIview"
failed=0
sensitive_public_pattern='\\\([^)]*(lastPathComponent|\.path\b|absoluteString|localizedDescription|filename\b|prompt\b|negativePrompt\b|metadata\b|bookmark\b)[^)]*privacy:[[:space:]]*\.public|\\\([^)]*\b[A-Za-z_]*url\b[[:space:]]*,[[:space:]]*privacy:[[:space:]]*\.public|\\\([^)]*\berror\b[[:space:]]*,[[:space:]]*privacy:[[:space:]]*\.public'
prompt_log_pattern='(Logger|logger)\.[^)]{0,500}(prompt|negativePrompt|parameters)'

assert_sensitive_fixture() {
  local fixture="$1"
  if ! printf '%s\n' "$fixture" | rg -q -U -i "$sensitive_public_pattern"; then
    printf '%s\n' "log privacy self-test failed to reject: ${fixture}" >&2
    exit 1
  fi
}

assert_allowed_fixture() {
  local fixture="$1"
  if printf '%s\n' "$fixture" | rg -q -U -i "$sensitive_public_pattern"; then
    printf '%s\n' "log privacy self-test rejected legal numeric log: ${fixture}" >&2
    exit 1
  fi
}

assert_sensitive_fixture 'Logger.app.info("bad \(url, privacy: .public)")'
assert_sensitive_fixture 'Logger.app.info("bad \(folderURL, privacy: .public)")'
assert_sensitive_fixture 'Logger.app.info("bad \(fileURL, privacy: .public)")'
assert_sensitive_fixture 'Logger.app.error("bad \(error, privacy: .public)")'
assert_sensitive_fixture $'Logger.app.info("bad \\(folderURL,\n privacy: .public)")'
assert_allowed_fixture 'Logger.app.info("count \(urls.count, privacy: .public)")'
assert_allowed_fixture 'Logger.app.info("duration \(elapsedMs, privacy: .public)")'
if ! printf '%s\n' $'Logger.metadata.debug(\n "prompt content")' | rg -q -U -i "$prompt_log_pattern"; then
  printf '%s\n' "log privacy self-test failed to reject multiline prompt log" >&2
  exit 1
fi

report_matches() {
  local description="$1"
  local pattern="$2"
  shift 2
  local matches
  if matches=$(rg -n "$@" --glob '*.swift' "$pattern" "$production_root"); then
    printf '%s\n%s\n' "log privacy check failed: ${description}" "$matches" >&2
    failed=1
  fi
}

report_matches \
  "production print/debugPrint/NSLog is forbidden" \
  '(^|[^[:alnum:]_])(print|debugPrint|NSLog)[[:space:]]*\('

report_matches \
  "sensitive values must not use public privacy" \
  "$sensitive_public_pattern" \
  -U \
  -i

report_matches \
  "prompt or extracted parameter content must never be logged" \
  "$prompt_log_pattern" \
  -U \
  -i

report_matches \
  "plaintext incident-file diagnostics are forbidden" \
  '(navigation-incidents|INCIDENT|FileHandle\(forWritingTo:|appendPathExtension\("1"\)|~/Library/Logs/AIview)'

report_matches \
  "NavigationDiagnostics must not expose arbitrary string APIs" \
  'func[[:space:]]+(breadcrumb|reportAnomaly)[[:space:]]*\('

if matches=$(rg -n '(FileManager|FileHandle|data\.write|Data\([^)]*\)\.write|write\(to:)' \
  AIview/Sources/Domain/NavigationDiagnostics.swift); then
  printf '%s\n%s\n' \
    "log privacy check failed: NavigationDiagnostics must remain in-memory only" \
    "$matches" >&2
  failed=1
fi

if (( failed != 0 )); then
  exit 1
fi

printf '%s\n' "Log privacy checks passed."
