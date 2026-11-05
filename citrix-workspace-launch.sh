#!/bin/bash
# Citrix Workspace launcher for the Distrobox container.
#
# Two jobs:
#  1. Force WebKit onto software rendering (the embedded auth webview's
#     WebKitWebProcess crashes on the container's GPU path otherwise).
#  2. Work around the embedded webview saving session .ica files to
#     ~/Downloads instead of launching them: watch ~/Downloads and hand
#     each new .ica straight to wfica (the HDX engine), then delete it
#     (ICA connection tickets are single-use).
#
# The watcher lives only as long as the Workspace UI is open.

export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1

DLDIR="$HOME/Downloads"
WFICA="/opt/Citrix/ICAClient/wfica"
SELFSERVICE="/opt/Citrix/ICAClient/selfservice"

mkdir -p "$DLDIR"

# --- background watcher: auto-launch any new .ica ---
(
  inotifywait -m -q -e close_write -e moved_to --format '%f' "$DLDIR" | while read -r f; do
    case "$f" in
      *.ica)
        # let the download finish flushing, then launch and consume
        ( sleep 1
          "$WFICA" "$DLDIR/$f" >/dev/null 2>&1
          rm -f "$DLDIR/$f"
        ) &
        ;;
    esac
  done
) &
WATCHER=$!

# Kill the watcher (and its inotifywait child) when the UI exits.
trap 'pkill -P "$WATCHER" 2>/dev/null; kill "$WATCHER" 2>/dev/null' EXIT

# --- foreground: the Workspace self-service UI ---
"$SELFSERVICE"
