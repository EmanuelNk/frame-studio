#!/bin/bash
# Updates Frame Studio: pulls the latest code from GitHub, then rebuilds and reinstalls the app in /Applications.
#   ./update.sh          update if there's anything new (or if the app isn't installed yet)
#   ./update.sh --force  rebuild and reinstall even if already up to date
set -euo pipefail
cd "$(dirname "$0")"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "Unknown option: $arg (use --force)" >&2; exit 2 ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "This folder isn't a git checkout, so there's nothing to update from." >&2
  exit 1
fi

# Never pull over local edits.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "There are uncommitted changes in $(pwd):" >&2
  git status --short >&2
  echo "Commit or discard them first, then run this again." >&2
  exit 1
fi

BEFORE="$(git rev-parse HEAD)"
echo "→ Checking GitHub for updates…"
if ! git pull --ff-only --quiet; then
  echo "Couldn't update from GitHub: you may be offline, or this copy has commits GitHub doesn't." >&2
  echo "Nothing was changed." >&2
  exit 1
fi
AFTER="$(git rev-parse HEAD)"

APP="/Applications/Frame Studio.app"
if [ "$BEFORE" = "$AFTER" ]; then
  if [ "$FORCE" = 0 ] && [ -d "$APP" ]; then
    echo "✓ Already up to date ($(git rev-parse --short HEAD)). Use --force to reinstall anyway."
    exit 0
  fi
  echo "  No new changes; reinstalling."
else
  echo "  New since your last update:"
  git log --reverse --format='   • %s' "${BEFORE}..${AFTER}"
fi

exec ./build.sh --install
