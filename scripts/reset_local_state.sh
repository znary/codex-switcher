#!/usr/bin/env bash

set -euo pipefail

APP_NAME="Codex Switcher"
BUNDLE_ID="com.zzz.codex.switcher"
STORAGE_NAME="MultiCodexLimitViewer"

DRY_RUN=0
INCLUDE_SHARED_AUTH=0

usage() {
  cat <<'EOF'
Reset Codex Switcher local app data on this Mac.

Usage:
  ./scripts/reset_local_state.sh [--dry-run] [--include-shared-auth]

Options:
  --dry-run              Print what would be removed without deleting anything.
  --include-shared-auth  Also remove ~/.codex/auth.json for a fully empty first launch.
  -h, --help             Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --include-shared-auth)
      INCLUDE_SHARED_AUTH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

TARGETS=(
  "$HOME/Library/Application Support/$STORAGE_NAME"
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  "$HOME/Library/Containers/$BUNDLE_ID"
  "$HOME/Library/Application Scripts/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/WebKit/$BUNDLE_ID"
)

if (( INCLUDE_SHARED_AUTH )); then
  TARGETS+=("$HOME/.codex/auth.json")
fi

run_cmd() {
  if (( DRY_RUN )); then
    printf '[dry-run] %q' "$1"
    shift
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
    return 0
  fi

  "$@"
}

remove_path() {
  local path="$1"

  if [[ -e "$path" || -L "$path" ]]; then
    echo "Removing: $path"
    run_cmd rm -rf "$path"
  else
    echo "Skipping missing path: $path"
  fi
}

echo "Stopping running instances"
run_cmd pkill -x "$APP_NAME" >/dev/null 2>&1 || true
run_cmd pkill -f "multi-codex-limit-viewer" >/dev/null 2>&1 || true
run_cmd killall cfprefsd >/dev/null 2>&1 || true

echo
echo "Clearing local state"
for path in "${TARGETS[@]}"; do
  remove_path "$path"
done

if (( DRY_RUN )); then
  echo
  echo "Dry run complete."
  exit 0
fi

echo
echo "Verification"
remaining=0

for path in "${TARGETS[@]}"; do
  if [[ -e "$path" || -L "$path" ]]; then
    echo "Still present: $path"
    remaining=1
  else
    echo "Cleared: $path"
  fi
done

if (( remaining )); then
  echo
  echo "Local cleanup finished with leftovers."
  exit 1
fi

if (( INCLUDE_SHARED_AUTH == 0 )); then
  echo
  echo "Shared Codex auth was left in place:"
  echo "  $HOME/.codex/auth.json"
  echo "The app may import it again on next launch."
fi

echo
echo "Local cleanup finished."
