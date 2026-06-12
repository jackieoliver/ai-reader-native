#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_VARIANT="${AI_READER_APP_IDENTITY:-${AI_READER_APP_VARIANT:-stable-dev}}"
PRODUCT_NAME="AIReader"
MIN_SYSTEM_VERSION="14.0"
SIGNING_MODE="${AI_READER_SIGNING_MODE:-apple-development}"
BUILD_STAMP="$(date -u '+%Y%m%d%H%M%S')"
BUILD_TIMESTAMP="${AI_READER_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
INSTALL_DIR="${AI_READER_INSTALL_DIR:-/Applications}"
INSTALL_TO_APPLICATIONS="${AI_READER_INSTALL_TO_APPLICATIONS:-1}"

normalize_permission_test_id() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

case "$APP_VARIANT" in
  permission-test|dev-permission|permission)
    APP_VARIANT="permission-test"
    PERMISSION_TEST_ID="$(normalize_permission_test_id "${AI_READER_PERMISSION_TEST_ID:-$BUILD_STAMP}")"
    if [[ -z "$PERMISSION_TEST_ID" || ${#PERMISSION_TEST_ID} -gt 40 ]]; then
      echo "error: AI_READER_PERMISSION_TEST_ID must normalize to 1-40 lowercase letters, digits, or hyphens." >&2
      exit 2
    fi
    DEFAULT_APP_BUNDLE_NAME="AI Reader Dev - $PERMISSION_TEST_ID"
    DEFAULT_APP_DISPLAY_NAME="AI Reader Dev - $PERMISSION_TEST_ID"
    DEFAULT_APP_EXECUTABLE_NAME="AIReaderDev"
    DEFAULT_BUNDLE_ID="com.hapticasensorics.AIReader.dev.permission.$PERMISSION_TEST_ID"
    DEFAULT_VERSION="1.1.0-dev"
    DEFAULT_APP_IDENTITY_PLIST_VALUE="dev-permission:$PERMISSION_TEST_ID"
    ;;
  dev|development|debug|local|stable-dev|stable_dev)
    APP_VARIANT="stable-dev"
    PERMISSION_TEST_ID=""
    DEFAULT_APP_BUNDLE_NAME="AI Reader Dev"
    DEFAULT_APP_DISPLAY_NAME="AI Reader Dev"
    DEFAULT_APP_EXECUTABLE_NAME="AIReaderDev"
    DEFAULT_BUNDLE_ID="com.hapticasensorics.AIReader.dev"
    DEFAULT_VERSION="1.1.0-dev"
    DEFAULT_APP_IDENTITY_PLIST_VALUE="dev"
    ;;
  official|release|prod|production|public)
    APP_VARIANT="official"
    PERMISSION_TEST_ID=""
    DEFAULT_APP_BUNDLE_NAME="AI Reader"
    DEFAULT_APP_DISPLAY_NAME="AI Reader"
    DEFAULT_APP_EXECUTABLE_NAME="AIReader"
    DEFAULT_BUNDLE_ID="com.hapticasensorics.AIReader"
    DEFAULT_VERSION="1.1.0"
    DEFAULT_APP_IDENTITY_PLIST_VALUE="official"
    ;;
  *)
    echo "error: AI_READER_APP_IDENTITY must be 'stable-dev', 'permission-test', or 'official'." >&2
    exit 2
    ;;
esac

APP_BUNDLE_NAME="${AI_READER_APP_BUNDLE_NAME:-$DEFAULT_APP_BUNDLE_NAME}"
APP_DISPLAY_NAME="${AI_READER_DISPLAY_NAME:-${AI_READER_APP_DISPLAY_NAME:-$DEFAULT_APP_DISPLAY_NAME}}"
APP_EXECUTABLE_NAME="${AI_READER_EXECUTABLE_NAME:-$DEFAULT_APP_EXECUTABLE_NAME}"
BUNDLE_ID="${AI_READER_BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
PREFERENCES_DOMAIN="${AI_READER_PREFERENCES_DOMAIN:-$BUNDLE_ID}"
VERSION="${AI_READER_VERSION:-$DEFAULT_VERSION}"
BUILD_VERSION="${AI_READER_BUILD_VERSION:-$BUILD_STAMP}"
APP_IDENTITY_PLIST_VALUE="${AI_READER_APP_IDENTITY_PLIST_VALUE:-$DEFAULT_APP_IDENTITY_PLIST_VALUE}"

APP_BUNDLE="$DIST_DIR/$APP_BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RUN_APP_BUNDLE="$APP_BUNDLE"

plist_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

pkill -x "$APP_EXECUTABLE_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$(plist_escape "$APP_EXECUTABLE_NAME")</string>
  <key>CFBundleIdentifier</key>
  <string>$(plist_escape "$BUNDLE_ID")</string>
  <key>CFBundleName</key>
  <string>$(plist_escape "$APP_BUNDLE_NAME")</string>
  <key>CFBundleDisplayName</key>
  <string>$(plist_escape "$APP_DISPLAY_NAME")</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$(plist_escape "$VERSION")</string>
  <key>CFBundleVersion</key>
  <string>$(plist_escape "$BUILD_VERSION")</string>
  <key>AIReaderAppIdentity</key>
  <string>$(plist_escape "$APP_IDENTITY_PLIST_VALUE")</string>
  <key>AIReaderPermissionTestID</key>
  <string>$(plist_escape "$PERMISSION_TEST_ID")</string>
  <key>AIReaderPreferencesDomain</key>
  <string>$(plist_escape "$PREFERENCES_DOMAIN")</string>
  <key>AIReaderBuildTimestamp</key>
  <string>$(plist_escape "$BUILD_TIMESTAMP")</string>
  <key>AIReaderProjectRoot</key>
  <string>$(plist_escape "$ROOT_DIR")</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

sign_app() {
  local identity="${AI_READER_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
  if [[ "$SIGNING_MODE" == "apple-development" && -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ { print $2; exit }')"
  fi

  if [[ "$SIGNING_MODE" == "apple-development" && -n "$identity" ]]; then
    /usr/bin/codesign --force --deep --options runtime --sign "$identity" "$APP_BUNDLE" >/dev/null
    /usr/bin/codesign --verify --strict --deep "$APP_BUNDLE" >/dev/null
    return
  fi

  if [[ "$APP_VARIANT" == "permission-test" ]]; then
    echo "error: permission-test builds require an Apple Development codesigning identity so macOS permissions can be tested honestly." >&2
    echo "       Set AI_READER_SIGNING_MODE=apple-development and CODESIGN_IDENTITY if auto-discovery fails." >&2
    exit 2
  fi

  echo "warning: no Apple Development codesigning identity found; using ad-hoc signing, so macOS permission grants may not survive rebuilds." >&2
  /usr/bin/codesign --force --deep --options runtime --sign - "$APP_BUNDLE" >/dev/null
  /usr/bin/codesign --verify --strict --deep "$APP_BUNDLE" >/dev/null
}

open_app() {
  /usr/bin/open -n "$RUN_APP_BUNDLE"
}

run_app_binary() {
  AI_READER_PROJECT_ROOT="$ROOT_DIR" "$RUN_APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE_NAME" "$@"
}

sign_app

if [[ "$INSTALL_TO_APPLICATIONS" == "1" ]]; then
  INSTALLED_APP_BUNDLE="$INSTALL_DIR/$APP_BUNDLE_NAME.app"
  rm -rf "$INSTALLED_APP_BUNDLE"
  /usr/bin/ditto --norsrc --noqtn "$APP_BUNDLE" "$INSTALLED_APP_BUNDLE"
  RUN_APP_BUNDLE="$INSTALLED_APP_BUNDLE"
fi

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_EXECUTABLE_NAME" >/dev/null
    ;;
  --shortcut-probe|shortcut-probe)
    run_app_binary --shortcut-probe
    ;;
  --clipboard-probe|clipboard-probe)
    run_app_binary --clipboard-probe
    ;;
  --tts-probe|tts-probe)
    run_app_binary --tts-probe
    ;;
  --playback-seek-probe|playback-seek-probe)
    run_app_binary --playback-seek-probe
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--shortcut-probe|--clipboard-probe|--tts-probe|--playback-seek-probe]" >&2
    echo "       AI_READER_APP_IDENTITY=permission-test|stable-dev|official $0" >&2
    exit 2
    ;;
esac
