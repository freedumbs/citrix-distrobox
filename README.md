# Running Citrix Workspace App on Fedora via Distrobox

**A technical write-up of why Citrix Workspace App fails on Fedora, and a
container-based workaround that delivers a working HDX desktop session
without modifying the host system.**

| | |
|---|---|
| **Host OS** | Fedora 44 (x86_64) |
| **Container** | Ubuntu 24.04 via [Distrobox](https://distrobox.it/) |
| **Citrix Workspace App** | 25.08.0.88 (`linuxx64` tarball) |
| **Status** | Working: SSO/SAML login, 2FA, and full HDX desktop sessions |

---

## Contents

1. [Summary](#1-summary)
2. [Background](#2-background)
3. [Root-cause analysis: install-time failures](#3-root-cause-analysis-install-time-failures)
4. [Solution: an Ubuntu userland in Distrobox](#4-solution-an-ubuntu-userland-in-distrobox)
5. [Root-cause analysis: runtime failures](#5-root-cause-analysis-runtime-failures)
6. [Architecture](#6-architecture)
7. [Repository contents](#7-repository-contents)
8. [Installation](#8-installation)
9. [Verification](#9-verification)
10. [Maintenance and removal](#10-maintenance-and-removal)
11. [Limitations and security notes](#11-limitations-and-security-notes)
12. [Disclaimer](#12-disclaimer)

---

## 1. Summary

Citrix Workspace App for Linux supports RHEL, Ubuntu, Debian, openSUSE,
and Raspberry Pi OS. It has never officially supported Fedora. A native
install on Fedora 44 fails because of two library-level problems, and both
come from Citrix assuming a Debian/Ubuntu filesystem layout and library
set.

Patching these one missing `.so` at a time is fragile and in one case
unsafe. This project runs Citrix Workspace inside an **Ubuntu 24.04
Distrobox container** instead. Ubuntu 24.04 is one of the distributions
Citrix actually supports. Distrobox shares the host's `$HOME`, display,
audio, and network, so the app still behaves like a native desktop
application.

Getting the app installed exposed two more problems that only show up at
runtime: a WebKit crash during SSO, and session files that never launch.
Both are fixed by small wrapper scripts in this repository.

The result is the normal workflow: **authenticate → 2FA → desktop opens.**

---

## 2. Background

Citrix Workspace App has two parts that matter here:

- **`selfservice`**: the storefront UI. It uses an embedded **WebKitGTK
  4.0** webview (`UIDialogLibWebKit3_ext.so`) to render login, SSO/SAML,
  and MFA pages.
- **`wfica`**: the HDX engine. It reads a `.ica` connection file (a
  single-use session ticket) and draws the remote desktop.

Citrix ships Linux packages as an RPM, a DEB, and a generic tarball
(`linuxx64-*.tar.gz`). I inspected the tarball read-only. It uses the
**same bundled WebKit payload and integration logic as the RPM**, so
choosing a different package format does not avoid any of the problems
below.

---

## 3. Root-cause analysis: install-time failures

### 3.1 Bundled WebKit extracts outside Fedora's linker path

The RPM hard-depends on `webkit2gtk3 >= 2.26`, a package Fedora removed
from its repositories years ago. To cover for a missing system WebKit,
Citrix's installer self-extracts a bundled copy from
`Webkit2gtk4.0/webkit2gtk-4.0.tar.gz`.

That archive's internal paths are `usr/lib/x86_64-linux-gnu/...`, which is
the Debian/Ubuntu **multiarch** convention. Fedora does not include that
directory in the dynamic linker's search path (`/etc/ld.so.conf*`). The
extracted libraries are therefore invisible to everything that links
against them, even after the installer runs `ldconfig` itself. The
installer gives no error; the libraries just never load.

### 3.2 Transitive dependencies with no Fedora equivalent

Adding the multiarch directory to the linker path only gets you to the
next failure. The bundled WebKit also needs:

| Library | Fedora status |
|---|---|
| `libsoup-2.4.so.1` | Still available as a legacy compat package |
| `libjpeg.so.8` | **Not available.** Fedora's `libjpeg-turbo` ships `libjpeg.so.62` only |

The `libjpeg` gap cannot be closed with a symlink. `.so.62` and `.so.8` are
different SONAMEs, and libjpeg-turbo's SONAME changes reflect real ABI
differences. Aliasing one to the other risks memory corruption, not just
a missing symbol.

### 3.3 Conclusion

Both failures come from the same cause: **Citrix assumes an Ubuntu/Debian
library layout and library versions.** The most reliable fix is to give
Citrix the OS it was built for.

---

## 4. Solution: an Ubuntu userland in Distrobox

[Distrobox](https://distrobox.it/) runs a container (Podman or Docker)
that is closely integrated with the host. By default it shares:

- `$HOME`, so files and paths are the same inside and outside the container
- the X11/Wayland display socket, so windows appear on the normal desktop
- the PulseAudio/PipeWire audio server
- the network namespace, so VPNs, Citrix Gateway, and STA work without
  extra configuration

Inside an Ubuntu 24.04 container, both install-time failures go away:

1. **Linker path.** `/usr/lib/x86_64-linux-gnu/` is a standard multiarch
   directory on Ubuntu, so the bundled WebKit is found as soon as it is
   extracted.
2. **Dependencies.** `libjpeg.so.8` and `libsoup-2.4.so.1` come from
   `apt install libjpeg-turbo8 libsoup2.4-1`. These are the exact
   ABI-matching versions Citrix built against.

> **Note:** Citrix still extracts its bundled WebKit on Ubuntu.
> `integrate.sh` special-cases Ubuntu ≥ 24 because 24.04 dropped the
> system `libwebkit2gtk-4.0-37` package. The bundled copy simply works
> there.

Two more dependency details came up while building the container:

- **`lsb-release` is required.** `integrate.sh` decides whether to extract
  the bundled WebKit based on `lsb_release -rs`. The base `ubuntu:24.04`
  image does not include `lsb-release`. Without it the check fails, WebKit
  is never installed, and the container is as broken as native Fedora.
- **The WebKitGTK 4.0 runtime closure must be installed explicitly.**
  Citrix ships the WebKit shared objects directly, not as a `.deb` with
  dependency metadata, so `apt` cannot resolve their dependencies. The
  full set (`libnotify4`, `libopengl0`, `libwoff1`, `libharfbuzz-icu0`,
  `libenchant-2-2`, `libsecret-1-0`, `libhyphen0`, `libwayland-server0`,
  `libmanette-0.2-0`, and others) was found with `ldd` and is installed
  by `setup.sh`.

Ubuntu 24.04's 64-bit `time_t` transition renamed some runtime packages
with a `t64` suffix. `setup.sh` tries `libsoup2.4-1` first and falls back
to `libsoup2.4-1t64`.

---

## 5. Root-cause analysis: runtime failures

Once installed, the app launches and shows the login page. Two more
problems only appear when you actually connect to a desktop.

### 5.1 WebKit web process crashes during SSO/SAML

**Symptom:** The first login page renders. On the SAML post-back,
authentication fails silently. `PrimaryAuthManager` dies and the logs say
"no coredumps found".

**Cause:** The SAML post-back starts a second `WebKitWebProcess`, which
crashes on the container's GPU/compositing path.

**Fix:** Force software rendering before starting the UI:

```sh
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
```

The performance cost is negligible because only the login webview is
affected. HDX session rendering in `wfica` does not go through WebKit.

### 5.2 Session `.ica` files are saved instead of launched

**Symptom:** After authentication and 2FA, nothing happens. A `.ica` file
appears in `~/Downloads`, often with a browser-style ` (1)` suffix. If
you double-click it, **the storefront UI opens again instead of the
desktop.**

**Cause:** Two separate gaps:

1. The embedded webview treats the `.ica` as a generic download. It has no
   post-download handler that passes it to `wfica`.
2. The `.desktop` launchers created by `distrobox-export` register
   `application/x-ica` to `citrix-workspace-selfservice.desktop`, which is
   the storefront. Opening any `.ica` from the host just relaunches the
   storefront and never reaches `wfica`.

`wfica` itself handles a downloaded `.ica` correctly. Only the handoff is
missing.

**Fix:** Two complementary mechanisms, one for each gap:

| Mechanism | Covers | Implementation |
|---|---|---|
| `inotify` watcher | `.ica` files the embedded webview drops into `~/Downloads` without invoking any handler | `citrix-workspace-launch.sh` |
| MIME handler | Explicit opens: a file-manager double-click, or a download from a regular browser | `ica-launch.sh` + `citrix-ica-handler.desktop` |

ICA tickets are single-use. The watcher deletes each file after handing
it to `wfica`. Files opened through the MIME handler carry
`RemoveICAFile=yes`, so `wfica` deletes them itself.

---

## 6. Architecture

```
FEDORA HOST
  App menu ─────────► citrix-workspace-selfservice.desktop ──┐
  File manager / ───► citrix-ica-handler.desktop             │
  browser (.ica)          └─► ica-launch.sh ──┐              │
                                              │              │
  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ distrobox-enter ┼ ─ ─ ─ ─ ─ ─ ─┼ ─ ─ ─ ─
                                              │              │
UBUNTU 24.04 CONTAINER (citrix-workspace)     │              ▼
                                              │   citrix-workspace-launch.sh
                                              │     1. export software-rendering vars
                                              │     2. inotifywait ~/Downloads (bg)
                                              │     3. run selfservice (login/SSO/2FA)
                                              │              │ new *.ica
                                              ▼              ▼
                                         wfica (HDX engine) ──► desktop window
                                                                on host display

Shared with host: $HOME · display socket · audio server · network
```

---

## 7. Repository contents

| File | Runs on | Purpose |
|---|---|---|
| `setup.sh` | Host | Creates the `citrix-workspace` container, installs all dependencies, and extracts the Citrix tarball |
| `install.sh` | Host | After the Citrix installer: exports the menu launcher, points it at `citrix-workspace-launch.sh`, and registers the `.ica` MIME handler |
| `citrix-workspace-launch.sh` | Container | Wraps `selfservice`: sets software-rendering env vars and runs the `.ica` watcher for as long as the UI is open |
| `ica-launch.sh` | Host | MIME handler target: passes a `.ica` file to `wfica` inside the container (auto-starts the container if needed) |
| `citrix-ica-handler.desktop` | Host | Desktop entry that registers `ica-launch.sh` for `application/x-ica`. Contains `@HOME@` / `@REPO_DIR@` placeholders that `install.sh` fills in |

The Citrix installer is proprietary and is **not** included. Download it
from Citrix's website.

---

## 8. Installation

### Prerequisites

- Fedora with `distrobox` and Podman: `sudo dnf install -y distrobox`
- The Citrix Workspace App for Linux **tarball** (`linuxx64-*.tar.gz`),
  downloaded somewhere under `$HOME`. Distrobox shares `$HOME`, so the
  container can read it in place.

### 8.1 Create the container

```sh
./setup.sh                                   # default: ~/Downloads/linuxx64-25.08.0.88.tar.gz
./setup.sh ~/path/to/linuxx64-<version>.tar.gz
```

This creates the container from `ubuntu:24.04` (or reuses it if it
already exists), installs the dependency set described in
[§4](#4-solution-an-ubuntu-userland-in-distrobox), extracts the tarball to
`~/citrix-install`, and stops before the interactive installer. It
refuses a tarball outside `$HOME`, because the container can't see it.

### 8.2 Run the Citrix installer (interactive)

```sh
distrobox enter citrix-workspace
cd ~/citrix-install
sudo ./setupwfc
```

Prompt answers for 25.08 (defaults are fine unless noted):

| Prompt | Answer |
|---|---|
| Setup option | `1` (Install) |
| Install directory | Enter (default `/opt/Citrix/ICAClient`) |
| Create directory? | Enter (`y`) |
| **Proceed with installation?** | **Type `y`.** This prompt defaults to `n`, so pressing Enter aborts. |
| EULA | Page through, then `yes` |
| Integrate with KDE/GNOME, GStreamer | `y` / defaults |
| App Protection | `n`. It needs systemd/kernel hooks that do not work in a container. |
| deviceTRUST / USB support / FIDO2 | `n` unless your organization requires them |

**Expected, harmless messages in a container:** `systemd ... Host is
down`, `killall: not found`, `gnomeShellVersion is not a valid number`.

**Success indicator:** near the end, look for
`The Webkit2gtk-4.0 package is installed from ...`. This is the step that
fails on native Fedora.

To confirm the bundled WebKit resolves correctly (the output should
contain no `not found` lines):

```sh
ldd /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3_ext/UIDialogLibWebKit3_ext.so \
  | grep -i 'webkit\|not found'
```

### 8.3 Integrate with the host desktop

Exit the container, then run from the repository root on the host:

```sh
./install.sh
```

It's safe to re-run, and you **must** re-run it if you move the
repository, because the desktop entries contain absolute paths. It:

1. Exports the Citrix launcher to the host menu with
   `distrobox-export --app selfservice`, unless it's already exported.
2. Rewrites the launcher's `Exec=` line in
   `~/.local/share/applications/citrix-workspace-selfservice.desktop` so
   it runs `citrix-workspace-launch.sh`. This applies the
   software-rendering fix (§5.1) and starts the `.ica` watcher (§5.2).
3. Fills in the `@HOME@` / `@REPO_DIR@` placeholders in
   `citrix-ica-handler.desktop`, installs it, and makes it the default for
   `application/x-ica`.
4. Refreshes the desktop database and checks that `xdg-mime` now resolves
   `.ica` files to the new handler.

<details>
<summary>Manual equivalent (what <code>install.sh</code> does)</summary>

```sh
# 1. export the launcher
distrobox enter citrix-workspace -- distrobox-export --app selfservice

# 2. edit ~/.local/share/applications/citrix-workspace-selfservice.desktop:
#    Exec=/usr/bin/distrobox-enter -n citrix-workspace -- bash /path/to/citrix-distrobox/citrix-workspace-launch.sh

# 3. install the MIME handler (from the repo root)
sed -e "s|@HOME@|$HOME|g" -e "s|@REPO_DIR@|$PWD|g" \
    citrix-ica-handler.desktop > ~/.local/share/applications/citrix-ica-handler.desktop
xdg-mime default citrix-ica-handler.desktop application/x-ica

# 4. refresh and verify
update-desktop-database ~/.local/share/applications
xdg-mime query default application/x-ica     # → citrix-ica-handler.desktop
```

</details>

**Notes:**

- Citrix also exports a hidden `…-citrixapp.desktop` URL-scheme handler
  with `NoDisplay=true`. Leave it in place; it doesn't appear in the menu.
- The handler's `Icon=` line points at `~/.local/share/icons/receiver.png`,
  where `distrobox-export` puts the icon. If yours is elsewhere, edit the
  installed copy. The icon is cosmetic only.
- On KDE, `xdg-mime` may print `qtpaths: command not found`. That warning
  is harmless.

---

## 9. Verification

1. Launch **Citrix Workspace** from the application menu, or run:
   ```sh
   distrobox enter citrix-workspace -- bash /path/to/citrix-distrobox/citrix-workspace-launch.sh
   ```
2. Check that the embedded login/SSO view renders and that you can sign in
   and complete 2FA. This confirms the WebKit fixes (§3, §5.1).
3. Select your published desktop. The watcher should start the session
   within a few seconds (§5.2).
4. **Optional:** sign in at your storefront URL in a regular browser and
   open the downloaded `.ica`. The desktop should open directly. Tick
   "always open files of this type" to skip the click next time.

A full HDX desktop window confirms that everything works end to end.

---

## 10. Maintenance and removal

### Updating Citrix

Re-run `setup.sh` with the newer tarball. It detects and reuses the
existing container. Then run `sudo ./setupwfc` inside the container again,
and re-run `./install.sh` on the host in case the new version re-exported
its launcher. Everything Citrix-specific lives in the container.

### Removing everything

```sh
distrobox stop citrix-workspace
distrobox rm citrix-workspace
rm -f ~/.local/share/applications/citrix-workspace-*.desktop \
      ~/.local/share/applications/citrix-ica-handler.desktop
update-desktop-database ~/.local/share/applications
```

---

## 11. Limitations and security notes

- **Tested configuration only.** Verified on Fedora 44 with Workspace App
  25.08.0.88. Other Citrix versions may change installer prompts or
  bundled libraries.
- **App Protection is unsupported** in this setup (see §8.2). Some
  organizations require it; check with your IT team.
- **Distrobox is not a security sandbox.** The container shares your home
  directory, display, and network. It is used here for userland
  compatibility, not isolation.
- **The `~/Downloads` watcher is broad.** While the Workspace UI is open,
  *any* new `*.ica` file in `~/Downloads` is launched and then deleted.
  The watcher stops when the UI exits.
- **ICA files are credentials.** A `.ica` file is a short-lived,
  single-use session ticket. Do not commit, share, or keep them; both
  launch paths delete them after use.

---

## 12. Disclaimer

This is an independent, unofficial workaround. It is not affiliated with
or endorsed by Citrix or Cloud Software Group. "Citrix", "Citrix
Workspace", and "HDX" are trademarks of their respective owners. No Citrix
software is distributed in this repository.

---

## License

The scripts and documentation in this repository are released under the
[MIT License](LICENSE).

---

*Developed with assistance from [Claude Code](https://claude.com/claude-code).*
