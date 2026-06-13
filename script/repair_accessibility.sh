#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${AI_READER_RELEASE_APP_NAME:-AI Reader}"
APP_BUNDLE="${AI_READER_INSTALLED_APP_BUNDLE:-/Applications/$APP_NAME.app}"
EXPECTED_BUNDLE_ID="${AI_READER_EXPECTED_BUNDLE_ID:-com.hapticasensorics.AIReader}"
EXPECTED_SIGNING_PREFIX="${AI_READER_EXPECTED_SIGNING_PREFIX:-Developer ID Application:}"
WAIT_SECONDS="${AI_READER_ACCESSIBILITY_REPAIR_TIMEOUT:-180}"

usage() {
  cat <<USAGE
usage: $0 [--app PATH]

Repairs Accessibility for the installed official AI Reader app.

Environment:
  AI_READER_INSTALLED_APP_BUNDLE        Installed app path. Defaults to /Applications/AI Reader.app.
  AI_READER_ACCESSIBILITY_REPAIR_TIMEOUT
                                        Seconds to wait for the user to grant permission.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_BUNDLE="${2:?missing value for --app}"
      shift 2
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

fail() {
  echo "error: $*" >&2
  exit 1
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

absolute_path() {
  local path="$1"
  local dir
  local base
  dir="$(cd "$(dirname "$path")" && pwd -P)"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
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

tcc_service_matches() {
  local service="$1"
  local expected_requirement="$2"
  local requirement

  requirement="$(tcc_requirement_for_service "$service")" || return 1
  [[ "$requirement" == "$expected_requirement" ]]
}

reset_stale_tcc_service() {
  local db_service="$1"
  local tccutil_service="$2"
  local expected_requirement="$3"
  local requirement

  if requirement="$(tcc_requirement_for_service "$db_service")"; then
    if [[ "$requirement" == "$expected_requirement" ]]; then
      echo "ok: ${db_service#kTCCService}_requirement_matches_current_signature"
      return
    fi
    echo "info: resetting stale ${db_service#kTCCService} grant"
    echo "info: stale_requirement=$requirement"
    /usr/bin/tccutil reset "$tccutil_service" "$EXPECTED_BUNDLE_ID" >/dev/null
    return
  fi

  echo "info: no approved ${db_service#kTCCService} grant found yet"
}

run_launchservices_permission_probe() {
  local probe_file="$1"
  local probe_log="$2"

  rm -f "$probe_file"
  /usr/bin/open -n "$APP_BUNDLE" --args --permission-probe-file "$probe_file" >"$probe_log" 2>&1 || true
  for _ in {1..80}; do
    if [[ -f "$probe_file" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

[[ -d "$APP_BUNDLE" ]] || fail "installed app not found: $APP_BUNDLE"
APP_BUNDLE="$(absolute_path "$APP_BUNDLE")"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "missing Info.plist at $INFO_PLIST"

bundle_id="$(plist_value "$INFO_PLIST" CFBundleIdentifier)"
app_identity="$(plist_value "$INFO_PLIST" AIReaderAppIdentity)"
app_version="$(plist_value "$INFO_PLIST" CFBundleShortVersionString)"
build_version="$(plist_value "$INFO_PLIST" CFBundleVersion)"

[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] \
  || fail "expected bundle id $EXPECTED_BUNDLE_ID, got ${bundle_id:-missing}"
[[ "$app_identity" == "official" ]] \
  || fail "expected AIReaderAppIdentity=official, got ${app_identity:-missing}"

codesign_details="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)" \
  || fail "could not inspect app codesign details"
signing_identity="$(awk -F= '/^Authority=/ { print $2; exit }' <<<"$codesign_details")"
[[ "$signing_identity" == "$EXPECTED_SIGNING_PREFIX"* ]] \
  || fail "expected signing identity prefix '$EXPECTED_SIGNING_PREFIX', got ${signing_identity:-missing}"

expected_requirement="$(current_designated_requirement)"
[[ -n "$expected_requirement" ]] || fail "could not determine current app designated requirement"

echo "info: app=$APP_BUNDLE"
echo "info: version=${app_version:-unknown} build=${build_version:-unknown}"
echo "info: signing_identity=$signing_identity"
echo "info: designated_requirement=$expected_requirement"

reset_stale_tcc_service "kTCCServiceAccessibility" "Accessibility" "$expected_requirement"
reset_stale_tcc_service "kTCCServiceListenEvent" "ListenEvent" "$expected_requirement"

probe_file="$(mktemp "${TMPDIR:-/tmp}/ai-reader-accessibility-repair.XXXXXX")"
probe_log="$(mktemp "${TMPDIR:-/tmp}/ai-reader-accessibility-repair-log.XXXXXX")"
trap 'rm -f "$probe_file" "$probe_log"' EXIT

if run_launchservices_permission_probe "$probe_file" "$probe_log"; then
  accessibility_trusted="$(awk -F= '$1 == "accessibility_trusted" { print $2; exit }' "$probe_file")"
  hotkey_ready="$(awk -F= '$1 == "hotkey_start_ready" { print $2; exit }' "$probe_file")"
  if [[ "$accessibility_trusted" == "true" && "$hotkey_ready" == "true" ]] \
    && tcc_service_matches "kTCCServiceAccessibility" "$expected_requirement" \
    && tcc_service_matches "kTCCServiceListenEvent" "$expected_requirement"; then
    cat "$probe_file"
    echo "accessibility_repair_passed=1"
    exit 0
  fi
fi

echo "info: opening Accessibility repair prompt for the installed official app"
/usr/bin/open -n "$APP_BUNDLE" --args --request-accessibility
echo "repair_request_started=1"
echo "action_required=Grant AI Reader in System Settings > Privacy & Security > Accessibility."

deadline=$((SECONDS + WAIT_SECONDS))
while [[ "$SECONDS" -lt "$deadline" ]]; do
  if run_launchservices_permission_probe "$probe_file" "$probe_log"; then
    accessibility_trusted="$(awk -F= '$1 == "accessibility_trusted" { print $2; exit }' "$probe_file")"
    hotkey_ready="$(awk -F= '$1 == "hotkey_start_ready" { print $2; exit }' "$probe_file")"
    if [[ "$accessibility_trusted" == "true" && "$hotkey_ready" == "true" ]] \
      && tcc_service_matches "kTCCServiceAccessibility" "$expected_requirement" \
      && tcc_service_matches "kTCCServiceListenEvent" "$expected_requirement"; then
      cat "$probe_file"
      echo "accessibility_repair_passed=1"
      echo "next=./script/release_smoke.sh --installed-app --require-accessibility"
      exit 0
    fi
  fi
  sleep 2
done

cat "$probe_file" 2>/dev/null || true
echo "accessibility_repair_passed=0"
echo "next=Grant AI Reader in System Settings, then run: ./script/release_smoke.sh --installed-app --require-accessibility"
exit 1
