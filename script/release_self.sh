#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MusicFloat"
PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
CONFIGURATION="Release"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$PWD/.codex/DerivedData}"
BUILT_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
EXPORT_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_TARGET="/Applications/$APP_NAME.app"

usage() {
  cat >&2 <<'EOF'
usage:
  script/release_self.sh [--install] [--open] [--memory] [--demo] [--live] [--drive-music] [--memory-duration seconds] [--status]

Builds a local Release app bundle into dist/MusicFloat.app with release-strip
postprocessing enabled. --install copies that bundle to /Applications.
--memory launches and samples the stripped bundle. Use --demo or --live to pass
that launch mode to the app; --memory-duration controls sample length.
--drive-music with --live seeks and attempts a next-track action during the
sample, which changes active Music.app playback.
--status prints the project, installed app, and running process identity.

Set ENABLE_APPLE_TRANSLATION_BUILD=1 to build an explicit Release bundle with
Apple Translation/NaturalLanguage linked. Default Release keeps that framework
cost out of the baseline.
EOF
}

install_app=false
open_app=false
sample_memory=false
show_status=false
memory_duration=2
launch_args=()
drive_music=false
driver_pid=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      install_app=true
      ;;
    --open)
      open_app=true
      ;;
    --memory)
      open_app=true
      sample_memory=true
      ;;
    --demo)
      launch_args+=(--demo)
      ;;
    --live)
      launch_args+=(--live)
      ;;
    --drive-music)
      drive_music=true
      ;;
    --memory-duration)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 ]]; then
        echo "Error: --memory-duration requires a positive integer number of seconds" >&2
        exit 2
      fi
      memory_duration="$2"
      shift
      ;;
    --status)
      show_status=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ "$drive_music" == true ]]; then
  live_requested=false
  for arg in "${launch_args[@]}"; do
    if [[ "$arg" == "--live" ]]; then
      live_requested=true
    fi
  done
  if [[ "$live_requested" == false ]]; then
    echo "Error: --drive-music requires --live" >&2
    exit 2
  fi
fi

status() {
  echo "[project]"
  script/version.sh show
  echo "[installed]"
  script/version.sh installed
  echo "[running]"
  script/version.sh running
}

stop_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/killall "$APP_NAME" >/dev/null 2>&1 || true
  while IFS= read -r pid; do
    command="$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$command" in
      *"/Contents/MacOS/$APP_NAME"*)
        /bin/kill "$pid" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(/usr/bin/pgrep -f "/Contents/MacOS/$APP_NAME" || true)
  /bin/sleep 0.2
  while IFS= read -r pid; do
    command="$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$command" in
      *"/Contents/MacOS/$APP_NAME"*)
        /bin/kill -9 "$pid" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(/usr/bin/pgrep -f "/Contents/MacOS/$APP_NAME" || true)
  /bin/sleep 0.2
}

wait_for_pid() {
  local bundle="$1"
  local attempt
  local pid
  local command

  for attempt in {1..30}; do
    while IFS= read -r pid; do
      command="$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)"
      if [[ "$command" == "$bundle/Contents/MacOS/$APP_NAME"* ]]; then
        echo "$pid"
        return 0
      fi
    done < <(/usr/bin/pgrep -x "$APP_NAME" || true)
    /bin/sleep 0.2
  done

  return 1
}

sample_process_memory() {
  local pid="$1"
  local duration="${2:-2}"
  local sample_file
  local sample_count=0
  sample_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/musicfloat-release-memory.XXXXXX")"

  while [[ "$sample_count" -lt "$duration" ]]; do
    if ! /bin/kill -0 "$pid" 2>/dev/null; then
      echo "memory_sample_stopped pid=$pid reason=process_exited sample=$((sample_count + 1))"
      break
    fi

    local ps_output
    ps_output="$(/bin/ps -o pid=,rss=,vsz=,command= -p "$pid" 2>/dev/null || true)"
    if [[ -z "$ps_output" ]]; then
      echo "memory_sample_stopped pid=$pid reason=process_unavailable sample=$((sample_count + 1))"
      break
    fi

    printf '%s\n' "$ps_output" | /usr/bin/awk \
      -v sample="$((sample_count + 1))" \
      -v sample_file="$sample_file" '
      {
        rss_mb = $2 / 1024
        vsz_mb = $3 / 1024
        printf "sample=%s pid=%s rss=%.1fMB vsz=%.1fMB command=", sample, $1, rss_mb, vsz_mb
        for (i = 4; i <= NF; i++) {
          printf "%s%s", $i, (i == NF ? ORS : OFS)
        }
        printf "%.3f\n", rss_mb >> sample_file
      }'
    sample_count=$((sample_count + 1))
    if [[ "$sample_count" -lt "$duration" ]]; then
      /bin/sleep 1
    fi
  done

  /usr/bin/awk '
    NR == 1 { min = max = $1 }
    { sum += $1; if ($1 < min) min = $1; if ($1 > max) max = $1 }
    END {
      if (NR > 0) {
        printf "rss_summary samples=%d avg=%.1fMB min=%.1fMB max=%.1fMB\n", NR, sum / NR, min, max
      }
    }' "$sample_file"
  /bin/rm -f "$sample_file"

  local vmmap_output
  vmmap_output="$(/usr/bin/vmmap -summary "$pid" 2>/dev/null || true)"
  if [[ -z "$vmmap_output" ]]; then
    echo "vmmap_summary_unavailable pid=$pid"
    return 0
  fi

  printf '%s\n' "$vmmap_output" | /usr/bin/awk '
    /Physical footprint:/ {
      print "physical_footprint=" $3
    }
    /Physical footprint \(peak\):/ {
      print "physical_footprint_peak=" $4
    }'
}

stop_music_driver() {
  if [[ -n "$driver_pid" ]]; then
    kill "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
    driver_pid=""
  fi
}

drive_music_during_sample() {
  (
    child_pid=""
    trap 'if [[ -n "$child_pid" ]]; then kill "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi' EXIT
    trap 'exit 0' TERM INT
    pause_driver() {
      /bin/sleep "$1" &
      child_pid=$!
      wait "$child_pid"
      child_pid=""
    }
    pause_driver 5
    /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application id "com.apple.Music"
  if it is running then
    try
      set player position to (player position + 15)
    end try
  end if
end tell
APPLESCRIPT

    pause_driver 8
    /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application id "com.apple.Music"
  if it is running then
    try
      next track
    end try
  end if
end tell
APPLESCRIPT
  ) >/dev/null 2>&1 &
  driver_pid=$!
  trap stop_music_driver EXIT
}

if [[ "$show_status" == true && "$install_app" == false && "$open_app" == false && "$sample_memory" == false ]]; then
  status
  exit 0
fi

echo "[before]"
status

stop_app

extra_build_settings=()
if [[ "${ENABLE_APPLE_TRANSLATION_BUILD:-0}" == "1" || "${ENABLE_APPLE_TRANSLATION_BUILD:-}" == "true" ]]; then
  extra_build_settings+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ENABLE_APPLE_TRANSLATION')
fi

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  DEPLOYMENT_POSTPROCESSING=YES \
  COPY_PHASE_STRIP=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  CLANG_COVERAGE_MAPPING=NO \
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
  GCC_GENERATE_TEST_COVERAGE_FILES=NO \
  "${extra_build_settings[@]}" \
  build

/bin/mkdir -p "$DIST_DIR"
/bin/rm -rf "$EXPORT_BUNDLE"
/usr/bin/ditto "$BUILT_BUNDLE" "$EXPORT_BUNDLE"

echo "exported=$EXPORT_BUNDLE"
echo -n "LSUIElement="
/usr/bin/plutil -extract LSUIElement raw "$EXPORT_BUNDLE/Contents/Info.plist"

echo "signature:"
/usr/bin/codesign -dvv "$EXPORT_BUNDLE" 2>&1 | /usr/bin/sed -n '1,12p'

echo "entitlements:"
/usr/bin/codesign -d --entitlements :- "$EXPORT_BUNDLE" 2>/dev/null | /usr/bin/plutil -p - 2>/dev/null || true

if [[ "$install_app" == true ]]; then
  stop_app
  /bin/rm -rf "$INSTALL_TARGET"
  /usr/bin/ditto "$EXPORT_BUNDLE" "$INSTALL_TARGET"
  echo "installed=$INSTALL_TARGET"
fi

if [[ "$open_app" == true ]]; then
  launch_bundle="$EXPORT_BUNDLE"
  if [[ "$install_app" == true ]]; then
    launch_bundle="$INSTALL_TARGET"
  fi

  if [[ "${#launch_args[@]}" -gt 0 ]]; then
    /usr/bin/open -n "$launch_bundle" --args "${launch_args[@]}"
  else
    /usr/bin/open -n "$launch_bundle"
  fi
  pid="$(wait_for_pid "$launch_bundle")"
  echo "pid=$pid"
  if [[ "${#launch_args[@]}" -gt 0 ]]; then
    printf "launch_args="
    printf "%q " "${launch_args[@]}"
    printf "\n"
  fi

  if [[ "$sample_memory" == true ]]; then
    /bin/sleep 2
    driver_pid=""
    if [[ "$drive_music" == true ]]; then
      drive_music_during_sample
      echo "music_driver_pid=$driver_pid"
    fi
    sample_process_memory "$pid" "$memory_duration"
    stop_music_driver
  fi
fi

echo "[after]"
status
