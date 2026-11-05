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

echo "==> Creating container '$CONTAINER_NAME' from $IMAGE (no-op if it already exists)"
distrobox create --name "$CONTAINER_NAME" --image "$IMAGE" --yes

echo "==> Installing baseline packages inside the container"
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

echo "==> Copying and extracting the Citrix tarball into the container"
distrobox enter "$CONTAINER_NAME" -- bash -lc "
	set -euo pipefail
	mkdir -p ~/citrix-install
	tar -xzf '$TARBALL' -C ~/citrix-install
"

cat <<EOF

==> Baseline setup done. The Citrix installer itself is an interactive
    text wizard (EULA + a few prompts) -- run it yourself. Everything
    below runs INSIDE the container (distrobox-export only exists there):

    distrobox enter $CONTAINER_NAME

    # --- now inside the container ---
    cd ~/citrix-install
    sudo ./setupwfc

    # confirm the bundled WebKit landed somewhere the linker can see it
    # (should print a path, no "not found"):
    ldd /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3_ext/UIDialogLibWebKit3_ext.so | grep -i 'webkit\|not found'

    # find the launcher Citrix created, then export it to the host menu:
    find /usr/share/applications /opt/Citrix -iname '*.desktop'
    distrobox-export --app <name-from-above>

EOF
