#!/usr/bin/env bash
# Set up Citrix Workspace App inside a Distrobox container, to avoid the
# Fedora-specific WebKit2GTK/libjpeg/libsoup ABI mismatches documented in
# README.md. See README.md for the interactive steps this script can't
# automate (the Citrix installer's EULA/prompt wizard).
set -euo pipefail

CONTAINER_NAME="citrix-workspace"
IMAGE="ubuntu:24.04"
TARBALL="${1:-$HOME/Downloads/linuxx64-25.08.0.88.tar.gz}"

if ! command -v distrobox >/dev/null 2>&1; then
	echo "distrobox not found. Install it first: sudo dnf install -y distrobox" >&2
	exit 1
fi

if [ ! -f "$TARBALL" ]; then
	echo "Citrix tarball installer not found at: $TARBALL" >&2
	echo "Pass the path as an argument: ./setup.sh /path/to/linuxx64-*.tar.gz" >&2
	exit 1
fi

# Resolve to an absolute path, and require it to be under $HOME: Distrobox
# shares $HOME with the container at the same path, but not arbitrary
# host directories.
TARBALL="$(realpath "$TARBALL")"
case "$TARBALL" in
	"$HOME"/*) ;;
	*)
		echo "The tarball must be under \$HOME so the container can read it: $TARBALL" >&2
		echo "Move or copy it into your home directory (e.g. ~/Downloads) and re-run." >&2
		exit 1
		;;
esac

if distrobox list --no-color 2>/dev/null | awk -F'|' 'NR>1 {gsub(/ /, "", $2); print $2}' \
	| grep -qx "$CONTAINER_NAME"; then
	echo "==> Container '$CONTAINER_NAME' already exists, reusing it"
else
	echo "==> Creating container '$CONTAINER_NAME' from $IMAGE"
	distrobox create --name "$CONTAINER_NAME" --image "$IMAGE" --yes
fi

echo "==> Installing baseline packages inside the container"
# shellcheck disable=SC2016  # single quotes intentional: runs inside the container
distrobox enter "$CONTAINER_NAME" -- bash -lc '
	set -euo pipefail
	sudo apt-get update

	# lsb-release: Citrix'\''s integrate.sh gates its bundled-WebKit
	#   extraction on `lsb_release -rs`. The base ubuntu:24.04 image does
	#   NOT ship it; without it that check errors out and WebKit is never
	#   installed, leaving the container as broken as native Fedora was.
	# libjpeg-turbo8 (libjpeg.so.8) + libsoup2.4-1 (libsoup-2.4.so.1):
	#   the two transitive deps of Citrix'\''s bundled WebKit that Fedora
	#   could not supply. These are the reason for the whole container.
	# libgtk-3-0 / libxss1: GTK3 runtime + screensaver-inhibit, app UI.
	# gstreamer plugins: optional, for multimedia/webcam redirection.
	# The libnotify4..libmanette block is the rest of the WebKitGTK 4.0
	#   runtime dependency closure. Citrix ships the WebKit .so directly
	#   (not as a .deb with dependency metadata), so apt never pulls these
	#   automatically -- without them the embedded login/SSO dialog
	#   (UIDialogLibWebKit3_ext.so) fails to load. Confirmed via `ldd`.
	# inotify-tools: the ~/Downloads .ica watcher in
	#   citrix-workspace-launch.sh.
	sudo apt-get install -y \
		lsb-release \
		libjpeg-turbo8 \
		libgtk-3-0 libxss1 \
		gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
		libnotify4 libopengl0 libwoff1 libharfbuzz-icu0 libenchant-2-2 \
		libsecret-1-0 libhyphen0 libwayland-server0 libmanette-0.2-0 \
		inotify-tools

	# Ubuntu 24.04 (noble) ran the 64-bit time_t transition, which renamed
	# some runtime packages with a "t64" suffix. libsoup2.4 may be either
	# name depending on archive state, so try the classic name first and
	# fall back to the t64 variant.
	sudo apt-get install -y libsoup2.4-1 || sudo apt-get install -y libsoup2.4-1t64
'

# The tarball path is passed as a positional argument ($1) rather than
# interpolated into the script string, so paths containing quotes or
# spaces are handled safely.
echo "==> Extracting the Citrix tarball into ~/citrix-install"
# shellcheck disable=SC2016  # $1 must expand inside the container, not here
distrobox enter "$CONTAINER_NAME" -- bash -lc '
	set -euo pipefail
	mkdir -p ~/citrix-install
	tar -xzf "$1" -C ~/citrix-install
' _ "$TARBALL"

cat <<EOF

==> Baseline setup done. The Citrix installer itself is an interactive
    text wizard (EULA + a few prompts) -- run it yourself, inside the
    container (see README.md section 8.2 for the prompt answers):

    distrobox enter $CONTAINER_NAME
    cd ~/citrix-install
    sudo ./setupwfc

    # optional: confirm the bundled WebKit resolves (no "not found" lines)
    ldd /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3_ext/UIDialogLibWebKit3_ext.so | grep -i 'webkit\|not found'

    exit

==> Then, back on the host, wire up the menu launcher and .ica handler:

    ./install.sh

EOF
