# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`teams-lxd.sh` — a single Bash script that runs Microsoft Teams (via Microsoft Edge) inside an isolated LXD system container. The container gets enrolled in Intune/Conditional Access while the host machine stays unmanaged.

## Usage

```bash
./teams-lxd.sh setup    # one-time: create + provision the container
./teams-lxd.sh enroll   # interactive: open Intune portal and enroll
./teams-lxd.sh run      # launch Edge → Teams on host desktop
./teams-lxd.sh shell    # drop into a root shell in the container
./teams-lxd.sh status   # show container + enrollment state
./teams-lxd.sh destroy  # delete container and all enrollment data
./teams-lxd.sh install-desktop    # write ~/.local/share/applications/teams-lxd.desktop launcher
./teams-lxd.sh uninstall-desktop  # remove that launcher
```

The desktop launcher (`cmd_install_desktop`) writes a `.desktop` file with **absolute** paths to
`teams-lxd.sh run` and an icon, so the repo must not be moved after install (re-run `install-desktop`
if it is). It passes through a non-default `TEAMS_CT` via `env`. `pick_icon()` renders the bundled
`teams-lxd.svg` to `teams-lxd.png` (256×256, via rsvg-convert/inkscape/convert) for menu/dock
compatibility, falling back to the SVG then a stock themed icon name; the PNG is git-ignored.

Configuration via env vars:
- `TEAMS_CT` — container name (default: `teams-box`)
- `TEAMS_KEYRING_PASS` — gnome-keyring unlock passphrase (default: `teams-sandbox`)

## Architecture / key design decisions

The script is structured as `cmd_<subcommand>()` functions dispatched from a `case` at the bottom.

**X11 forwarding:** The host's `/tmp/.X11-unix` socket is bind-mounted into the container. Access is granted via a per-display MIT cookie (not `xhost`): `prepare_xauth()` derives a FamilyWild (`ffff`) cookie from the host's into `$XAUTH_DIR` (bind-mounted to `/tmp/xauth`), and GUI launches set `XAUTHORITY=/tmp/xauth/cookie`. This avoids `xhost +local:`, which disabled X11 access control for all local processes. Requires `$DISPLAY` to be set on the host.

**UID mapping:** The host user's uid/gid is mapped to container uid 1000 (`ubuntu`) via `raw.idmap`. This is required so the shared X socket and auth cookies align. A container restart is needed after setting this.

**Gnome-keyring / session persistence:** The identity broker stores device-bound keys in gnome-keyring. A `/usr/local/bin/session-init` helper script is installed in the container to start dbus and unlock the keyring non-interactively on each `run`/`enroll`. `loginctl enable-linger ubuntu` keeps the systemd user session alive between launches. **If enrollment silently fails, the keyring unlock is the first place to debug.**

**Audio:** PulseAudio + PipeWire passthrough by bind-mounting the host sockets to stable `/tmp` paths (`/tmp/pulse-native`, `/tmp/pipewire-0`) — *not* an LXD proxy (the proxy connects as root and PipeWire refuses a non-owner peer; a bind-mount preserves credentials via idmap) and *not* under `/run/user/1000` (logind's tmpfs would shadow it). `cmd_run` points the clients at those paths. Best-effort; setup continues without it.

**Timezone:** `/etc/localtime` and `/etc/timezone` are bind-mounted read-only from the host so the container (and therefore Teams meeting/message times) matches the host timezone and stays in sync.

**Container helpers:** `ctexec()` runs commands as root in the container; `ctuser()` runs as the `ubuntu` user.

**Window identity / single-instance:** Edge is launched with `--class=teams-lxd`, so the window's `WM_CLASS` matches `StartupWMClass=teams-lxd` in the `.desktop` file. `raise_if_open()` (uses `xdotool`) focuses an existing `teams-lxd` window instead of launching a second one. `ensure_running()` starts the container first if it's stopped (polls readiness, no fixed sleep).

**Taskbar icon:** GNOME's `StartupWMClass` matching can lag a freshly-installed `.desktop` (often needs a relogin on Wayland). To make the icon appear reliably, `set-window-icon.py` (pushed into the container, run after launch via python3-xlib + Pillow) stamps `_NET_WM_ICON` directly on the Teams window. It runs in its own backgrounded session because — unlike Edge, which self-daemonizes — it would otherwise be SIGHUP'd when the launch shell exits. **Auth subtlety:** `prepare_xauth()` writes two cookie entries: a `FamilyWild` (`ffff`) one (Edge/xcb accept it) and a `FamilyLocal` one keyed to the container hostname (`$CT`), which python-xlib's stricter xauth lookup requires for a local `:0` connection.

## Prerequisites

- LXD installed (`sudo snap install lxd && sudo lxd init --minimal`)
- Current user in the `lxd` group
- X11 or Xwayland session running on the host (`$DISPLAY` must be set)
