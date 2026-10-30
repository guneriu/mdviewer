#!/bin/bash
# Explicit opt-in only. Does not launch, register, set defaults, or change quarantine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=""
REPLACE=0
for argument in "$@"; do
  case "$argument" in
    --dry-run|--install)
      if [[ -n "$MODE" ]]; then echo "Choose exactly one mode." >&2; exit 2; fi
      MODE="$argument" ;;
    --replace) REPLACE=1 ;;
    *) echo "Usage: bash scripts/install.sh --dry-run | --install [--replace]" >&2; exit 2 ;;
  esac
done
if [[ -z "$MODE" ]]; then
  echo "STOP: installation is not implicit. Use --dry-run, or separately approve --install [--replace]." >&2
  exit 2
fi
SOURCE="$ROOT/.build/release-package/MDViewer.app"
APPLICATIONS="${HOME:?HOME must be set}/Applications"
DESTINATION="$APPLICATIONS/MDViewer.app"
if [[ -L "$APPLICATIONS" || -L "$DESTINATION" ]]; then echo "Refusing symlink installation paths." >&2; exit 1; fi
python3 "$ROOT/scripts/verify_assets.py" --bundle "$SOURCE"
/usr/bin/codesign --verify --strict "$SOURCE"
PLIST="$SOURCE/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == de.local.mdviewer ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MDViewerBuildConfiguration' "$PLIST")" == release ]]
if [[ "$MODE" == --dry-run ]]; then
  printf 'DRY RUN ONLY: verified release; would copy %s to %s\n' "$SOURCE" "$DESTINATION"
  echo "Existing destination requires --replace. No installation/launch/registration/default change performed."
  exit 0
fi
if [[ -e "$DESTINATION" && "$REPLACE" != 1 ]]; then echo "Destination exists; close MDViewer and explicitly use --replace." >&2; exit 1; fi
if /usr/bin/pgrep -x MDViewer >/dev/null; then echo "Close MDViewer before installation; no process will be terminated." >&2; exit 1; fi
echo "WARNING: copying a document-type app may affect macOS discovery/default resolution even without an explicit registration call."
mkdir -p "$APPLICATIONS"
STAGING="$(mktemp -d "$APPLICATIONS/.mdviewer-install.XXXXXX")"
cleanup() {
  if [[ -e "$STAGING/previous.app" ]]; then
    printf 'Previous app retained for recovery: %s\n' "$STAGING/previous.app" >&2
  else
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT
/usr/bin/ditto "$SOURCE" "$STAGING/MDViewer.app"
/usr/bin/codesign --verify --strict "$STAGING/MDViewer.app"
python3 "$ROOT/scripts/verify_assets.py" --bundle "$STAGING/MDViewer.app"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGING/previous.app"; fi
if ! mv "$STAGING/MDViewer.app" "$DESTINATION"; then
  if [[ -e "$STAGING/previous.app" ]]; then mv "$STAGING/previous.app" "$DESTINATION"; fi
  echo "Installation failed; previous app restored where present." >&2
  exit 1
fi
rm -rf "$STAGING/previous.app"
printf 'Copied to %s. Not launched or explicitly registered; no default preference changed.\n' "$DESTINATION"
