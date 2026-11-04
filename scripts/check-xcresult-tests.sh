#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <path-to-xcresult> [--minimum-tests N] [--maximum-skipped N] [--require-name TEXT]..." >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

RESULT_BUNDLE=$1
shift
MINIMUM_TESTS=1
MAXIMUM_SKIPPED=0
REQUIRED_NAMES=()
XCRESULT_SCHEMA_VERSION=0.1.0

while (( $# > 0 )); do
  case "$1" in
    --minimum-tests)
      if [[ $# -lt 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: --minimum-tests requires a positive integer" >&2
        usage
        exit 64
      fi
      MINIMUM_TESTS=$2
      shift 2
      ;;
    --maximum-skipped)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
        echo "error: --maximum-skipped requires a non-negative integer" >&2
        usage
        exit 64
      fi
      MAXIMUM_SKIPPED=$2
      shift 2
      ;;
    --require-name)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: --require-name requires non-empty text" >&2
        usage
        exit 64
      fi
      REQUIRED_NAMES+=("$2")
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [[ ! -d "$RESULT_BUNDLE" ]]; then
  echo "error: xcresult bundle not found: $RESULT_BUNDLE" >&2
  exit 66
fi

if ! XCRESULTTOOL=$(xcrun --find xcresulttool 2>/dev/null); then
  echo "error: xcresulttool not found; install a current Xcode toolchain" >&2
  exit 69
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to parse xcresult test nodes" >&2
  exit 69
fi

SUMMARY_FILE=$(mktemp "${TMPDIR:-/tmp}/aiview-xcresult-summary.XXXXXX")
TESTS_FILE=$(mktemp "${TMPDIR:-/tmp}/aiview-xcresult-tests.XXXXXX")
trap 'rm -f "$SUMMARY_FILE" "$TESTS_FILE"' EXIT

if ! "$XCRESULTTOOL" get test-results summary \
  --schema-version "$XCRESULT_SCHEMA_VERSION" \
  --path "$RESULT_BUNDLE" \
  --compact > "$SUMMARY_FILE"; then
  echo "error: unable to read test summary from: $RESULT_BUNDLE" >&2
  exit 65
fi

extract_integer() {
  local key=$1
  plutil -extract "$key" raw -o - "$SUMMARY_FILE" 2>/dev/null || true
}

SUMMARY_RESULT=$(plutil -extract result raw -o - "$SUMMARY_FILE" 2>/dev/null || true)
TOTAL_TESTS=$(extract_integer totalTestCount)
PASSED_TESTS=$(extract_integer passedTests)
FAILED_TESTS=$(extract_integer failedTests)
SKIPPED_TESTS=$(extract_integer skippedTests)

for summary_key in TOTAL_TESTS PASSED_TESTS FAILED_TESTS SKIPPED_TESTS; do
  if [[ ! "${!summary_key}" =~ ^[0-9]+$ ]]; then
    echo "error: xcresult summary does not contain a numeric $summary_key" >&2
    exit 65
  fi
done

if [[ "$SUMMARY_RESULT" != "Passed" ]]; then
  echo "error: xcresult summary result is not Passed: ${SUMMARY_RESULT:-missing}" >&2
  exit 1
fi

if (( FAILED_TESTS > 0 )); then
  echo "error: xcresult contains failed tests: $FAILED_TESTS" >&2
  exit 1
fi

if (( TOTAL_TESTS < MINIMUM_TESTS )); then
  echo "error: xcresult contains $TOTAL_TESTS tests; expected at least $MINIMUM_TESTS" >&2
  exit 1
fi

if (( SKIPPED_TESTS > MAXIMUM_SKIPPED )); then
  echo "error: xcresult contains $SKIPPED_TESTS skipped tests; maximum is $MAXIMUM_SKIPPED" >&2
  exit 1
fi

if (( PASSED_TESTS + SKIPPED_TESTS != TOTAL_TESTS )); then
  echo "error: xcresult passed + skipped counts do not equal total count: $PASSED_TESTS + $SKIPPED_TESTS != $TOTAL_TESTS" >&2
  exit 1
fi

if (( ${#REQUIRED_NAMES[@]} > 0 )); then
  if ! "$XCRESULTTOOL" get test-results tests \
    --schema-version "$XCRESULT_SCHEMA_VERSION" \
    --path "$RESULT_BUNDLE" \
    --compact > "$TESTS_FILE"; then
    echo "error: unable to read test details from: $RESULT_BUNDLE" >&2
    exit 65
  fi

  if ! python3 - "$TESTS_FILE" "${REQUIRED_NAMES[@]}" <<'PY'
import json
import pathlib
import sys

tests_path = pathlib.Path(sys.argv[1])
required_names = set(sys.argv[2:])
eligible_node_types = {
    "Unit test bundle",
    "UI test bundle",
    "Test Suite",
    "Test Case",
}

with tests_path.open(encoding="utf-8") as tests_file:
    payload = json.load(tests_file)

found_names = set()


def visit(node):
    if not isinstance(node, dict):
        return
    if node.get("nodeType") in eligible_node_types and isinstance(node.get("name"), str):
        found_names.add(node["name"])
    for child in node.get("children", []):
        visit(child)


for test_node in payload.get("testNodes", []):
    visit(test_node)

missing_names = sorted(required_names - found_names)
if missing_names:
    print(
        "error: exact required test node names are missing from xcresult: "
        + ", ".join(missing_names),
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
  then
    exit 1
  fi
fi

printf 'Verified xcresult schema=%s: result=%s total=%s minimum=%s passed=%s failed=%s skipped=%s maximum-skipped=%s\n' \
  "$XCRESULT_SCHEMA_VERSION" "$SUMMARY_RESULT" "$TOTAL_TESTS" "$MINIMUM_TESTS" \
  "$PASSED_TESTS" "$FAILED_TESTS" "$SKIPPED_TESTS" "$MAXIMUM_SKIPPED"
