#!/usr/bin/env bash
#
# Propagates the version in ./VERSION into both Info.plists.
#
#   ./scripts/sync-version.sh          # write
#   ./scripts/sync-version.sh --check  # fail if anything is out of date
#
# There is one source of truth because there were three, and they had already
# drifted: the plists said 0.1.0 while the released tag was v0.1.1, so the app
# reported a version that did not exist. CI runs --check so that cannot recur.
set -euo pipefail

cd "$(dirname "$0")/.."

CHECK=false
[ "${1:-}" = "--check" ] && CHECK=true

VERSION="$(tr -d '[:space:]' < VERSION)"
[ -n "$VERSION" ] || { echo "error: VERSION is empty" >&2; exit 1; }

PLISTS=(
    "GroveApp/Resources/Info.plist"
    "GroveKit/Sources/grove/Info.plist"
)

status=0
for plist in "${PLISTS[@]}"; do
    current="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "")"
    if [ "$current" = "$VERSION" ]; then
        continue
    fi
    if [ "$CHECK" = true ]; then
        echo "out of date: $plist is '$current', VERSION is '$VERSION'" >&2
        status=1
    else
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
        echo "updated $plist -> $VERSION"
    fi
done

if [ "$CHECK" = true ]; then
    [ "$status" -eq 0 ] && echo "version $VERSION is in sync"
    [ "$status" -ne 0 ] && echo "run ./scripts/sync-version.sh" >&2
    exit "$status"
fi
