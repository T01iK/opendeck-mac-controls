#!/bin/bash
# Builds the plugin, installs it into OpenDeck and restarts OpenDeck so it is picked up.
# Usage: scripts/install.sh [--no-restart]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="com.t01ik.macoscontrols.sdPlugin"
PLUGINS="$HOME/Library/Application Support/opendeck/plugins"

"$ROOT/scripts/build.sh"

mkdir -p "$PLUGINS"
# Stop the running plugin first so the binary can be replaced cleanly.
pkill -f "$PLUGINS/$NAME/MacControls" 2>/dev/null || true
rm -rf "${PLUGINS:?}/$NAME"
cp -R "$ROOT/build/$NAME" "$PLUGINS/$NAME"
echo "✓ Installed to $PLUGINS/$NAME"

if [[ "${1:-}" != "--no-restart" ]] && pgrep -xq opendeck; then
	echo "→ Restarting OpenDeck"
	# A normal quit may only hide OpenDeck when it runs in the background, so terminate it.
	pkill -x opendeck || true
	for _ in {1..20}; do pgrep -xq opendeck || break; sleep 0.5; done
	sleep 1
	# Launch with a clean environment, like the Dock does, so this shell's variables do not leak into OpenDeck and its plugins.
	env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -a OpenDeck
fi
