#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MusicFloat"
PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$PWD/.codex/DerivedData}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
TRACE_DIR="${TRACE_DIR:-$PWD/.codex/traces}"
LIVE_LOG_DIR="${LIVE_LOG_DIR:-$TRACE_DIR/live-logs}"
USAGE_LOG_DIR="${USAGE_LOG_DIR:-$TRACE_DIR/usage}"
USAGE_SAMPLE_INTERVAL="${USAGE_SAMPLE_INTERVAL:-1}"
LIVE_TRACE_WARN_MB="${LIVE_TRACE_WARN_MB:-1024}"
RUN_LEDGER="${RUN_LEDGER:-$PWD/reports/performance-runs.jsonl}"

# ── phased profiling templates ──────────────────────────────────────────────
# Each entry: "template|duration|description"
# Ordered to capture: startup → active overlay → idle → memory → cleanup
PHASED_TEMPLATES=(
  "App Launch|12s|Startup cost (dyld, AppKit init, first frame)"
  "Time Profiler|25s|CPU under load (sync engine, SwiftUI, provider calls)"
  "Allocations|30s|Memory under load (lyrics doc, translation cache, overlay)"
  "Leaks|30s|Memory leaks (extended overlay + translation cycle)"
  "SwiftUI|20s|View invalidation and body recomputation cost"
  "System Trace|15s|Wake/idle patterns, context switches, timer fires"
  "Swift Concurrency|20s|Task lifetimes, actor hops, runaway async work"
  "Power Profiler|15s|Energy impact of long-running menu bar presence"
  "Animation Hitches|20s|Overlay rendering smoothness during lyric transitions"
)

usage() {
  cat >&2 <<'EOF'
usage:
  script/profile.sh list
  script/profile.sh record [template] [duration] [--demo] [--live] [--drive-music] [--apple-translation] [--hide-after duration] [--scenario name]
  script/profile.sh phased [--demo] [--live] [--drive-music] [--apple-translation] [--hide-after duration] [--scenario name]
  script/profile.sh sample [duration] [--demo] [--live] [--drive-music] [--apple-translation] [--hide-after duration] [--scenario name]
  script/profile.sh report
  script/profile.sh compare-runs [--strict] <baseline-run-id> <candidate-run-id>
  script/profile.sh preflight-live [--drive-music]
  script/profile.sh doctor
  script/profile.sh disk
  script/profile.sh open [template]
  script/profile.sh compare <trace-a> <trace-b>
  script/profile.sh clean

Use --apple-translation, or set ENABLE_APPLE_TRANSLATION_BUILD=1, to profile an
explicit Release build with Apple Translation/NaturalLanguage linked. Default
Release profiling keeps that framework cost out of the baseline.

examples:
  script/profile.sh list
  script/profile.sh record "Time Profiler" 20s
  script/profile.sh record "Allocations" 30s --live --scenario overlay-karaoke
  script/profile.sh sample 30s --demo --apple-translation --scenario translation-enabled-overlay
  script/profile.sh sample 60s --demo --hide-after 10s --scenario overlay-show-hide-idle
  script/profile.sh phased --live --scenario overlay-karaoke
  script/profile.sh sample 30s --live --scenario overlay-karaoke
  script/profile.sh report
  script/profile.sh compare-runs 20260524-aaa 20260524-bbb
  script/profile.sh compare-runs --strict 20260524-aaa 20260524-bbb
  script/profile.sh preflight-live
  script/profile.sh doctor
  script/profile.sh disk
  script/profile.sh open "SwiftUI"
  script/profile.sh compare traces/0.0.1-Time-Profiler.trace traces/0.0.2-Time-Profiler.trace
  script/profile.sh clean

--demo: Launches the app with the --demo flag, which auto-shows the
        floating lyrics overlay with mock playback, mock lyrics, and
        mock translation — exercising the real hot paths.
--live: Requires Music.app to already be playing a real track, launches the
        app with --live, captures MusicFloat logs, and verifies live playback,
        overlay appearance, and non-mock lyrics before accepting the trace.
--drive-music: With --live, launches Music.app if needed, starts playback,
               then performs a seek and next-track action during the trace so
               live lyrics, playerInfo events, and watchdog correction are
               exercised. This is intentionally opt-in because it changes the
               user's active playback.
--scenario: Names the workflow being measured so future comparisons do not mix
            unrelated evidence.
--apple-translation: Builds with ENABLE_APPLE_TRANSLATION so Translation and
                     NaturalLanguage cost is measured in a dedicated lane.
--hide-after: Hides the overlay after the given duration. Use with --demo or
              --live to measure post-hide idle behavior in one run.
EOF
}

apple_translation_build_enabled() {
  case "${ENABLE_APPLE_TRANSLATION_BUILD:-0}" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

apply_build_profile_flags() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --apple-translation|--translation-enabled)
        ENABLE_APPLE_TRANSLATION_BUILD=1
        ;;
    esac
    shift
  done
}

build_app() {
  local build_command=(
    /usr/bin/xcodebuild
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$DERIVED_DATA_DIR"
  )
  if apple_translation_build_enabled; then
    build_command+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ENABLE_APPLE_TRANSLATION')
  fi
  build_command+=(build)

  "${build_command[@]}"
}

stop_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/killall "$APP_NAME" >/dev/null 2>&1 || true
}

artifact_size() {
  local path="$1"
  if [[ -e "$path" ]]; then
    /usr/bin/du -sh "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  else
    printf "0B"
  fi
}

print_artifact_usage() {
  echo "  Artifact usage:"
  printf "    traces:      %s (%s)\n" "$(artifact_size "$TRACE_DIR")" "$TRACE_DIR"
  printf "    DerivedData: %s (%s)\n" "$(artifact_size "$DERIVED_DATA_DIR")" "$DERIVED_DATA_DIR"
}

run_doctor_step() {
  local label="$1"
  shift
  echo "== $label =="
  set +e
  "$@"
  local status="$?"
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "status=$status"
  fi
}

mode_name() {
  local use_demo="$1"
  local use_live="$2"
  if [[ "$use_live" == "true" ]]; then
    printf "live"
  elif [[ "$use_demo" == "true" ]]; then
    printf "demo"
  else
    printf "default"
  fi
}

parse_scenario() {
  local scenario="unspecified"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --scenario)
        if [[ "$#" -lt 2 ]]; then
          echo "Error: --scenario requires a value" >&2
          exit 2
        fi
        scenario="$2"
        shift 2
        ;;
      --scenario=*)
        scenario="${1#--scenario=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  printf "%s" "$scenario"
}

parse_hide_after() {
  local hide_after=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --hide-after)
        if [[ "$#" -lt 2 ]]; then
          echo "Error: --hide-after requires a value" >&2
          exit 2
        fi
        hide_after="$2"
        shift 2
        ;;
      --hide-after=*)
        hide_after="${1#--hide-after=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -n "$hide_after" ]]; then
    duration_to_sleep_seconds "$hide_after"
  fi
}

parse_sample_duration() {
  local duration="20s"
  local found="false"
  shift || true

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --demo|--live|--drive-music|--apple-translation|--translation-enabled)
        shift
        ;;
      --hide-after)
        if [[ "$#" -lt 2 ]]; then
          echo "Error: --hide-after requires a value" >&2
          exit 2
        fi
        shift 2
        ;;
      --hide-after=*)
        shift
        ;;
      --scenario)
        if [[ "$#" -lt 2 ]]; then
          echo "Error: --scenario requires a value" >&2
          exit 2
        fi
        shift 2
        ;;
      --scenario=*)
        shift
        ;;
      --*)
        echo "Error: unknown sample option: $1" >&2
        exit 2
        ;;
      *)
        if [[ "$found" == "true" ]]; then
          echo "Error: sample accepts only one duration argument." >&2
          exit 2
        fi
        duration="$1"
        found="true"
        shift
        ;;
    esac
  done

  printf "%s" "$duration"
}

duration_to_sleep_seconds() {
  DURATION="$1" /usr/bin/python3 <<'PY'
import os
import re
import sys

duration = os.environ["DURATION"]
match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)?", duration)
if not match:
    print(f"Error: invalid sample duration: {duration}", file=sys.stderr)
    raise SystemExit(2)

value = float(match.group(1))
unit = match.group(2) or "s"
multiplier = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0}[unit]
seconds = value * multiplier
if seconds <= 0:
    print(f"Error: sample duration must be greater than zero: {duration}", file=sys.stderr)
    raise SystemExit(2)

print(f"{seconds:.3f}".rstrip("0").rstrip("."))
PY
}

git_value() {
  git "$@" 2>/dev/null || true
}

app_marketing_version() {
  script/version.sh value MARKETING_VERSION
}

app_build_version() {
  script/version.sh value CURRENT_PROJECT_VERSION
}

current_pr_number() {
  if command -v gh >/dev/null 2>&1; then
    gh pr view --json number --jq .number 2>/dev/null || true
  fi
}

ensure_disk_headroom() {
  local min_free_gb="$1"
  local min_free_kb=$((min_free_gb * 1024 * 1024))
  local available_kb
  available_kb="$(/bin/df -Pk "$PWD" | /usr/bin/awk 'NR == 2 { print $4 }')"

  if [[ -z "$available_kb" || "$available_kb" -lt "$min_free_kb" ]]; then
    echo "Error: profiling needs at least ${min_free_gb}GB free in this workspace." >&2
    print_artifact_usage >&2
    echo "Run: ./script/profile.sh clean" >&2
    exit 1
  fi
}

music_playback_driver_script() {
  /usr/bin/osascript <<'APPLESCRIPT'
tell application id "com.apple.Music"
  launch
  delay 0.5
  if player state is not playing then play
  delay 0.5
  set playbackState to player state as string
  set trackName to ""
  set artistName to ""
  set playerPosition to player position
  try
    set trackName to name of current track
    set artistName to artist of current track
  end try
end tell

return playbackState & tab & trackName & tab & artistName & tab & playerPosition
APPLESCRIPT
}

preflight_live() {
  local drive_music="${1:-false}"
  local info
  set +e
  if [[ "$drive_music" == "true" ]]; then
    info="$(music_playback_driver_script 2>/dev/null)"
  else
    info="$(/usr/bin/osascript <<'APPLESCRIPT' 2>/dev/null
tell application "System Events"
  set musicRunning to exists process "Music"
end tell
if musicRunning is false then
  return "not_running"
end if

tell application "Music"
  set playbackState to player state as string
  set trackName to ""
  set artistName to ""
  set playerPosition to player position
  try
    set trackName to name of current track
    set artistName to artist of current track
  end try
end tell

return playbackState & tab & trackName & tab & artistName & tab & playerPosition
APPLESCRIPT
)"
  fi
  local status="$?"
  set -e

  if [[ "$status" -ne 0 || -z "$info" ]]; then
    echo "Error: could not inspect Music.app playback for --live profiling." >&2
    echo "Start Music.app, play a lyric-capable Apple Music track, then retry; or use --drive-music to let the script start playback." >&2
    exit 1
  fi

  if [[ "$info" == "not_running" ]]; then
    echo "Error: --live profiling requires Music.app to be running and playing." >&2
    exit 1
  fi

  local playback_state track_name artist_name player_position
  playback_state="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $1 }')"
  track_name="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $2 }')"
  artist_name="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $3 }')"
  player_position="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $4 }')"
  if [[ "$playback_state" != "playing" || -z "$track_name" ]]; then
    echo "Error: --live profiling requires an actively playing Music.app track." >&2
    echo "Current Music state: ${playback_state:-unknown} ${track_name:+- $track_name}" >&2
    exit 1
  fi

  echo "  Live preflight: Music.app is playing \"$track_name\" by ${artist_name:-unknown artist} at ${player_position:-unknown}s."
  echo "  The profiled app will launch with --live, start Live Apple Music mode, and show the overlay."
  if [[ "$drive_music" == "true" ]]; then
    echo "  Music driver: enabled; the trace will seek and attempt a next-track action."
  else
    echo "  Keep Music playing and visually confirm lyrics appear during the trace."
  fi
}

doctor_music_preflight() {
  local pgrep_log
  pgrep_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/musicfloat-doctor-pgrep.XXXXXX")"
  set +e
  /usr/bin/pgrep -x Music >/dev/null 2>"$pgrep_log"
  local pgrep_status="$?"
  set -e
  if [[ "$pgrep_status" -eq 1 ]]; then
    echo "music_running=false"
    echo "note=read-only; does not start playback or print track metadata"
    return 0
  fi
  if [[ "$pgrep_status" -ne 0 ]]; then
    echo "live_preflight=unavailable"
    echo "reason=process_list_unavailable"
    /usr/bin/head -4 "$pgrep_log" | /usr/bin/sed 's/^/detail=/'
    return 0
  fi

  local info
  set +e
  info="$(/usr/bin/osascript <<'APPLESCRIPT' 2>&1
tell application "Music"
  set playbackState to player state as string
  set hasTrack to false
  try
    set trackName to name of current track
    if trackName is not "" then set hasTrack to true
  end try
end tell

return "music_running=true" & tab & "playback_state=" & playbackState & tab & "has_track=" & hasTrack
APPLESCRIPT
)"
  local status="$?"
  set -e

  if [[ "$status" -ne 0 ]]; then
    echo "live_preflight=unavailable"
    echo "reason=music_apple_event_unavailable"
    echo "$info" | /usr/bin/sed 's/^/detail=/'
    return 0
  fi

  printf "%s\n" "$info" | /usr/bin/tr '\t' '\n'
  echo "note=read-only; does not start playback or print track metadata"
}

doctor_snapshot_readiness() {
  if [[ -x "script/profile_snapshot.sh" ]]; then
    echo "profile_snapshot=available"
  elif [[ -f "script/profile_snapshot.sh" ]]; then
    echo "profile_snapshot=present_not_executable"
  else
    echo "profile_snapshot=missing"
    return 0
  fi

  local tracked_dirty untracked_count
  tracked_dirty="$([[ -n "$(git status --porcelain --untracked-files=no)" ]] && printf true || printf false)"
  untracked_count="$(git status --porcelain --untracked-files=all | /usr/bin/awk '/^\?\?/ { count += 1 } END { print count + 0 }')"
  echo "tracked_dirty=$tracked_dirty"
  echo "untracked_count=$untracked_count"
  if [[ "$tracked_dirty" == "true" || "$untracked_count" != "0" ]]; then
    echo "clean_snapshot_needed=true"
    echo "snapshot_command=script/profile_snapshot.sh -- ./script/profile.sh sample 30s --demo --scenario overlay-karaoke"
  else
    echo "clean_snapshot_needed=false"
  fi
}

doctor_xcodebuildmcp() {
  if ! command -v xcodebuildmcp >/dev/null 2>&1; then
    echo "xcodebuildmcp=missing"
    return 0
  fi

  printf "xcodebuildmcp=%s\n" "$(command -v xcodebuildmcp)"
  printf "version="
  xcodebuildmcp --version || true
  echo "codex_tool_hint=XcodeBuildMCP may surface as Xcode or mcp__xcode__ tools after session reload"

  if [[ -f ".xcodebuildmcp/config.yaml" ]]; then
    echo "config=.xcodebuildmcp/config.yaml"
    /usr/bin/awk '
      /^enabledWorkflows:/ { in_workflows=1; next }
      in_workflows && /^[[:space:]]*-/ {
        item=$0
        sub(/^[[:space:]]*-[[:space:]]*/, "", item)
        printf "workflow=%s\n", item
        next
      }
      in_workflows && /^[^[:space:]]/ { in_workflows=0 }
      /^  projectPath:/ || /^  scheme:/ || /^  configuration:/ ||
      /^  platform:/ || /^  arch:/ || /^  derivedDataPath:/ || /^  bundleId:/ {
        line=$0
        sub(/^[[:space:]]*/, "", line)
        printf "default_%s\n", line
      }
    ' .xcodebuildmcp/config.yaml
  else
    echo "config=missing"
  fi

  local tools_json tools_status
  set +e
  tools_json="$(xcodebuildmcp tools --json --workflow macos 2>&1)"
  tools_status="$?"
  set -e
  if [[ "$tools_status" -ne 0 ]]; then
    echo "macos_tools=unavailable"
    echo "$tools_json" | /usr/bin/head -6 | /usr/bin/sed 's/^/detail=/'
    return 0
  fi

  TOOLS_JSON="$tools_json" /usr/bin/python3 <<'PY'
import json
import os

data = json.loads(os.environ["TOOLS_JSON"])
print(f"macos_tool_count={data.get('toolCount', 0)}")
for workflow in data.get("workflows", []):
    for tool in workflow.get("tools", []):
        command = tool.get("command")
        if command:
            print(f"macos_tool={command}")
PY
}

do_doctor() {
  echo "MusicFloat doctor is read-only. It does not clean, record Instruments, install, or drive Music.app."

  run_doctor_step "git" /bin/sh -c '
    /usr/bin/git status --short --branch
    /usr/bin/git rev-parse --short HEAD
  '

  echo "== profile snapshot =="
  doctor_snapshot_readiness

  run_doctor_step "xcode" /bin/sh -c '
    printf "developer_dir="
    /usr/bin/xcode-select -p
    /usr/bin/xcodebuild -version
  '

  run_doctor_step "mcpbridge" /bin/sh -c '
    if path="$(/usr/bin/xcrun --find mcpbridge 2>/dev/null)"; then
      printf "mcpbridge=%s\n" "$path"
    else
      echo "mcpbridge=missing"
    fi
  '

  echo "== xcodebuildmcp =="
  doctor_xcodebuildmcp

  echo "== xctrace =="
  local xctrace_log
  xctrace_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/musicfloat-doctor-xctrace.XXXXXX")"
  set +e
  /usr/bin/python3 - "$xctrace_log" <<'PY'
import subprocess
import sys

log_path = sys.argv[1]
with open(log_path, "wb") as log:
    proc = subprocess.run(
        ["/usr/bin/xcrun", "xctrace", "list", "templates"],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
if proc.returncode < 0:
    raise SystemExit(128 + abs(proc.returncode))
raise SystemExit(proc.returncode)
PY
  local xctrace_status="$?"
  set -e
  if [[ "$xctrace_status" -eq 0 ]]; then
    echo "xctrace_templates=available"
    /usr/bin/grep -E "^[[:space:]]+[A-Za-z]" "$xctrace_log" | /usr/bin/head -8 || true
  else
    echo "xctrace_templates=unavailable"
    echo "status=$xctrace_status"
    /usr/bin/head -8 "$xctrace_log" | /usr/bin/sed 's/^/detail=/'
  fi

  run_doctor_step "bundle identity" /bin/sh -c '
    script/version.sh show
    script/version.sh installed
    script/version.sh running
  '

  echo "== live preflight =="
  doctor_music_preflight

  echo "== artifacts =="
  print_artifact_usage

  echo "== codex actions =="
  if [[ -f ".codex/environments/environment.toml" ]]; then
    /usr/bin/awk '
      /^name = / {
        name=$0
        sub(/^name = "/, "", name)
        sub(/"$/, "", name)
      }
      /^command = / {
        sub(/^command = "/, "")
        sub(/"$/, "")
        printf "action=%s command=%s\n", name, $0
      }
    ' .codex/environments/environment.toml
  else
    echo "actions=missing"
  fi
}

parse_profile_flags() {
  local use_demo="$1"
  local use_live="$2"

  if [[ "$use_demo" == "true" && "$use_live" == "true" ]]; then
    echo "Error: choose either --demo or --live, not both." >&2
    exit 2
  fi
}

require_drive_music_live() {
  local drive_music="$1"
  local use_live="$2"
  if [[ "$drive_music" == "true" && "$use_live" != "true" ]]; then
    echo "Error: --drive-music can only be used with --live." >&2
    exit 2
  fi
}

start_live_log_capture() {
  local log_path="$1"
  /bin/mkdir -p "$(dirname "$log_path")"
  : > "$log_path"
  /usr/bin/log stream \
    --style compact \
    --level debug \
    --predicate 'subsystem == "cv.MusicFloat" OR process == "MusicFloat"' \
    > "$log_path" 2>&1 &
  echo "$!"
}

finalize_sample_log_capture() {
  local log_path="$1"
  local stream_path="$2"
  local stderr_path="$3"
  local stream_pid="$4"
  local source="app_stderr"
  local network_coverage="limited"

  if [[ -n "$stream_pid" ]] && /bin/kill -0 "$stream_pid" 2>/dev/null \
    && ! /usr/bin/grep -E '^log:|Must be admin' "$stream_path" >/dev/null; then
    source="unified_stream"
    network_coverage="unified_stream"
  fi
  stop_live_log_capture "$stream_pid"

  # Select one source instead of concatenating duplicate application events.
  # Preserve both raw artifacts, including a failed stream's diagnostics.
  if [[ "$source" == "unified_stream" ]]; then
    /bin/cat "$stream_path" > "$log_path"
  else
    /bin/cat "$stderr_path" > "$log_path"
    echo "  Unified log stream unavailable; using application stderr. Process-wide network log coverage is limited." >&2
  fi
  printf '\nMusicFloat log capture source=%s process_network_logs=%s\n' "$source" "$network_coverage" >> "$log_path"
}

start_usage_capture() {
  local usage_path="$1"
  /bin/mkdir -p "$(dirname "$usage_path")"
  printf "timestamp,pid,rss_kb,cpu_pct\n" > "$usage_path"
  (
    set +e
    while true; do
      # Only sample the process launched from the profiled bundle; another
      # MusicFloat (installed or Xcode build) may already be running.
      pid=""
      for candidate in $(/usr/bin/pgrep -x "$APP_NAME" || true); do
        if [[ "$(/bin/ps -o command= -p "$candidate" 2>/dev/null)" == "$APP_EXEC"* ]]; then
          pid="$candidate"
          break
        fi
      done
      if [[ -n "$pid" ]]; then
        /bin/ps -o pid=,rss=,%cpu= -p "$pid" | /usr/bin/awk -v ts="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" '
          NF >= 3 { printf "%s,%s,%s,%s\n", ts, $1, $2, $3 }
        ' >> "$usage_path" || true
      fi
      /bin/sleep "$USAGE_SAMPLE_INTERVAL"
    done
  ) >/dev/null 2>&1 &
  echo "$!"
}

stop_usage_capture() {
  local usage_pid="${1:-}"
  if [[ -n "$usage_pid" ]]; then
    /bin/kill "$usage_pid" >/dev/null 2>&1 || true
    wait "$usage_pid" >/dev/null 2>&1 || true
  fi
}

start_music_driver() {
  local driver_log_path="$1"
  /bin/mkdir -p "$(dirname "$driver_log_path")"
  : > "$driver_log_path"
  (
    set +e
    echo "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) driver start"
    /bin/sleep 5
    /usr/bin/osascript <<'APPLESCRIPT'
tell application id "com.apple.Music"
  if player state is playing then
    set currentPosition to player position
    set player position to currentPosition + 15
  end if
end tell
APPLESCRIPT
    echo "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) seek +15s rc=$?"
    /bin/sleep 6
    /usr/bin/osascript <<'APPLESCRIPT'
tell application id "com.apple.Music"
  if player state is playing then next track
end tell
APPLESCRIPT
    echo "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) next track rc=$?"
    /bin/sleep 6
    /usr/bin/osascript <<'APPLESCRIPT'
tell application id "com.apple.Music"
  if player state is playing then
    set currentPosition to player position
    if currentPosition > 20 then
      set player position to currentPosition - 10
    else
      set player position to currentPosition + 10
    end if
  end if
end tell
APPLESCRIPT
    echo "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) seek correction rc=$?"
  ) > "$driver_log_path" 2>&1 &
  echo "$!"
}

stop_music_driver() {
  local driver_pid="${1:-}"
  if [[ -n "$driver_pid" ]]; then
    /bin/kill "$driver_pid" >/dev/null 2>&1 || true
    wait "$driver_pid" >/dev/null 2>&1 || true
  fi
}

summarize_usage_capture() {
  local usage_path="$1"
  if [[ ! -s "$usage_path" ]]; then
    echo "  Usage samples: none captured ($usage_path)"
    return 1
  fi

  /usr/bin/awk -F, '
    NR > 1 && NF >= 4 && $3 > 1024 {
      count += 1
      rss += $3
      cpu += $4
      if ($3 > max_rss) { max_rss = $3 }
      if ($4 > max_cpu) { max_cpu = $4 }
    }
    END {
      if (count == 0) {
        printf "  Usage samples: none credible captured\n"
        exit 1
      }
      printf "  Usage samples: %d avgRSS=%.1fMB maxRSS=%.1fMB avgCPU=%.2f%% maxCPU=%.2f%%\n", count, rss / count / 1024, max_rss / 1024, cpu / count, max_cpu
    }
  ' "$usage_path"
  echo "  Usage CSV: $usage_path"
}

append_run_ledger() {
  local run_id="$1"
  local kind="$2"
  local mode="$3"
  local scenario="$4"
  local duration="$5"
  local template="$6"
  local status="$7"
  local valid="$8"
  local trace_path="$9"
  local usage_path="${10}"
  local live_log_path="${11}"
  local failure_reason="${12:-}"
  local hide_after_seconds="${13:-}"

  /bin/mkdir -p "$(dirname "$RUN_LEDGER")"
  RUN_ID="$run_id" \
  RUN_KIND="$kind" \
  RUN_MODE="$mode" \
  RUN_SCENARIO="$scenario" \
  RUN_DURATION="$duration" \
  RUN_TEMPLATE="$template" \
  RUN_STATUS="$status" \
  RUN_VALID="$valid" \
  RUN_CREATED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
  RUN_TRACE_PATH="$trace_path" \
  RUN_USAGE_PATH="$usage_path" \
  RUN_LIVE_LOG_PATH="$live_log_path" \
  RUN_FAILURE_REASON="$failure_reason" \
  RUN_HIDE_AFTER_SECONDS="$hide_after_seconds" \
  RUN_LEDGER="$RUN_LEDGER" \
  RUN_WORKSPACE="$PWD" \
  RUN_BRANCH="$(git_value branch --show-current)" \
  RUN_COMMIT="$(git_value rev-parse HEAD)" \
  RUN_EXACT_TAG="$(git_value describe --tags --exact-match HEAD)" \
  RUN_NEAREST_TAG="$(git_value describe --tags --abbrev=8 --always HEAD)" \
  RUN_PR_NUMBER="$(current_pr_number)" \
  RUN_MARKETING_VERSION="$(app_marketing_version)" \
  RUN_BUILD_VERSION="$(app_build_version)" \
  RUN_APPLE_TRANSLATION_BUILD="$(apple_translation_build_enabled && printf true || printf false)" \
  RUN_TRACKED_DIRTY="$([[ -n "$(git status --porcelain --untracked-files=no)" ]] && printf true || printf false)" \
  RUN_UNTRACKED_COUNT="$(git status --porcelain --untracked-files=all | /usr/bin/awk '/^\\?\\?/ { count += 1 } END { print count + 0 }')" \
  /usr/bin/python3 <<'PY'
import csv
import json
import os
import re
from pathlib import Path

def env(name, default=""):
    return os.environ.get(name, default)

workspace = Path(env("RUN_WORKSPACE")).resolve()
usage_path = env("RUN_USAGE_PATH")
trace_path = env("RUN_TRACE_PATH")
samples = []
if usage_path and Path(usage_path).is_file():
    with open(usage_path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                rss = float(row.get("rss_kb") or 0)
                cpu = float(row.get("cpu_pct") or 0)
            except ValueError:
                continue
            if rss > 1024:
                samples.append((rss, cpu))

usage = {
    "samples": len(samples),
    "avg_rss_mb": None,
    "max_rss_mb": None,
    "avg_cpu_pct": None,
    "max_cpu_pct": None,
}
if samples:
    usage["avg_rss_mb"] = round(sum(r for r, _ in samples) / len(samples) / 1024, 2)
    usage["max_rss_mb"] = round(max(r for r, _ in samples) / 1024, 2)
    usage["avg_cpu_pct"] = round(sum(c for _, c in samples) / len(samples), 2)
    usage["max_cpu_pct"] = round(max(c for _, c in samples), 2)

trace_size_mb = None
if trace_path and Path(trace_path).exists():
    if Path(trace_path).is_dir():
        trace_size = sum(p.stat().st_size for p in Path(trace_path).rglob("*") if p.is_file())
    else:
        trace_size = Path(trace_path).stat().st_size
    trace_size_mb = round(trace_size / 1024 / 1024, 2)

def artifact_path(path):
    if not path:
        return None
    p = Path(path)
    if not p.is_absolute():
        return path
    try:
        return str(p.resolve().relative_to(workspace))
    except ValueError:
        return str(p)

def live_verification_summary(path):
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    text = p.read_text(errors="replace")
    capture = re.search(r"MusicFloat log capture source=(\w+) process_network_logs=(\w+)", text)
    summary = {
        "log_capture_source": capture.group(1) if capture else "legacy_unified_stream",
        "process_network_log_coverage": capture.group(2) if capture else "unknown",
        "live_launch": bool(re.search(r"Live mode requested", text)),
        "bridge_started": bool(re.search(r"Live Apple Music bridge started", text)),
        "playing_prime": bool(re.search(r"Live prime: status=playing hasTrack=true", text)),
        "overlay_visible": bool(re.search(r"(Toggle overlay requested visible=true|Showing lyrics overlay for Live Apple Music|Show floating panel)", text)),
        "overlay_appeared": bool(re.search(r"Lyrics overlay view appeared", text)),
        "provider_ready": bool(re.search(r"Provider pipeline ready", text)),
        "driven_event": bool(re.search(r"(SEEK_DETECTED|Live track changed)", text)),
    }
    seek_event_count = len(re.findall(r"SEEK_DETECTED", text))
    watchdog_seek_count = len(re.findall(r"SEEK_DETECTED source=watchdog", text))
    player_info_seek_count = len(re.findall(r"SEEK_DETECTED source=playerInfoEvent", text))
    track_change_count = len(re.findall(r"Live track changed", text))
    resync_count = len(re.findall(r"Live tick resync", text))
    track_tokens = sorted(set(re.findall(r"\btrack=(track:[0-9a-f]+)", text)))
    summary["seek_event_count"] = seek_event_count
    summary["watchdog_seek_count"] = watchdog_seek_count
    summary["player_info_seek_count"] = player_info_seek_count
    summary["track_change_count"] = track_change_count
    summary["resync_count"] = resync_count
    summary["track_token_count"] = len(track_tokens)
    summary["track_tokens_sample"] = track_tokens[:8]
    applied = re.search(
        r"Lyrics document applied source=(?P<source>[A-Za-z]+).*?line_count=(?P<lines>\d+).*?syllable_count=(?P<syllables>\d+)",
        text,
        re.S,
    )
    if applied:
        summary["lyrics_source"] = applied.group("source")
        summary["line_count"] = int(applied.group("lines"))
        summary["syllable_count"] = int(applied.group("syllables"))
    else:
        summary["lyrics_source"] = None
        summary["line_count"] = None
        summary["syllable_count"] = None
    lookup_ids = sorted(set(re.findall(r"lookup=([A-Za-z0-9_.:-]+)", text)))
    lines = text.splitlines()
    # Only count real network/request failures here. Unified logging also
    # prints AppleEvent timeout parameters such as "timeout 7200", which are
    # not failed provider requests and should not pollute the ledger.
    network_timeout_pattern = re.compile(
        r"(Operation timed out|NSURLErrorTimedOut|NSURLErrorDomain.*-1001|"
        r"nw_read_request_report.*timed out|request timed out|"
        r"timed out waiting for|network.*timed out)",
        re.I,
    )
    lookup_pattern = re.compile(r"lookup=([A-Za-z0-9_.:-]+)")
    timeout_indexes = [
        index for index, line in enumerate(lines)
        if network_timeout_pattern.search(line)
    ]
    timeout_lookup_ids = set()
    timeout_near_lookup_ids = set()
    uncorrelated_timeout_count = 0
    for index in timeout_indexes:
        line = lines[index]
        same_line_ids = [match.group(1) for match in lookup_pattern.finditer(line)]
        timeout_lookup_ids.update(same_line_ids)
        window_start = max(0, index - 6)
        window_end = min(len(lines), index + 7)
        nearby_ids = [
            match.group(1)
            for nearby in lines[window_start:window_end]
            for match in lookup_pattern.finditer(nearby)
        ]
        timeout_near_lookup_ids.update(nearby_ids)
        if not same_line_ids and not nearby_ids:
            uncorrelated_timeout_count += 1
    timeout_lookup_ids = sorted(timeout_lookup_ids)
    timeout_near_lookup_ids = sorted(timeout_near_lookup_ids)
    summary["lookup_count"] = len(lookup_ids)
    summary["lookup_ids_sample"] = lookup_ids[:8]
    summary["network_timeout_count"] = len(timeout_indexes)
    summary["timeout_with_lookup_count"] = len(timeout_lookup_ids)
    summary["timeout_lookup_ids_sample"] = timeout_lookup_ids[:8]
    summary["timeout_near_lookup_ids_sample"] = timeout_near_lookup_ids[:8]
    summary["uncorrelated_timeout_count"] = uncorrelated_timeout_count
    summary["translation_ready"] = bool(re.search(r"Translation ready", text))
    summary["translation_cache_hits"] = len(re.findall(r"Translation cache hit", text))
    return summary

app_stderr_path = env("RUN_LIVE_LOG_PATH") + ".app-stderr.log" if env("RUN_LIVE_LOG_PATH") else ""
app_stderr_capture_enabled = env("RUN_KIND") == "sample" and bool(app_stderr_path) and Path(app_stderr_path).is_file()

record = {
    "schema": 1,
    "run_id": env("RUN_ID"),
    "timestamp_utc": env("RUN_CREATED_AT"),
    "kind": env("RUN_KIND"),
    "mode": env("RUN_MODE"),
    "scenario": env("RUN_SCENARIO"),
    "duration": env("RUN_DURATION"),
    "template": env("RUN_TEMPLATE"),
    "status": env("RUN_STATUS"),
    "valid": env("RUN_VALID") == "true",
    "failure_reason": env("RUN_FAILURE_REASON") or None,
    "git": {
        "branch": env("RUN_BRANCH"),
        "commit": env("RUN_COMMIT"),
        "exact_tag": env("RUN_EXACT_TAG") or None,
        "nearest_tag": env("RUN_NEAREST_TAG") or None,
        "pr_number": int(env("RUN_PR_NUMBER")) if env("RUN_PR_NUMBER").isdigit() else None,
        "tracked_dirty": env("RUN_TRACKED_DIRTY") == "true",
        "untracked_count": int(env("RUN_UNTRACKED_COUNT") or 0),
    },
    "app": {
        "marketing_version": env("RUN_MARKETING_VERSION") or None,
        "build_version": env("RUN_BUILD_VERSION") or None,
        "apple_translation_build": env("RUN_APPLE_TRANSLATION_BUILD") == "true",
        "app_stderr_capture_enabled": app_stderr_capture_enabled,
        "hide_after_seconds": float(env("RUN_HIDE_AFTER_SECONDS")) if env("RUN_HIDE_AFTER_SECONDS") else None,
    },
    "usage": usage,
    "artifacts": {
        "trace_path": artifact_path(trace_path),
        "trace_size_mb": trace_size_mb,
        "usage_csv": artifact_path(usage_path),
        "live_log": artifact_path(env("RUN_LIVE_LOG_PATH")),
        "app_stderr_log": artifact_path(app_stderr_path) if app_stderr_capture_enabled else None,
        "unified_stream_log": artifact_path(env("RUN_LIVE_LOG_PATH") + ".unified-stream.log")
            if env("RUN_LIVE_LOG_PATH") and Path(env("RUN_LIVE_LOG_PATH") + ".unified-stream.log").is_file() else None,
    },
    "live_verification": live_verification_summary(env("RUN_LIVE_LOG_PATH")),
}

with open(env("RUN_LEDGER"), "a") as f:
    f.write(json.dumps(record, separators=(",", ":")) + "\n")
PY
  echo "  Run ledger: $RUN_LEDGER ($run_id)"
}

stop_live_log_capture() {
  local log_pid="${1:-}"
  if [[ -n "$log_pid" ]]; then
    /bin/kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" >/dev/null 2>&1 || true
  fi
}

require_live_log_pattern() {
  local log_path="$1"
  local pattern="$2"
  local description="$3"
  if ! /usr/bin/grep -E "$pattern" "$log_path" >/dev/null; then
    echo "Error: live trace verification failed: missing $description" >&2
    echo "       log: $log_path" >&2
    return 1
  fi
}

verify_live_recording() {
  local log_path="$1"
  local trace_path="$2"
  local drive_music="${3:-false}"

  verify_live_log "$log_path" "$drive_music"

  local trace_kb
  trace_kb="$(/usr/bin/du -sk "$trace_path" | /usr/bin/awk '{print $1}')"
  local trace_mb=$(( (trace_kb + 1023) / 1024 ))
  echo "  Trace disk usage: ${trace_mb}MB ($trace_path)"
  if (( trace_mb > LIVE_TRACE_WARN_MB )); then
    echo "  Warning: trace exceeds LIVE_TRACE_WARN_MB=${LIVE_TRACE_WARN_MB}MB"
  fi
}

verify_hide_after_log() {
  local log_path="$1"
  require_live_log_pattern "$log_path" "Hide overlay requested reason=autoHide" "auto-hide overlay request" || return 1
  require_live_log_pattern "$log_path" "Hide floating panel" "floating panel hide" || return 1
  echo "  Hide-after verification: overlay hide confirmed"
  echo "  Verification log: $log_path"
}

verify_live_log() {
  local log_path="$1"
  local drive_music="${2:-false}"
  local missing=0

  require_live_log_pattern "$log_path" "Live mode requested" "live launch" || missing=1
  require_live_log_pattern "$log_path" "Live Apple Music bridge started" "live bridge start" || missing=1
  require_live_log_pattern "$log_path" "Live prime: status=playing hasTrack=true" "playing Apple Music prime" || missing=1
  require_live_log_pattern "$log_path" "(Toggle overlay requested visible=true|Showing lyrics overlay for Live Apple Music|Show floating panel)" "overlay show" || missing=1
  require_live_log_pattern "$log_path" "Lyrics overlay view appeared" "overlay appearance" || missing=1
  require_live_log_pattern "$log_path" "Lyrics document applied source=(appleMusicWeb|lrclib|musicApp|musicAppUI|publicProvider)" "non-mock lyrics document" || missing=1
  require_live_log_pattern "$log_path" "Provider pipeline ready" "provider ready state" || missing=1
  if [[ "$drive_music" == "true" ]]; then
    require_live_log_pattern "$log_path" "(SEEK_DETECTED|Live track changed)" "driven seek or track-change event" || missing=1
  fi

  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi

  echo "  Live verification: playback, overlay, and non-mock lyrics confirmed"
  echo "  Live verification log: $log_path"
}

# ── record_one: records a single template ───────────────────────────────────
# Args: template duration use_demo use_live scenario drive_music hide_after_seconds
record_one() {
  local template="$1"
  local duration="$2"
  local use_demo="${3:-false}"
  local use_live="${4:-false}"
  local scenario="${5:-unspecified}"
  local drive_music="${6:-false}"
  local hide_after_seconds="${7:-}"
  local timestamp
  timestamp="$(/bin/date -u +%Y%m%d-%H%M%SZ)"
  local safe_name="${template// /-}"
  local run_id="${timestamp}-$(mode_name "$use_demo" "$use_live")-${safe_name}-$(git_value rev-parse --short HEAD)"
  local trace_path="$TRACE_DIR/${APP_NAME}-${safe_name}-$timestamp.trace"
  local live_log_path="$LIVE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.live.log"
  local ledger_live_log_path=""
  local usage_log_path="$USAGE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.usage.csv"
  local driver_log_path="$LIVE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.music-driver.log"
  local live_log_pid=""
  local usage_log_pid=""
  local driver_pid=""

  /bin/mkdir -p "$TRACE_DIR"
  stop_app

  local launch_args=("$APP_EXEC")
  if [[ "$use_demo" == "true" ]]; then
    launch_args+=("--demo")
  elif [[ "$use_live" == "true" ]]; then
    launch_args+=("--live")
  fi
  if [[ -n "$hide_after_seconds" ]]; then
    launch_args+=("--hide-after=$hide_after_seconds")
  fi

  if [[ "$use_live" == "true" || -n "$hide_after_seconds" ]]; then
    ledger_live_log_path="$live_log_path"
    live_log_pid="$(start_live_log_capture "$live_log_path")"
    /bin/sleep 0.5
  fi
  usage_log_pid="$(start_usage_capture "$usage_log_path")"
  if [[ "$use_live" == "true" && "$drive_music" == "true" ]]; then
    driver_pid="$(start_music_driver "$driver_log_path")"
  fi

  printf "  \033[1;36m▶\033[0m %-22s (%s) ... " "$template" "$duration"
  set +e
  local record_output
  record_output="$(/usr/bin/xcrun xctrace record \
    --template "$template" \
    --time-limit "$duration" \
    --output "$trace_path" \
    --launch -- "${launch_args[@]}" 2>&1)"
  local record_status="$?"
  set -e

  stop_app
  stop_music_driver "$driver_pid"
  stop_usage_capture "$usage_log_pid"
  stop_live_log_capture "$live_log_pid"

  if [[ "$record_status" -ne 0 ]]; then
    printf "\033[1;31mFAILED\033[0m\n   %s\n" "$record_output"
    append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "failed" "false" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "xctrace exited non-zero" "$hide_after_seconds"
    return 1
  fi

  if [[ "$use_live" == "true" ]]; then
    if ! verify_live_recording "$live_log_path" "$trace_path" "$drive_music"; then
      printf "\033[1;31mFAILED\033[0m\n"
      [[ "$drive_music" == "true" ]] && echo "  Music driver log: $driver_log_path"
      append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "failed" "false" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "live verification failed" "$hide_after_seconds"
      return 1
    fi
    [[ "$drive_music" == "true" ]] && echo "  Music driver log: $driver_log_path"
  fi
  if [[ -n "$hide_after_seconds" ]]; then
    if ! verify_hide_after_log "$live_log_path"; then
      printf "\033[1;31mFAILED\033[0m\n"
      append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "failed" "false" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "hide-after verification failed" "$hide_after_seconds"
      return 1
    fi
  fi
  if ! summarize_usage_capture "$usage_log_path"; then
    printf "\033[1;31mFAILED\033[0m\n"
    append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "failed" "false" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "usage capture failed" "$hide_after_seconds"
    return 1
  fi
  append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "passed" "true" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "" "$hide_after_seconds"

  printf "\033[1;32m✓\033[0m %s\n" "$trace_path"
  return 0
}

# ── record (single template) ────────────────────────────────────────────────
do_record() {
  apply_build_profile_flags "$@"
  local template="${2:-Time Profiler}"
  local duration="${3:-20s}"
  local use_demo="false"
  local use_live="false"
  local drive_music="false"
  local scenario
  scenario="$(parse_scenario "$@")"
  local hide_after_seconds
  hide_after_seconds="$(parse_hide_after "$@")"

  # Parse flags (can be anywhere after mode)
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
    [[ "$arg" == "--live" ]] && use_live="true"
    [[ "$arg" == "--drive-music" ]] && drive_music="true"
  done
  parse_profile_flags "$use_demo" "$use_live"
  require_drive_music_live "$drive_music" "$use_live"
  ensure_disk_headroom 2
  if [[ "$use_live" == "true" ]]; then
    preflight_live "$drive_music"
  fi

  build_app
  echo ""
  echo "  Recording: $template ($duration)"
  echo "  Demo mode: $use_demo"
  echo "  Live mode: $use_live"
  echo "  Drive Music: $drive_music"
  echo "  Hide after: ${hide_after_seconds:-none}"
  echo "  Apple Translation build: $(apple_translation_build_enabled && printf true || printf false)"
  echo ""

  record_one "$template" "$duration" "$use_demo" "$use_live" "$scenario" "$drive_music" "$hide_after_seconds"
  print_artifact_usage
}

# ── phased (all templates in sequence) ──────────────────────────────────────
do_phased() {
  apply_build_profile_flags "$@"
  local use_demo="false"
  local use_live="false"
  local drive_music="false"
  local scenario
  scenario="$(parse_scenario "$@")"
  local hide_after_seconds
  hide_after_seconds="$(parse_hide_after "$@")"
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
    [[ "$arg" == "--live" ]] && use_live="true"
    [[ "$arg" == "--drive-music" ]] && drive_music="true"
  done
  parse_profile_flags "$use_demo" "$use_live"
  require_drive_music_live "$drive_music" "$use_live"
  ensure_disk_headroom 8
  if [[ "$use_live" == "true" ]]; then
    preflight_live "$drive_music"
  fi

  build_app

  local total=${#PHASED_TEMPLATES[@]}
  local passed=0
  local failed=0
  local traces=()

  echo ""
  echo "  ═══════════════════════════════════════════════════════════"
  printf "  Phased profiling: %d templates | Demo: %s | Live: %s | Drive Music: %s | Hide after: %s | Apple Translation build: %s\n" "$total" "$use_demo" "$use_live" "$drive_music" "${hide_after_seconds:-none}" "$(apple_translation_build_enabled && printf true || printf false)"
  echo "  ═══════════════════════════════════════════════════════════"
  echo ""

  local i=1
  for entry in "${PHASED_TEMPLATES[@]}"; do
    IFS='|' read -r template duration desc <<< "$entry"
    printf "  [%d/%d] %s\n" "$i" "$total" "$desc"
    if record_one "$template" "$duration" "$use_demo" "$use_live" "$scenario" "$drive_music" "$hide_after_seconds"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
    i=$((i + 1))
    echo ""
  done

  echo "  ═══════════════════════════════════════════════════════════"
  printf "  Results: \033[1;32m%d passed\033[0m" "$passed"
  if [[ "$failed" -gt 0 ]]; then
    printf ", \033[1;31m%d failed\033[0m" "$failed"
  fi
  printf " of %d templates\n" "$total"
  echo "  ═══════════════════════════════════════════════════════════"
  print_artifact_usage
}

# ── sample: direct run with ps-based CPU/RSS sampling ───────────────────────
do_sample() {
  apply_build_profile_flags "$@"
  local duration
  duration="$(parse_sample_duration "$@")"
  local use_demo="false"
  local use_live="false"
  local drive_music="false"
  local scenario
  scenario="$(parse_scenario "$@")"
  local hide_after_seconds
  hide_after_seconds="$(parse_hide_after "$@")"
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
    [[ "$arg" == "--live" ]] && use_live="true"
    [[ "$arg" == "--drive-music" ]] && drive_music="true"
  done
  parse_profile_flags "$use_demo" "$use_live"
  require_drive_music_live "$drive_music" "$use_live"
  ensure_disk_headroom 1
  if [[ "$use_live" == "true" ]]; then
    preflight_live "$drive_music"
  fi

  build_app

  local seconds
  seconds="$(duration_to_sleep_seconds "$duration")"
  local timestamp safe_name usage_log_path live_log_path driver_log_path ledger_live_log_path live_log_pid usage_log_pid driver_pid app_stderr_path stream_log_path
  timestamp="$(/bin/date -u +%Y%m%d-%H%M%SZ)"
  safe_name="Direct-Sample"
  local run_id="${timestamp}-$(mode_name "$use_demo" "$use_live")-${safe_name}-$(git_value rev-parse --short HEAD)"
  usage_log_path="$USAGE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.usage.csv"
  live_log_path="$LIVE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.live.log"
  app_stderr_path="$live_log_path.app-stderr.log"
  stream_log_path="$live_log_path.unified-stream.log"
  driver_log_path="$LIVE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.music-driver.log"
  ledger_live_log_path=""
  live_log_pid=""
  usage_log_pid=""
  driver_pid=""

  stop_app
  local launch_args=("$APP_EXEC")
  if [[ "$use_demo" == "true" ]]; then
    launch_args+=("--demo")
  elif [[ "$use_live" == "true" ]]; then
    launch_args+=("--live")
  fi
  if [[ -n "$hide_after_seconds" ]]; then
    launch_args+=("--hide-after=$hide_after_seconds")
  fi

  if [[ "$use_live" == "true" || -n "$hide_after_seconds" ]]; then
    ledger_live_log_path="$live_log_path"
    live_log_pid="$(start_live_log_capture "$stream_log_path")"
    /bin/sleep 0.5
  fi

  echo "  Direct sample: ${duration} | Demo: $use_demo | Live: $use_live | Drive Music: $drive_music | Hide after: ${hide_after_seconds:-none} | Apple Translation build: $(apple_translation_build_enabled && printf true || printf false)"
  if [[ -n "$ledger_live_log_path" ]]; then
    # Application stderr can carry Logger events without admin log-stream access.
    # This is a separate artifact so available unified logs are never counted twice.
    OS_ACTIVITY_DT_MODE=YES "${launch_args[@]}" > "$app_stderr_path" 2>&1 &
  else
    "${launch_args[@]}" >/dev/null 2>&1 &
  fi
  usage_log_pid="$(start_usage_capture "$usage_log_path")"
  if [[ "$use_live" == "true" && "$drive_music" == "true" ]]; then
    driver_pid="$(start_music_driver "$driver_log_path")"
  fi
  /bin/sleep "$seconds"
  stop_app
  stop_music_driver "$driver_pid"
  stop_usage_capture "$usage_log_pid"
  if [[ -n "$ledger_live_log_path" ]]; then
    finalize_sample_log_capture "$live_log_path" "$stream_log_path" "$app_stderr_path" "$live_log_pid"
  fi

  if [[ "$use_live" == "true" ]]; then
    if ! verify_live_log "$live_log_path" "$drive_music"; then
      summarize_usage_capture "$usage_log_path" || true
      [[ "$drive_music" == "true" ]] && echo "  Music driver log: $driver_log_path"
      append_run_ledger "$run_id" "sample" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "" "failed" "false" "" "$usage_log_path" "$ledger_live_log_path" "live verification failed" "$hide_after_seconds"
      return 1
    fi
    [[ "$drive_music" == "true" ]] && echo "  Music driver log: $driver_log_path"
  fi
  if [[ -n "$hide_after_seconds" ]]; then
    if ! verify_hide_after_log "$live_log_path"; then
      summarize_usage_capture "$usage_log_path" || true
      append_run_ledger "$run_id" "sample" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "" "failed" "false" "" "$usage_log_path" "$ledger_live_log_path" "hide-after verification failed" "$hide_after_seconds"
      return 1
    fi
  fi
  if ! summarize_usage_capture "$usage_log_path"; then
    append_run_ledger "$run_id" "sample" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "" "failed" "false" "" "$usage_log_path" "$ledger_live_log_path" "usage capture failed" "$hide_after_seconds"
    return 1
  fi
  append_run_ledger "$run_id" "sample" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "" "passed" "true" "" "$usage_log_path" "$ledger_live_log_path" "" "$hide_after_seconds"
  print_artifact_usage
}

# ── compare: open two traces side-by-side in Instruments ────────────────────
do_compare() {
  local trace_a="$2"
  local trace_b="$3"

  if [[ ! -d "$trace_a" ]]; then
    echo "Error: trace not found: $trace_a" >&2
    exit 1
  fi
  if [[ ! -d "$trace_b" ]]; then
    echo "Error: trace not found: $trace_b" >&2
    exit 1
  fi

  echo "Opening Instruments with:"
  echo "  A: $trace_a"
  echo "  B: $trace_b"
  /usr/bin/open -a Instruments --args "$trace_a" "$trace_b"
}

# ── report: summarize durable run ledger ───────────────────────────────────
do_report() {
  RUN_LEDGER="$RUN_LEDGER" /usr/bin/python3 <<'PY'
import json
import os
from pathlib import Path

ledger = Path(os.environ["RUN_LEDGER"])
if not ledger.exists():
    print(f"No performance runs recorded yet: {ledger}")
    raise SystemExit(0)

runs = []
with ledger.open() as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            runs.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not runs:
    print(f"No readable performance runs in: {ledger}")
    raise SystemExit(0)

print(f"Performance runs: {len(runs)} ({ledger})")
for run in runs[-12:]:
    usage = run.get("usage", {})
    git = run.get("git", {})
    app = run.get("app", {})
    print(
        "{run_id} | {status} | {mode}/{scenario} | pr={pr} | {branch}@{commit} | "
        "v={version} | appleTranslation={translation} | avgRSS={rss}MB maxCPU={cpu}% | valid={valid}".format(
            run_id=run.get("run_id"),
            status=run.get("status"),
            mode=run.get("mode"),
            scenario=run.get("scenario"),
            pr=git.get("pr_number") or "-",
            branch=git.get("branch") or "-",
            commit=(git.get("commit") or "")[:8],
            version=app.get("marketing_version") or "-",
            translation=app.get("apple_translation_build", False),
            rss=usage.get("avg_rss_mb"),
            cpu=usage.get("max_cpu_pct"),
            valid=run.get("valid"),
        )
    )
PY
}

# ── compare-runs: compare two ledger entries ───────────────────────────────
do_compare_runs() {
  local strict="false"
  local args=()
  local arg
  for arg in "${@:2}"; do
    if [[ "$arg" == "--strict" ]]; then
      strict="true"
    else
      args+=("$arg")
    fi
  done

  local baseline_id="${args[0]:-}"
  local candidate_id="${args[1]:-}"
  if [[ -z "$baseline_id" || -z "$candidate_id" ]]; then
    echo "usage: script/profile.sh compare-runs [--strict] <baseline-run-id> <candidate-run-id>" >&2
    exit 2
  fi

  BASELINE_RUN_ID="$baseline_id" CANDIDATE_RUN_ID="$candidate_id" STRICT_COMPARE="$strict" RUN_LEDGER="$RUN_LEDGER" /usr/bin/python3 <<'PY'
import json
import os
from pathlib import Path

ledger = Path(os.environ["RUN_LEDGER"])
baseline_id = os.environ["BASELINE_RUN_ID"]
candidate_id = os.environ["CANDIDATE_RUN_ID"]
strict = os.environ.get("STRICT_COMPARE") == "true"

runs = {}
if ledger.exists():
    with ledger.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                run = json.loads(line)
            except json.JSONDecodeError:
                continue
            runs[run.get("run_id")] = run

missing = [rid for rid in (baseline_id, candidate_id) if rid not in runs]
if missing:
    print(f"Missing run id(s): {', '.join(missing)}")
    raise SystemExit(1)

a = runs[baseline_id]
b = runs[candidate_id]

def metric(run, key):
    return run.get("usage", {}).get(key)

def delta(key):
    av = metric(a, key)
    bv = metric(b, key)
    if av is None or bv is None:
        return "n/a"
    raw = bv - av
    pct = (raw / av * 100) if av else 0
    return f"{raw:+.2f} ({pct:+.1f}%)"

print(f"Baseline:  {baseline_id} {a.get('mode')}/{a.get('scenario')} {a.get('git', {}).get('branch')}@{(a.get('git', {}).get('commit') or '')[:8]}")
print(f"Candidate: {candidate_id} {b.get('mode')}/{b.get('scenario')} {b.get('git', {}).get('branch')}@{(b.get('git', {}).get('commit') or '')[:8]}")

problems = []
if a.get("mode") != b.get("mode"):
    problems.append("mixed-mode comparison")
if a.get("scenario") != b.get("scenario"):
    problems.append("scenario differs")
if a.get("app", {}).get("apple_translation_build", False) != b.get("app", {}).get("apple_translation_build", False):
    problems.append("Apple Translation build setting differs")
if a.get("app", {}).get("app_stderr_capture_enabled", False) != b.get("app", {}).get("app_stderr_capture_enabled", False):
    problems.append("application stderr capture (OS_ACTIVITY_DT_MODE=YES) differs")
if not a.get("valid") or not b.get("valid"):
    problems.append("at least one run is invalid")
if a.get("git", {}).get("tracked_dirty") or b.get("git", {}).get("tracked_dirty"):
    problems.append("tracked source was dirty for at least one run")
if (a.get("git", {}).get("untracked_count") or 0) > 0 or (b.get("git", {}).get("untracked_count") or 0) > 0:
    problems.append("untracked files were present for at least one run")

for problem in problems:
    print(f"WARNING: {problem}; do not treat as regression evidence.")

print("Deltas candidate - baseline:")
print(f"  avg RSS: {delta('avg_rss_mb')}")
print(f"  max RSS: {delta('max_rss_mb')}")
print(f"  avg CPU: {delta('avg_cpu_pct')}")
print(f"  max CPU: {delta('max_cpu_pct')}")

trace_a = a.get("artifacts", {}).get("trace_size_mb")
trace_b = b.get("artifacts", {}).get("trace_size_mb")
if trace_a is not None and trace_b is not None:
    raw = trace_b - trace_a
    pct = (raw / trace_a * 100) if trace_a else 0
    print(f"  trace size: {raw:+.2f}MB ({pct:+.1f}%)")

if strict and problems:
    print("STRICT: comparison rejected.")
    raise SystemExit(3)
PY
}

# ── clean: wipe out generated traces and local DerivedData ──────────────────
do_clean() {
  echo "Cleaning up profiling artifacts..."
  if [[ -d "$TRACE_DIR" ]]; then
    echo "  Removing trace bundles from: $TRACE_DIR"
    /bin/rm -rf "$TRACE_DIR"/*
  else
    echo "  No traces folder found."
  fi
  if [[ -d "$DERIVED_DATA_DIR" ]]; then
    echo "  Removing local DerivedData: $DERIVED_DATA_DIR"
    /bin/rm -rf "$DERIVED_DATA_DIR"
  else
    echo "  No local DerivedData folder found."
  fi
  # Clean local Xcode coverage raw profiles if any
  if [[ -f "$PWD/default.profraw" ]]; then
    echo "  Removing default.profraw"
    /bin/rm -f "$PWD/default.profraw"
  fi
  echo "Cleanup complete!"
}

# ── main dispatch ───────────────────────────────────────────────────────────
mode="${1:-list}"
case "$mode" in
  list)
    /usr/bin/xcrun xctrace list templates
    ;;
  record)
    do_record "$@"
    ;;
  phased)
    do_phased "$@"
    ;;
  sample)
    do_sample "$@"
    ;;
  report)
    do_report
    ;;
  compare-runs)
    do_compare_runs "$@"
    ;;
  preflight-live)
    drive_music="false"
    for arg in "$@"; do
      [[ "$arg" == "--drive-music" ]] && drive_music="true"
    done
    preflight_live "$drive_music"
    ;;
  doctor)
    do_doctor
    ;;
  disk)
    print_artifact_usage
    ;;
  open)
    template="${2:-Time Profiler}"
    /usr/bin/open -a Instruments --args -t "$template"
    ;;
  compare)
    do_compare "$@"
    ;;
  clean)
    do_clean
    ;;
  *)
    usage
    exit 2
    ;;
esac
