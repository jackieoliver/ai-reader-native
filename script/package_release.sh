#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_VERSION="${AI_READER_RELEASE_VERSION:-1.2.0}"

if [[ -n "${AI_READER_RELEASE_TAG:-}" ]]; then
  RELEASE_TAG="$AI_READER_RELEASE_TAG"
else
  IFS=. read -r major minor _ <<<"$RELEASE_VERSION"
  RELEASE_TAG="v$major.$minor"
fi

ARTIFACT_VERSION="${RELEASE_TAG#v}"
APP_NAME="AI Reader"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/AIReader-$RELEASE_TAG.dmg"
STAGE_ROOT="$ROOT_DIR/.build/release-dmg"
VOLUME_ROOT="$STAGE_ROOT/$APP_NAME $RELEASE_TAG"
BUILD_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.build.log"
APP_CODESIGN_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.app.codesign.txt"
DMG_CODESIGN_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.dmg.codesign.txt"
SPCTL_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.spctl.txt"
NOTARY_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.notarytool.json"
STAPLER_LOG="$DIST_DIR/AIReader-$RELEASE_TAG.stapler.txt"

SIGN_IDENTITY="${AI_READER_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: no Developer ID Application signing identity found." >&2
  exit 2
fi

mkdir -p "$DIST_DIR"
AI_READER_APP_IDENTITY=official \
AI_READER_VERSION="$RELEASE_VERSION" \
AI_READER_SIGNING_MODE=developer-id \
AI_READER_CODESIGN_IDENTITY="$SIGN_IDENTITY" \
AI_READER_INSTALL_TO_APPLICATIONS=0 \
  "$ROOT_DIR/script/build_and_run.sh" --launch-at-login-probe | tee "$BUILD_LOG"

/usr/bin/codesign --verify --strict --deep "$APP_BUNDLE"
/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" >"$APP_CODESIGN_LOG" 2>&1

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
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate -v "$DMG_PATH" | tee "$STAPLER_LOG"
else
  if xcrun stapler validate -v "$DMG_PATH" >"$STAPLER_LOG" 2>&1; then
    cat "$STAPLER_LOG"
  else
    cat "$STAPLER_LOG"
    echo "warning: no notarization ticket is stapled. Set AI_READER_NOTARY_PROFILE to notarize during packaging." >&2
  fi
fi

if /usr/sbin/spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" >"$SPCTL_LOG" 2>&1; then
  cat "$SPCTL_LOG"
else
  cat "$SPCTL_LOG"
  echo "warning: Gatekeeper assessment did not accept the DMG. Notarize and staple before a public release." >&2
fi

echo "release_dmg=$DMG_PATH"
