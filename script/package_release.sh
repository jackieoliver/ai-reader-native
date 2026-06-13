#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
PRODUCT_NAME="AIReader"
APP_NAME="AI Reader"
APP_EXECUTABLE_NAME="AIReader"
BUNDLE_ID="com.hapticasensorics.AIReader"
MIN_SYSTEM_VERSION="14.0"
RELEASE_VERSION="${AI_READER_RELEASE_VERSION:-1.3.0}"
BUILD_VERSION="${AI_READER_BUILD_VERSION:-$(date -u '+%Y%m%d%H%M%S')}"
BUILD_TIMESTAMP="${AI_READER_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
PROJECT_ROOT_VALUE="${AI_READER_PROJECT_ROOT_OVERRIDE:-$ROOT_DIR}"
PUBLIC_RELEASE="${AI_READER_PUBLIC_RELEASE:-1}"

require_bool() {
  local name="$1"
  local value="$2"
  case "$value" in
    0|1) ;;
    *)
      echo "error: $name must be 0 or 1." >&2
      exit 2
      ;;
  esac
}

if [[ -n "${AI_READER_RELEASE_TAG:-}" ]]; then
  RELEASE_TAG="$AI_READER_RELEASE_TAG"
else
  IFS=. read -r major minor _ <<<"$RELEASE_VERSION"
  RELEASE_TAG="v$major.$minor"
fi

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DMG_PATH="$DIST_DIR/AIReader-$RELEASE_TAG.dmg"
STAGE_ROOT="$ROOT_DIR/.build/release-dmg"
VOLUME_ROOT="$STAGE_ROOT/$APP_NAME $RELEASE_TAG"
BUILD_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.build.log"
APP_CODESIGN_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.app.codesign.txt"
DMG_CODESIGN_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.dmg.codesign.txt"
SPCTL_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.spctl.txt"
NOTARY_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.notarytool.json"
STAPLER_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.stapler.txt"

require_bool "AI_READER_PUBLIC_RELEASE" "$PUBLIC_RELEASE"
REQUIRE_NOTARIZATION="${AI_READER_REQUIRE_NOTARIZATION:-$PUBLIC_RELEASE}"
REQUIRE_SPCTL="${AI_READER_REQUIRE_SPCTL:-$PUBLIC_RELEASE}"
if [[ "$PUBLIC_RELEASE" == "1" ]]; then
  REQUIRE_NOTARIZATION=1
  REQUIRE_SPCTL=1
fi
require_bool "AI_READER_REQUIRE_NOTARIZATION" "$REQUIRE_NOTARIZATION"
require_bool "AI_READER_REQUIRE_SPCTL" "$REQUIRE_SPCTL"

SIGN_IDENTITY="${AI_READER_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: no Developer ID Application signing identity found." >&2
  exit 2
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" && -z "${AI_READER_NOTARY_PROFILE:-}" ]]; then
  echo "error: public release packaging requires AI_READER_NOTARY_PROFILE for notarization." >&2
  echo "       For a local signed candidate smoke, rerun with AI_READER_PUBLIC_RELEASE=0." >&2
  exit 2
fi

plist_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

mkdir -p "$DIST_DIR"

swift build -c release --product "$PRODUCT_NAME" 2>&1 | tee "$BUILD_LOG"
BUILD_BINARY="$(swift build -c release --show-bin-path)/$PRODUCT_NAME"
if [[ ! -x "$BUILD_BINARY" ]]; then
  echo "error: release binary not found at $BUILD_BINARY" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
/usr/bin/ditto --norsrc --noqtn "$BUILD_BINARY" "$APP_BINARY"
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
  <string>$(plist_escape "$APP_NAME")</string>
  <key>CFBundleDisplayName</key>
  <string>$(plist_escape "$APP_NAME")</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$(plist_escape "$RELEASE_VERSION")</string>
  <key>CFBundleVersion</key>
  <string>$(plist_escape "$BUILD_VERSION")</string>
  <key>AIReaderAppIdentity</key>
  <string>official</string>
  <key>AIReaderPermissionTestID</key>
  <string></string>
  <key>AIReaderPreferencesDomain</key>
  <string>$(plist_escape "$BUNDLE_ID")</string>
  <key>AIReaderBuildTimestamp</key>
  <string>$(plist_escape "$BUILD_TIMESTAMP")</string>
  <key>AIReaderProjectRoot</key>
  <string>$(plist_escape "$PROJECT_ROOT_VALUE")</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
/usr/bin/codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE" >"$APP_CODESIGN_LOG" 2>&1
/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" >>"$APP_CODESIGN_LOG" 2>&1

rm -rf "$STAGE_ROOT"
mkdir -p "$VOLUME_ROOT"
/usr/bin/ditto --norsrc --noqtn "$APP_BUNDLE" "$VOLUME_ROOT/$APP_NAME.app"
ln -s /Applications "$VOLUME_ROOT/Applications"

rm -f "$DMG_PATH"
/usr/bin/hdiutil create \
  -volname "$APP_NAME $RELEASE_TAG" \
  -srcfolder "$VOLUME_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

/usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH" >/dev/null
/usr/bin/codesign --verify --verbose=2 "$DMG_PATH" >"$DMG_CODESIGN_LOG" 2>&1
/usr/bin/shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

if [[ -n "${AI_READER_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$AI_READER_NOTARY_PROFILE" \
    --wait \
    --timeout "${AI_READER_NOTARY_TIMEOUT:-30m}" \
    --output-format json | tee "$NOTARY_LOG"
  xcrun stapler staple "$DMG_PATH" 2>&1 | tee "$STAPLER_LOG"
  xcrun stapler validate -v "$DMG_PATH" 2>&1 | tee -a "$STAPLER_LOG"
else
  if xcrun stapler validate -v "$DMG_PATH" >"$STAPLER_LOG" 2>&1; then
    cat "$STAPLER_LOG"
  else
    cat "$STAPLER_LOG"
    if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
      echo "error: no notarization ticket is stapled. Set AI_READER_NOTARY_PROFILE to notarize during packaging." >&2
      exit 1
    fi
    echo "warning: no notarization ticket is stapled. This DMG is not approved for public release." >&2
  fi
fi

if /usr/sbin/spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" >"$SPCTL_LOG" 2>&1; then
  cat "$SPCTL_LOG"
else
  status=$?
  cat "$SPCTL_LOG"
  if [[ "$REQUIRE_SPCTL" == "1" ]]; then
    echo "error: Gatekeeper assessment did not accept the DMG. This is not a public release artifact." >&2
    exit "$status"
  fi
  echo "warning: Gatekeeper assessment did not accept the DMG. This candidate is not approved for public release." >&2
fi

if [[ "$PUBLIC_RELEASE" == "1" ]]; then
  echo "public_release_ready=1"
else
  echo "public_release_ready=0"
fi
echo "release_dmg=$DMG_PATH"
