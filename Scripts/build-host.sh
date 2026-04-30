#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repo_root/.build/xcode/host"
canonical_app_path="$derived_data_path/Build/Products/Debug/SnapletHost.app"

build_host() {
  xcodebuild \
    -project "$repo_root/Snaplet.xcodeproj" \
    -scheme SnapletHost \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

prune_duplicate_host_apps() {
  while IFS= read -r app_path; do
    [[ -z "$app_path" ]] && continue
    [[ "$app_path" == "$canonical_app_path" ]] && continue
    rm -rf -- "$app_path"
  done < <(
    find \
      "$repo_root" \
      "$HOME/Library/Developer/Xcode/DerivedData" \
      -name "SnapletHost.app" \
      -type d \
      2>/dev/null
  )
}

build_host
prune_duplicate_host_apps

printf 'SnapletHost.app available at %s\n' "$canonical_app_path"
