#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PROJECT_FILE:-}" ]]; then
  if [[ -f MusicFloat.xcodeproj/project.xcproj ]]; then
    PROJECT_FILE="MusicFloat.xcodeproj/project.xcproj"
  else
    PROJECT_FILE="MusicFloat.xcodeproj/project.pbxproj"
  fi
fi
APP_NAME="${APP_NAME:-MusicFloat}"
INSTALLED_APP="${INSTALLED_APP:-/Applications/$APP_NAME.app}"

usage() {
  cat >&2 <<'EOF'
usage:
  script/version.sh show
  script/version.sh value <MARKETING_VERSION|CURRENT_PROJECT_VERSION>
  script/version.sh bump-build
  script/version.sh set-marketing <semver>
  script/version.sh installed
  script/version.sh running
  script/version.sh assert-tag-version <tag>

Keeps MARKETING_VERSION and CURRENT_PROJECT_VERSION handling in one place.
MARKETING_VERSION is the user-facing semantic version. CURRENT_PROJECT_VERSION
is the monotonically increasing build number.
EOF
}

project_value() {
  local key="$1"
  if [[ "$PROJECT_FILE" == *.xcproj ]]; then
    /usr/bin/awk -F'"' -v key="$key" '$2 == key { print $4; exit }' "$PROJECT_FILE"
    return
  fi
  /usr/bin/awk -F' = ' -v key="$key" '
    index($1, key) {
      gsub(/;| /, "", $2)
      print $2
      exit
    }
  ' "$PROJECT_FILE"
}

set_project_value() {
  local key="$1"
  local old_value="$2"
  local new_value="$3"
  if [[ "$PROJECT_FILE" == *.xcproj ]]; then
    /usr/bin/sed -E -i '' "s/^([[:space:]]*\"$key\":[[:space:]]*)\"[^\"]*\"/\\1\"$new_value\"/" "$PROJECT_FILE"
    return
  fi
  /usr/bin/sed -i '' "s/$key = $old_value;/$key = $new_value;/g" "$PROJECT_FILE"
}

plist_value() {
  local bundle="$1"
  local key="$2"
  if [[ -d "$bundle" ]]; then
    /usr/bin/plutil -extract "$key" raw "$bundle/Contents/Info.plist" 2>/dev/null || true
  fi
}

show_project() {
  local marketing
  local build
  local tag
  local commit

  marketing="$(project_value MARKETING_VERSION)"
  build="$(project_value CURRENT_PROJECT_VERSION)"
  tag="$(/usr/bin/git describe --tags --exact-match HEAD 2>/dev/null || true)"
  commit="$(/usr/bin/git rev-parse --short HEAD 2>/dev/null || true)"

  echo "project_marketing_version=$marketing"
  echo "project_build_version=$build"
  echo "expected_tag=v$marketing"
  echo "head_commit=$commit"
  if [[ -n "$tag" ]]; then
    echo "head_tag=$tag"
  else
    echo "head_tag="
  fi
}

show_installed() {
  local marketing
  local build
  local executable

  marketing="$(plist_value "$INSTALLED_APP" CFBundleShortVersionString)"
  build="$(plist_value "$INSTALLED_APP" CFBundleVersion)"
  executable="$INSTALLED_APP/Contents/MacOS/$APP_NAME"

  echo "installed_app=$INSTALLED_APP"
  if [[ -d "$INSTALLED_APP" ]]; then
    echo "installed_marketing_version=$marketing"
    echo "installed_build_version=$build"
    if [[ -x "$executable" ]]; then
      echo "installed_executable=$executable"
    fi
  else
    echo "installed_missing=true"
  fi
}

show_running() {
  local found=false
  local pid
  local command

  while IFS= read -r pid; do
    found=true
    command="$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)"
    echo "running_pid=$pid"
    echo "running_command=$command"
  done < <(/usr/bin/pgrep -x "$APP_NAME" || true)

  if [[ "$found" == false ]]; then
    echo "running=false"
  fi
}

require_semver() {
  local version="$1"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "error: expected semantic version like 0.4.0, got '$version'" >&2
    exit 2
  fi
}

cmd="${1:-}"
case "$cmd" in
  show)
    show_project
    ;;
  value)
    case "${2:-}" in
      MARKETING_VERSION|CURRENT_PROJECT_VERSION) project_value "$2" ;;
      *) usage; exit 2 ;;
    esac
    ;;
  bump-build)
    current_build="$(project_value CURRENT_PROJECT_VERSION)"
    new_build=$((current_build + 1))
    set_project_value CURRENT_PROJECT_VERSION "$current_build" "$new_build"
    echo "build_version=$current_build->$new_build"
    ;;
  set-marketing)
    version="${2:-}"
    require_semver "$version"
    current_version="$(project_value MARKETING_VERSION)"
    set_project_value MARKETING_VERSION "$current_version" "$version"
    echo "marketing_version=$current_version->$version"
    echo "expected_tag=v$version"
    ;;
  installed)
    show_installed
    ;;
  running)
    show_running
    ;;
  assert-tag-version)
    tag="${2:-}"
    if [[ -z "$tag" ]]; then
      usage
      exit 2
    fi
    marketing="$(project_value MARKETING_VERSION)"
    if [[ "$tag" != "v$marketing" ]]; then
      echo "error: tag '$tag' does not match MARKETING_VERSION '$marketing' (expected v$marketing)" >&2
      exit 1
    fi
    echo "tag_matches_marketing_version=true"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
