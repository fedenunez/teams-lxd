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
```

Configuration via env vars:
- `TEAMS_CT` — container name (default: `teams-box`)
- `TEAMS_KEYRING_PASS` — gnome-keyring unlock passphrase (default: `teams-sandbox`)

## Architecture / key design decisions

The script is structured as `cmd_<subcommand>()` functions dispatched from a `case` at the bottom.

**X11 forwarding:** The host's `/tmp/.X11-unix` socket is bind-mounted into the container. Access is granted via a per-display MIT cookie (not `xhost`): `prepare_xauth()` derives a FamilyWild (`ffff`) cookie from the host's into `$XAUTH_DIR` (bind-mounted to `/tmp/xauth`), and GUI launches set `XAUTHORITY=/tmp/xauth/cookie`. This avoids `xhost +local:`, which disabled X11 access control for all local processes. Requires `$DISPLAY` to be set on the host.

**UID mapping:** The host user's uid/gid is mapped to container uid 1000 (`ubuntu`) via `raw.idmap`. This is required so the shared X socket and auth cookies align. A container restart is needed after setting this.

**Gnome-keyring / session persistence:** The identity broker stores device-bound keys in gnome-keyring. A `/usr/local/bin/session-init` helper script is installed in the container to start dbus and unlock the keyring non-interactively on each `run`/`enroll`. `loginctl enable-linger ubuntu` keeps the systemd user session alive between launches. **If enrollment silently fails, the keyring unlock is the first place to debug.**

**Audio:** PulseAudio/PipeWire passthrough via an LXD proxy device (`/tmp/pulse-native` inside container → host socket). Best-effort; setup continues without it.

**Container helpers:** `ctexec()` runs commands as root in the container; `ctuser()` runs as the `ubuntu` user.

## Prerequisites

- LXD installed (`sudo snap install lxd && sudo lxd init --minimal`)
- Current user in the `lxd` group
- X11 or Xwayland session running on the host (`$DISPLAY` must be set)
