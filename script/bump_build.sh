#!/usr/bin/env bash
# bump_build.sh - compatibility wrapper for incrementing CURRENT_PROJECT_VERSION.
set -euo pipefail

script/version.sh bump-build
echo "Done. Run: git add MusicFloat.xcodeproj && git commit -m 'Bump build version'"
