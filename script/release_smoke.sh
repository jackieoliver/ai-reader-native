#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="${AI_READER_RELEASE_APP_NAME:-AI Reader}"
EXPECTED_BUNDLE_ID="${AI_READER_EXPECTED_BUNDLE_ID:-com.hapticasensorics.AIReader}"
EXPECTED_SIGNING_PREFIX="${AI_READER_EXPECTED_SIGNING_PREFIX:-Developer ID Application:}"

APP_BUNDLE="${AI_READER_APP_BUNDLE:-$DIST_DIR/$APP_NAME.app}"
DMG_PATH="${AI_READER_DMG_PATH:-}"
INSTALLED_APP_BUNDLE="${AI_READER_INSTALLED_APP_BUNDLE:-/Applications/$APP_NAME.app}"
EXPECTED_VERSION="${AI_READER_RELEASE_VERSION:-}"
ALLOW_UNNOTARIZED="${AI_READER_ALLOW_UNNOTARIZED:-0}"
REQUIRE_ACCESSIBILITY="${AI_READER_REQUIRE_ACCESSIBILITY:-0}"
CHECK_INSTALLED_APP=0

failures=0
public_release_blockers=0
mount_point=""
mount_parent=""
probe_dir=""
tmp_files=()

usage() {
  cat <<USAGE
usage: $0 [--app PATH] [--dmg PATH] [--version VERSION] [--installed-app] [--require-accessibility] [--allow-unnotarized]

Verifies the release app and DMG without installing over /Applications.

Environment:
  AI_READER_RELEASE_VERSION       Expected CFBundleShortVersionString.
  AI_READER_RELEASE_TAG           Expected DMG tag, e.g. v1.3.
  AI_READER_APP_BUNDLE            App bundle path. Defaults to dist/AI Reader.app.
  AI_READER_DMG_PATH              DMG path. Defaults to the release tag or newest dist/AIReader-v*.dmg.
  AI_READER_INSTALLED_APP_BUNDLE  Installed app path for --installed-app. Defaults to /Applications/AI Reader.app.
  AI_READER_REQUIRE_ACCESSIBILITY Require the permission probe to have Accessibility trust and a ready hotkey tap.
  AI_READER_ALLOW_UNNOTARIZED=1   Let local smoke pass while still reporting the public-release blocker.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_BUNDLE="${2:?missing value for --app}"
      shift 2
      ;;
    --dmg)
      DMG_PATH="${2:?missing value for --dmg}"
      shift 2
      ;;
    --version)
      EXPECTED_VERSION="${2:?missing value for --version}"
      shift 2
      ;;
    --installed-app)
      APP_BUNDLE="$INSTALLED_APP_BUNDLE"
      CHECK_INSTALLED_APP=1
      shift
      ;;
    --require-accessibility)
      REQUIRE_ACCESSIBILITY=1
      shift
      ;;
    --allow-unnotarized)
      ALLOW_UNNOTARIZED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

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

cleanup() {
  detach_dmg quiet
  if [[ -n "$probe_dir" && -d "$probe_dir" ]]; then
    rm -rf "$probe_dir"
  fi
  local file
  for file in "${tmp_files[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

note() {
  printf 'info: %s\n' "$*"
}

pass() {
  printf 'ok: %s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

detach_dmg() {
  local mode="${1:-quiet}"
  local detach_log
  if [[ -n "$mount_point" && -d "$mount_point" ]]; then
    detach_log="$(make_tmp_file)"
    if /usr/bin/hdiutil detach "$mount_point" >"$detach_log" 2>&1; then
      if [[ "$mode" == "report" ]]; then
        pass "dmg detached"
      fi
    else
      if [[ "$mode" == "report" ]]; then
        fail "dmg detach failed: $(tr '\n' ' ' <"$detach_log")"
      fi
    fi
  fi
  mount_point=""
  if [[ -n "$mount_parent" && -d "$mount_parent" ]]; then
    rmdir "$mount_parent" >/dev/null 2>&1 || true
  fi
  mount_parent=""
}

public_blocker() {
  printf 'PUBLIC RELEASE BLOCKER: %s\n' "$*" >&2
  public_release_blockers=$((public_release_blockers + 1))
}

make_tmp_file() {
  local file
  file="$(mktemp "${TMPDIR:-/tmp}/ai-reader-release-smoke.XXXXXX")"
  tmp_files+=("$file")
  printf '%s\n' "$file"
}

absolute_path() {
  local path="$1"
  local dir
  local base
  dir="$(cd "$(dirname "$path")" && pwd -P)"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

release_tag_from_version() {
  local version="$1"
  local major
  local minor
  IFS=. read -r major minor _ <<<"$version"
  if [[ -z "${major:-}" || -z "${minor:-}" ]]; then
    return 1
  fi
  printf 'v%s.%s\n' "$major" "$minor"
}

newest_dmg() {
  local candidate=""
  local candidate_mtime=0
  local file
  local file_mtime
  for file in "$DIST_DIR"/AIReader-v*.dmg; do
    [[ -e "$file" ]] || continue
    file_mtime="$(/usr/bin/stat -f '%m' "$file" 2>/dev/null || printf '0')"
    if [[ "$file_mtime" -gt "$candidate_mtime" ]]; then
      candidate="$file"
      candidate_mtime="$file_mtime"
    fi
  done
  printf '%s\n' "$candidate"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

kv_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$file"
}

contains() {
  local needle="$1"
  local file="$2"
  grep -Fq "$needle" "$file"
}

current_designated_requirement() {
  /usr/bin/codesign -dr - "$APP_BUNDLE" 2>&1 | sed -n 's/^designated => //p'
}

tcc_requirement_for_service() {
  local service="$1"
  local db="/Library/Application Support/com.apple.TCC/TCC.db"
  local hex

  [[ -r "$db" ]] || return 2
  hex="$(/usr/bin/sqlite3 "$db" "select hex(csreq) from access where service='$service' and client='$EXPECTED_BUNDLE_ID' and auth_value=2 order by last_modified desc limit 1;" 2>/dev/null || true)"
  [[ -n "$hex" ]] || return 1
  printf '%s' "$hex" | /usr/bin/xxd -r -p | /usr/bin/csreq -r- -t 2>/dev/null
}

audit_tcc_service() {
  local service="$1"
  local expected_requirement="$2"
  local requirement

  if requirement="$(tcc_requirement_for_service "$service")"; then
    if [[ "$requirement" == "$expected_requirement" ]]; then
      pass "tcc_${service#kTCCService}_requirement_matches_current_signature"
    else
      fail "stale TCC grant for $service; run script/repair_accessibility.sh. current='$expected_requirement' tcc='$requirement'"
    fi
    return
  fi

  case "$?" in
    1)
      fail "missing approved TCC grant for $service and $EXPECTED_BUNDLE_ID"
      ;;
    2)
      fail "could not read /Library/Application Support/com.apple.TCC/TCC.db to audit $service"
      ;;
    *)
      fail "could not decode TCC grant for $service"
      ;;
  esac
}

audit_tcc_if_required() {
  local expected_requirement

  if [[ "$REQUIRE_ACCESSIBILITY" != "1" ]]; then
    return 0
  fi

  expected_requirement="$(current_designated_requirement)"
  if [[ -z "$expected_requirement" ]]; then
    fail "could not determine current app designated requirement for TCC audit"
    return
  fi

  audit_tcc_service "kTCCServiceAccessibility" "$expected_requirement"
  audit_tcc_service "kTCCServiceListenEvent" "$expected_requirement"
}

wait_for_probe_file() {
  local file="$1"
  for _ in {1..80}; do
    if [[ -f "$file" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

if [[ -z "$DMG_PATH" ]]; then
  if [[ -n "${AI_READER_RELEASE_TAG:-}" ]]; then
    DMG_PATH="$DIST_DIR/AIReader-$AI_READER_RELEASE_TAG.dmg"
  elif [[ -n "$EXPECTED_VERSION" ]]; then
    DMG_PATH="$DIST_DIR/AIReader-$(release_tag_from_version "$EXPECTED_VERSION").dmg"
  else
    DMG_PATH="$(newest_dmg)"
  fi
fi

if [[ -z "$DMG_PATH" ]]; then
  echo "error: no release DMG found. Run script/package_release.sh first or pass --dmg." >&2
  exit 2
fi

require_bool "AI_READER_REQUIRE_ACCESSIBILITY" "$REQUIRE_ACCESSIBILITY"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: app bundle not found: $APP_BUNDLE" >&2
  exit 2
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "error: DMG not found: $DMG_PATH" >&2
  exit 2
fi

APP_BUNDLE="$(absolute_path "$APP_BUNDLE")"
DMG_PATH="$(absolute_path "$DMG_PATH")"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

note "app=$APP_BUNDLE"
note "dmg=$DMG_PATH"

case "$(basename "$APP_BUNDLE")" in
  AI\ Reader\ Dev.app|AI\ Reader\ Dev\ -*.app)
    fail "refusing to smoke the local dogfood app; pass the release app bundle instead"
    ;;
esac

if [[ "$CHECK_INSTALLED_APP" == "1" ]]; then
  expected_installed_app_bundle="$(absolute_path "$INSTALLED_APP_BUNDLE")"
  if [[ "$APP_BUNDLE" == "$expected_installed_app_bundle" ]]; then
    pass "installed_app_bundle=$APP_BUNDLE"
  else
    fail "--installed-app expected $expected_installed_app_bundle, got $APP_BUNDLE"
  fi
fi

if [[ ! -f "$INFO_PLIST" ]]; then
  fail "missing Info.plist at $INFO_PLIST"
fi

app_version="$(plist_value "$INFO_PLIST" CFBundleShortVersionString)"
build_version="$(plist_value "$INFO_PLIST" CFBundleVersion)"
bundle_id="$(plist_value "$INFO_PLIST" CFBundleIdentifier)"
executable_name="$(plist_value "$INFO_PLIST" CFBundleExecutable)"
app_identity="$(plist_value "$INFO_PLIST" AIReaderAppIdentity)"

if [[ -z "$app_version" ]]; then
  fail "CFBundleShortVersionString is missing"
elif [[ -n "$EXPECTED_VERSION" && "$app_version" != "$EXPECTED_VERSION" ]]; then
  fail "version mismatch: expected $EXPECTED_VERSION, got $app_version"
else
  pass "version=$app_version"
fi

if [[ -z "$build_version" ]]; then
  fail "CFBundleVersion is missing"
else
  pass "build_version=$build_version"
fi

if [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]]; then
  pass "bundle_id=$bundle_id"
else
  fail "bundle id mismatch: expected $EXPECTED_BUNDLE_ID, got ${bundle_id:-missing}"
fi

if [[ "$app_identity" == "official" ]]; then
  pass "app_identity=official"
else
  fail "AIReaderAppIdentity should be official, got ${app_identity:-missing}"
fi

if [[ -z "$executable_name" || ! -x "$APP_BUNDLE/Contents/MacOS/$executable_name" ]]; then
  fail "release executable is missing or not executable"
else
  pass "executable=$executable_name"
fi

app_verify_log="$(make_tmp_file)"
if /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE" >"$app_verify_log" 2>&1; then
  pass "app codesign verifies with --strict --deep"
else
  fail "app codesign verification failed: $(tr '\n' ' ' <"$app_verify_log")"
fi

if app_codesign_details="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"; then
  app_codesign_log="$(make_tmp_file)"
  printf '%s\n' "$app_codesign_details" >"$app_codesign_log"
  signing_identity="$(awk -F= '/^Authority=/ { print $2; exit }' "$app_codesign_log")"
  team_id="$(awk -F= '/^TeamIdentifier=/ { print $2; exit }' "$app_codesign_log")"
  if [[ "$signing_identity" == "$EXPECTED_SIGNING_PREFIX"* ]]; then
    pass "signing_identity=$signing_identity team_id=${team_id:-unknown}"
  else
    fail "expected signing identity prefix '$EXPECTED_SIGNING_PREFIX', got ${signing_identity:-missing}"
  fi
  if contains "(runtime)" "$app_codesign_log"; then
    pass "hardened_runtime=enabled"
  else
    fail "hardened runtime flag is missing from app signature"
  fi
else
  fail "could not inspect app codesign details"
fi

dmg_verify_log="$(make_tmp_file)"
if /usr/bin/hdiutil verify "$DMG_PATH" >"$dmg_verify_log" 2>&1; then
  pass "dmg image verifies"
else
  fail "hdiutil verify failed: $(tr '\n' ' ' <"$dmg_verify_log")"
fi

dmg_codesign_log="$(make_tmp_file)"
if /usr/bin/codesign --verify --verbose=2 "$DMG_PATH" >"$dmg_codesign_log" 2>&1; then
  pass "dmg codesign verifies"
else
  fail "dmg codesign verification failed: $(tr '\n' ' ' <"$dmg_codesign_log")"
fi

mount_parent="$(mktemp -d "${TMPDIR:-/tmp}/ai-reader-dmg.XXXXXX")"
attach_log="$(make_tmp_file)"
if /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$mount_parent" -plist "$DMG_PATH" >"$attach_log" 2>&1; then
  mount_point="$mount_parent"
  pass "dmg mounted read-only"
else
  fail "dmg attach failed: $(tr '\n' ' ' <"$attach_log")"
fi

if [[ -n "$mount_point" && -d "$mount_point" ]]; then
  dmg_app="$mount_point/$APP_NAME.app"
  applications_link="$mount_point/Applications"
  if [[ -d "$dmg_app" ]]; then
    pass "dmg contains $APP_NAME.app"
    dmg_info_plist="$dmg_app/Contents/Info.plist"
    dmg_app_version="$(plist_value "$dmg_info_plist" CFBundleShortVersionString)"
    dmg_build_version="$(plist_value "$dmg_info_plist" CFBundleVersion)"
    dmg_bundle_id="$(plist_value "$dmg_info_plist" CFBundleIdentifier)"
    if [[ "$dmg_app_version" == "$app_version" ]]; then
      pass "dmg_app_version=$dmg_app_version"
    else
      fail "DMG app version mismatch: dist app is ${app_version:-missing}, DMG app is ${dmg_app_version:-missing}"
    fi
    if [[ "$dmg_build_version" == "$build_version" ]]; then
      pass "dmg_build_version=$dmg_build_version"
    else
      fail "DMG app build version mismatch: app is ${build_version:-missing}, DMG app is ${dmg_build_version:-missing}"
    fi
    if [[ "$dmg_bundle_id" == "$bundle_id" ]]; then
      pass "dmg_app_bundle_id=$dmg_bundle_id"
    else
      fail "DMG app bundle id mismatch: dist app is ${bundle_id:-missing}, DMG app is ${dmg_bundle_id:-missing}"
    fi
  else
    fail "dmg is missing $APP_NAME.app"
  fi
  if [[ -L "$applications_link" && "$(readlink "$applications_link")" == "/Applications" ]]; then
    pass "dmg contains Applications symlink"
  else
    fail "dmg Applications link should be a symlink to /Applications"
  fi
fi
detach_dmg report

dogfood_app="/Applications/AI Reader Dev.app"
dogfood_before=""
dogfood_after=""
if [[ -d "$dogfood_app" ]]; then
  dogfood_before="$(/usr/bin/stat -f '%m:%z' "$dogfood_app" 2>/dev/null || true)"
fi

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-reader-permission-probe.XXXXXX")"
permission_probe_file="$probe_dir/permission-probe.txt"
permission_probe_log="$(make_tmp_file)"
if [[ -n "${executable_name:-}" && -x "$APP_BUNDLE/Contents/MacOS/$executable_name" ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args --permission-probe-file "$permission_probe_file" >"$permission_probe_log" 2>&1 || true
  if ! wait_for_probe_file "$permission_probe_file"; then
    fail "permission probe did not write $permission_probe_file: $(tr '\n' ' ' <"$permission_probe_log")"
  fi
else
  fail "permission probe executable is missing"
fi

if [[ -f "$permission_probe_file" ]]; then
  probe_bundle_url="$(kv_value bundle_url "$permission_probe_file")"
  probe_bundle_id="$(kv_value bundle_identifier "$permission_probe_file")"
  accessibility_trusted="$(kv_value accessibility_trusted "$permission_probe_file")"
  hotkey_ready="$(kv_value hotkey_start_ready "$permission_probe_file")"
  hotkey_tap_active="$(kv_value hotkey_tap_active "$permission_probe_file")"
  hotkey_start_error="$(kv_value hotkey_start_error "$permission_probe_file")"
  if [[ "$probe_bundle_id" == "$EXPECTED_BUNDLE_ID" && "$probe_bundle_url" == "$APP_BUNDLE" ]]; then
    pass "permission_probe_identity bundle_id=$probe_bundle_id bundle_url=$probe_bundle_url"
  else
    fail "permission probe used unexpected app identity: bundle_url=${probe_bundle_url:-missing} bundle_id=${probe_bundle_id:-missing}"
  fi
  if [[ "$accessibility_trusted" == "true" && "$hotkey_ready" == "true" && ("$hotkey_tap_active" == "true" || -z "$hotkey_tap_active") ]]; then
    pass "accessibility_permission_ready=1 hotkey_start_ready=true hotkey_tap_active=${hotkey_tap_active:-not_reported}"
  else
    permission_message="Accessibility permission is not ready for $APP_BUNDLE: accessibility_trusted=${accessibility_trusted:-unknown} hotkey_start_ready=${hotkey_ready:-unknown} hotkey_tap_active=${hotkey_tap_active:-unknown} hotkey_start_error=${hotkey_start_error:-}. Run script/repair_accessibility.sh, grant the installed official app, then rerun with --installed-app --require-accessibility."
    if [[ "$REQUIRE_ACCESSIBILITY" == "1" ]]; then
      fail "$permission_message"
    else
      note "$permission_message"
    fi
  fi
else
  fail "permission probe did not write $permission_probe_file"
fi

audit_tcc_if_required

if [[ -d "$dogfood_app" ]]; then
  dogfood_after="$(/usr/bin/stat -f '%m:%z' "$dogfood_app" 2>/dev/null || true)"
  if [[ "$dogfood_before" == "$dogfood_after" ]]; then
    pass "dogfood_app_unchanged=$dogfood_app"
  else
    fail "dogfood app metadata changed while running release permission probe"
  fi
fi

launch_probe_log="$(make_tmp_file)"
if [[ -n "${executable_name:-}" && -x "$APP_BUNDLE/Contents/MacOS/$executable_name" ]]; then
  if "$APP_BUNDLE/Contents/MacOS/$executable_name" --launch-at-login-probe >"$launch_probe_log" 2>&1; then
    launch_bundle_id="$(kv_value bundle_identifier "$launch_probe_log")"
    running_from_bundle="$(kv_value running_from_app_bundle "$launch_probe_log")"
    state_can_change="$(kv_value state_can_change "$launch_probe_log")"
    smappservice_status="$(kv_value smappservice_status "$launch_probe_log")"
    if [[ "$launch_bundle_id" == "$EXPECTED_BUNDLE_ID" && "$running_from_bundle" == "true" && "$state_can_change" == "true" ]]; then
      pass "launch_at_login_probe_changeable status=${smappservice_status:-unknown}"
    else
      fail "launch-at-login probe did not report changeable app-bundle state: $(tr '\n' ' ' <"$launch_probe_log")"
    fi
  else
    fail "launch-at-login probe failed: $(tr '\n' ' ' <"$launch_probe_log")"
  fi
fi

stapler_log="$(make_tmp_file)"
if /usr/bin/xcrun stapler validate -v "$DMG_PATH" >"$stapler_log" 2>&1; then
  pass "notarization_ticket=stapled"
else
  public_blocker "notarization required before public release; stapler validate failed: $(tail -n 1 "$stapler_log")"
fi

spctl_log="$(make_tmp_file)"
if /usr/sbin/spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" >"$spctl_log" 2>&1; then
  pass "gatekeeper_accepts_dmg=1"
else
  public_blocker "Gatekeeper rejects the DMG before notarization/stapling: $(tr '\n' ' ' <"$spctl_log")"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "release_smoke_passed=0 failures=$failures public_release_blockers=$public_release_blockers" >&2
  exit 1
fi

if [[ "$public_release_blockers" -gt 0 ]]; then
  echo "release_smoke_passed=0 failures=0 public_release_blockers=$public_release_blockers" >&2
  if [[ "$ALLOW_UNNOTARIZED" == "1" ]]; then
    echo "warning: continuing because AI_READER_ALLOW_UNNOTARIZED=1 or --allow-unnotarized was set" >&2
    exit 0
  fi
  exit 3
fi

echo "release_smoke_passed=1"
