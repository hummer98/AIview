#!/usr/bin/env bash
# notarize.sh — Notarize, staple, and package a Developer ID signed .app
#
# Reads a signed .app bundle (or extracts it from an .xcarchive), submits it
# to Apple's notary service, staples the resulting ticket, and produces
# distribution artifacts (.zip / .dmg / .sha256) under ./dist.
#
# See docs/release.md for prerequisites and step-by-step instructions.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DIST_DIR="${REPO_ROOT}/dist"
APP_NAME="AIview"

# Globals populated by parse_args / later stages.
APP_PATH=""
ARCHIVE_PATH=""
VERSION=""
TMP_WORK=""
SUBMIT_ZIP=""
RELEASE_ZIP=""
RELEASE_DMG=""
SUBMISSION_ID=""

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} (--app <path> | --archive <path>) --version <x.y.z>

Required (choose one of --app / --archive):
  --app <path>       Path to a signed ${APP_NAME}.app bundle
  --archive <path>   Path to an .xcarchive produced by 'xcodebuild archive'
  --version <x.y.z>  Semantic version string used in output filenames

Environment (required):
  ASC_KEY_ID           App Store Connect API Key ID (e.g. ABCD1234EF)
  ASC_ISSUER_ID        App Store Connect Issuer ID (UUID)
  ASC_PRIVATE_KEY_PATH Absolute path to the .p8 private key file

Output (under ./dist):
  ${APP_NAME}-<version>.zip           Notarized + stapled zip archive
  ${APP_NAME}-<version>.dmg           Notarized + stapled disk image
  ${APP_NAME}-<version>.zip.sha256    SHA-256 checksum for the zip
  ${APP_NAME}-<version>.dmg.sha256    SHA-256 checksum for the dmg

Options:
  -h, --help         Show this help text and exit

Examples:
  ${SCRIPT_NAME} --app build/${APP_NAME}.app --version 0.3.0
  ${SCRIPT_NAME} --archive build/${APP_NAME}.xcarchive --version 0.3.0
USAGE
}

log() {
  printf '==> %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    die "no arguments given"
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)
        [[ $# -ge 2 ]] || die "--app requires a value"
        APP_PATH="$2"
        shift 2
        ;;
      --archive)
        [[ $# -ge 2 ]] || die "--archive requires a value"
        ARCHIVE_PATH="$2"
        shift 2
        ;;
      --version)
        [[ $# -ge 2 ]] || die "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
  done
}

validate_args() {
  if [[ -n "$APP_PATH" && -n "$ARCHIVE_PATH" ]]; then
    die "--app and --archive are mutually exclusive"
  fi
  if [[ -z "$APP_PATH" && -z "$ARCHIVE_PATH" ]]; then
    die "one of --app or --archive is required"
  fi
  [[ -n "$VERSION" ]] || die "--version is required"

  # semver: MAJOR.MINOR.PATCH with optional prerelease tag (e.g. 1.2.3-rc.1)
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    die "invalid --version: '${VERSION}' (expected SEMVER like 1.2.3 or 1.2.3-rc.1)"
  fi

  if [[ -n "$APP_PATH" ]]; then
    [[ "$APP_PATH" == *.app ]] || die "--app must end with .app: $APP_PATH"
    [[ -d "$APP_PATH" ]] || die "--app path not found: $APP_PATH"
  fi
  if [[ -n "$ARCHIVE_PATH" ]]; then
    [[ "$ARCHIVE_PATH" == *.xcarchive ]] || die "--archive must end with .xcarchive: $ARCHIVE_PATH"
    [[ -d "$ARCHIVE_PATH" ]] || die "--archive path not found: $ARCHIVE_PATH"
  fi
}

check_env() {
  : "${ASC_KEY_ID:?ASC_KEY_ID is not set}"
  : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"
  : "${ASC_PRIVATE_KEY_PATH:?ASC_PRIVATE_KEY_PATH is not set}"
  [[ -f "$ASC_PRIVATE_KEY_PATH" ]] || die "ASC_PRIVATE_KEY_PATH file not found: $ASC_PRIVATE_KEY_PATH"
}

resolve_app_path() {
  if [[ -n "$ARCHIVE_PATH" ]]; then
    APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
    [[ -d "$APP_PATH" ]] || die "app not found in archive: $APP_PATH"
  fi
  [[ -d "$APP_PATH" ]] || die "app not found: $APP_PATH"
  log "app bundle: $APP_PATH"
}

setup_workspace() {
  TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/notarize-XXXXXX")"
  mkdir -p "$DIST_DIR"
}

verify_signature() {
  log "verifying signature: $APP_PATH"
  if ! codesign -vv --deep --strict "$APP_PATH"; then
    die "codesign verification failed for $APP_PATH"
  fi
  # Surface key signing metadata for the build log.
  codesign --display --verbose=2 "$APP_PATH" 2>&1 \
    | grep -E '^(Authority|TeamIdentifier|Identifier|flags)' >&2 || true
}

create_initial_zip() {
  SUBMIT_ZIP="${TMP_WORK}/${APP_NAME}-submit.zip"
  log "creating submission zip: $SUBMIT_ZIP"
  ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
}

extract_json_field() {
  # Extract a top-level string field from notarytool JSON output without
  # requiring jq. Tries plutil first (macOS stock) and falls back to sed.
  local json="$1" key="$2" value
  value="$(printf '%s' "$json" | /usr/bin/plutil -extract "$key" raw -o - - 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$(printf '%s' "$json" \
      | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
      | head -n 1)"
  fi
  printf '%s' "$value"
}

submit_notarization() {
  log "submitting to notarytool (this can take a few minutes)"
  local output status
  output="$(xcrun notarytool submit "$SUBMIT_ZIP" \
    --wait \
    --key "$ASC_PRIVATE_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --output-format json)"

  SUBMISSION_ID="$(extract_json_field "$output" "id")"
  status="$(extract_json_field "$output" "status")"
  log "submission id: ${SUBMISSION_ID:-<unknown>} / status: ${status:-<unknown>}"

  if [[ "$status" != "Accepted" ]]; then
    if [[ -n "$SUBMISSION_ID" ]]; then
      log "notarytool log for submission ${SUBMISSION_ID}:"
      xcrun notarytool log "$SUBMISSION_ID" \
        --key "$ASC_PRIVATE_KEY_PATH" \
        --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" >&2 || true
    fi
    die "notarization failed: status=${status:-unknown}"
  fi
}

staple_app() {
  log "stapling ticket to $APP_PATH"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl -a -vvv --type execute "$APP_PATH" 2>&1 | head -n 5 >&2 || true
}

recreate_zip() {
  RELEASE_ZIP="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"
  log "creating release zip: $RELEASE_ZIP"
  rm -f "$RELEASE_ZIP"
  ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"
}

create_dmg() {
  RELEASE_DMG="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
  local stage="${TMP_WORK}/dmg-stage"
  mkdir -p "$stage"
  cp -R "$APP_PATH" "$stage/"
  ln -s /Applications "$stage/Applications"

  log "creating dmg: $RELEASE_DMG"
  rm -f "$RELEASE_DMG"
  hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "$stage" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$RELEASE_DMG"

  # Staple the dmg as well so Gatekeeper can validate it offline.
  if ! xcrun stapler staple "$RELEASE_DMG"; then
    log "warning: stapling dmg failed (continuing)"
  fi
}

emit_sha256() {
  log "computing sha256 checksums"
  (
    cd "$DIST_DIR"
    local zip_name dmg_name
    zip_name="$(basename "$RELEASE_ZIP")"
    dmg_name="$(basename "$RELEASE_DMG")"
    shasum -a 256 "$zip_name" > "${zip_name}.sha256"
    shasum -a 256 "$dmg_name" > "${dmg_name}.sha256"
  )
}

on_error() {
  local line="$1" cmd="$2"
  printf 'error at line %s: %s\n' "$line" "$cmd" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    printf '--- notarytool log for submission %s ---\n' "$SUBMISSION_ID" >&2
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$ASC_PRIVATE_KEY_PATH" \
      --key-id "$ASC_KEY_ID" \
      --issuer "$ASC_ISSUER_ID" >&2 || true
  fi
}

cleanup() {
  local code=$?
  if [[ -n "${TMP_WORK:-}" && -d "$TMP_WORK" ]]; then
    rm -rf "$TMP_WORK"
  fi
  exit "$code"
}

main() {
  parse_args "$@"
  validate_args
  check_env
  resolve_app_path
  setup_workspace

  trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
  trap cleanup EXIT

  verify_signature
  create_initial_zip
  submit_notarization
  staple_app
  recreate_zip
  create_dmg
  emit_sha256

  log "✓ release artifacts ready in ${DIST_DIR}"
  log "    - $(basename "$RELEASE_ZIP")"
  log "    - $(basename "$RELEASE_DMG")"
  log "    - $(basename "$RELEASE_ZIP").sha256"
  log "    - $(basename "$RELEASE_DMG").sha256"
}

main "$@"
