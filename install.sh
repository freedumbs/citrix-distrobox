#!/usr/bin/env bash
# Host-side integration for Citrix Workspace in Distrobox. Run this AFTER
# setup.sh and the interactive `sudo ./setupwfc` inside the container.
#
#  1. Exports the Citrix self-service launcher to the host app menu (if it
#     isn't already) and repoints its Exec at citrix-workspace-launch.sh, so
#     the software-rendering env vars and the .ica watcher always apply.
#  2. Installs citrix-ica-handler.desktop (filling in its @HOME@/@REPO_DIR@
#     placeholders) and makes it the default handler for application/x-ica.
#
# Safe to re-run: every step overwrites its previous result.
set -euo pipefail

CONTAINER_NAME="citrix-workspace"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SELFSERVICE_DESKTOP="$APPS_DIR/$CONTAINER_NAME-selfservice.desktop"
ICA_DESKTOP="$APPS_DIR/citrix-ica-handler.desktop"

die() { echo "error: $*" >&2; exit 1; }

command -v distrobox >/dev/null 2>&1 || die "distrobox not found. Run setup.sh first."
command -v xdg-mime  >/dev/null 2>&1 || die "xdg-mime not found (package: xdg-utils)."

mkdir -p "$APPS_DIR"

echo "==> Ensuring the Citrix launcher is exported to the host menu"
if [ ! -f "$SELFSERVICE_DESKTOP" ]; then
	distrobox enter "$CONTAINER_NAME" -- distrobox-export --app selfservice \
		|| die "distrobox-export failed. Is Citrix installed in the container (sudo ./setupwfc)?"
fi
[ -f "$SELFSERVICE_DESKTOP" ] || die "expected $SELFSERVICE_DESKTOP after export, but it is missing."

echo "==> Pointing the launcher at citrix-workspace-launch.sh"
sed -i "s|^Exec=.*|Exec=/usr/bin/distrobox-enter -n $CONTAINER_NAME -- bash $REPO_DIR/citrix-workspace-launch.sh|" \
	"$SELFSERVICE_DESKTOP"

echo "==> Installing the .ica MIME handler"
sed -e "s|@HOME@|$HOME|g" -e "s|@REPO_DIR@|$REPO_DIR|g" \
	"$REPO_DIR/citrix-ica-handler.desktop" > "$ICA_DESKTOP"
xdg-mime default citrix-ica-handler.desktop application/x-ica

if command -v update-desktop-database >/dev/null 2>&1; then
	update-desktop-database "$APPS_DIR"
fi

handler="$(xdg-mime query default application/x-ica)"
[ "$handler" = "citrix-ica-handler.desktop" ] \
	|| die "application/x-ica resolves to '$handler', expected citrix-ica-handler.desktop."

cat <<EOF

==> Done.
    Menu launcher : $SELFSERVICE_DESKTOP
    .ica handler  : $ICA_DESKTOP (default for application/x-ica)

    Launch "Citrix Workspace" from your app menu to test.
    If you move this repository, re-run ./install.sh to update the paths.
EOF
