#!/bin/bash
# Hand a downloaded .ica session file straight to the HDX engine (wfica)
# inside the Citrix Distrobox container, launching the published desktop.
#
# This is the handler for the `application/x-ica` MIME type. Without it,
# double-clicking a downloaded .ica falls through to the self-service
# storefront UI (selfservice.desktop) instead of opening the desktop.
#
# distrobox-enter auto-starts the container if it is stopped, and $HOME is
# shared with the host, so the host-side path passed in "$@" is valid as-is
# inside the container. The .ica itself carries RemoveICAFile=yes, so wfica
# deletes the single-use ticket file after launch.

exec /usr/bin/distrobox-enter -n citrix-workspace -- /opt/Citrix/ICAClient/wfica "$@"
