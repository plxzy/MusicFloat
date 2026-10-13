#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi
if [[ "${1:-}" == "--" ]]; then
  shift
fi
APP_ARGS=("$@")
APP_NAME="MusicFloat"
BUNDLE_ID="cv.MusicFloat"
PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$PWD/.codex/DerivedData}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--memory] [-- app args]" >&2
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--memory|memory)
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

stop_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/killall "$APP_NAME" >/dev/null 2>&1 || true

  local attempt
  for attempt in {1..20}; do
    if ! /usr/bin/pgrep -x "$APP_NAME" >/dev/null; then
      return 0
    fi
    /bin/sleep 0.1
  done
}

build_app() {
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build
}

open_app() {
  if [[ ${#APP_ARGS[@]} -gt 0 ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args "${APP_ARGS[@]}"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

wait_for_pid() {
  local attempt
  local pid
  local command
  for attempt in {1..30}; do
    while IFS= read -r pid; do
      command="$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)"
      if [[ "$command" == "$APP_BUNDLE/Contents/MacOS/$APP_NAME"* ]]; then
        echo "$pid"
        return 0
      fi
    done < <(/usr/bin/pgrep -x "$APP_NAME" || true)
    /bin/sleep 0.2
  done
  return 1
}

sample_memory() {
  local pid="$1"
  /bin/ps -o pid=,rss=,vsz=,command= -p "$pid" | /usr/bin/awk '
    {
      rss_mb = $2 / 1024
      vsz_mb = $3 / 1024
      printf "pid=%s rss=%.1fMB vsz=%.1fMB command=", $1, rss_mb, vsz_mb
      for (i = 4; i <= NF; i++) {
        printf "%s%s", $i, (i == NF ? ORS : OFS)
      }
    }'
  /usr/bin/vmmap -summary "$pid" 2>/dev/null | /usr/bin/awk '
    /Physical footprint:/ {
      print "physical_footprint=" $3
    }
    /Physical footprint \(peak\):/ {
      print "physical_footprint_peak=" $4
    }'
}

stop_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    ls_ui_element="$(/usr/bin/plutil -extract LSUIElement raw "$APP_BUNDLE/Contents/Info.plist")"
    case "$ls_ui_element" in
      true|YES|1) ;;
      *)
        echo "error: expected LSUIElement=true, got '$ls_ui_element'" >&2
        exit 1
        ;;
    esac
    open_app
    wait_for_pid >/dev/null
    printf 'LSUIElement=%s\n' "$ls_ui_element"
    ;;
  --memory|memory)
    open_app
    pid="$(wait_for_pid)"
    /bin/sleep 2
    sample_memory "$pid"
    ;;
esac
