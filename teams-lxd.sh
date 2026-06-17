#!/usr/bin/env bash
#
# teams-lxd.sh — Run company Teams inside an isolated LXD system container.
#
# The container gets enrolled in Intune (so Conditional Access is satisfied)
# while your real laptop stays unmanaged and invisible to your employer.
# Edge runs inside the container but displays on your host desktop via the
# shared X11 socket.
#
# Usage:
#   ./teams-lxd.sh setup     # one-time: create + provision the container
#   ./teams-lxd.sh enroll    # interactive: open Intune portal, sign in, enroll
#   ./teams-lxd.sh run       # launch Edge -> Teams on your desktop
#   ./teams-lxd.sh shell     # drop into a root shell in the container
#   ./teams-lxd.sh status    # show container + enrollment state
#   ./teams-lxd.sh destroy   # delete the container; data/home on host is kept
#   ./teams-lxd.sh install-desktop    # add a "Microsoft Teams (LXD)" app menu launcher
#   ./teams-lxd.sh uninstall-desktop  # remove that launcher
#
# Tested target: Ubuntu 24.04 (noble) container on an X11 or Xwayland host.
#
set -euo pipefail

# ----- config ---------------------------------------------------------------
CT="${TEAMS_CT:-teams-box}"          # container name (override with TEAMS_CT=)
IMAGE="ubuntu:24.04"                  # supported Intune target (also 26.04)
KEYRING_PASS="${TEAMS_KEYRING_PASS:-teams-sandbox}"  # unlock pass for gnome-keyring
TEAMS_URL="https://teams.microsoft.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${TEAMS_DATA:-$SCRIPT_DIR/data}"  # persisted across destroy/recreate
XAUTH_DIR="$DATA_DIR/xauth"          # host dir bind-mounted to /tmp/xauth in the CT

# ----- pretty logging -------------------------------------------------------
c_blue='\033[1;34m'; c_grn='\033[1;32m'; c_yel='\033[1;33m'; c_red='\033[1;31m'; c_off='\033[0m'
log()  { echo -e "${c_blue}==>${c_off} $*"; }
ok()   { echo -e "${c_grn}  ok${c_off} $*"; }
warn() { echo -e "${c_yel}  ! ${c_off} $*"; }
die()  { echo -e "${c_red}  x ${c_off} $*" >&2; exit 1; }

ctexec() { lxc exec "$CT" -- "$@"; }                 # run as root in container
ctuser() { lxc exec "$CT" -- sudo -u ubuntu -i "$@"; }  # run as 'ubuntu'

# prepare_xauth: derive a hostname-agnostic X11 auth cookie into the bind-mounted
# xauth dir so GUI apps in the container authenticate via a per-display cookie —
# WITHOUT weakening host access control. This replaces 'xhost +local:', which
# disabled X11 access control for every local process on the host.
prepare_xauth() {
  command -v xauth >/dev/null 2>&1 || { warn "xauth not found on host — GUI auth may fail"; return 0; }
  mkdir -p "$XAUTH_DIR"
  local ck="$XAUTH_DIR/cookie"
  rm -f "$ck"; : > "$ck"
  # Rewrite the cookie's address family to FamilyWild ('ffff') so it matches the
  # container's (different) hostname when connecting over the shared X socket.
  # Edge/xcb accept this wildcard entry.
  if ! xauth nlist "$DISPLAY" 2>/dev/null | sed -e 's/^..../ffff/' | xauth -f "$ck" nmerge - 2>/dev/null; then
    warn "could not derive an X cookie for $DISPLAY — the GUI window may not appear"
  fi
  # Also add a FamilyLocal entry keyed to the container hostname (= "$CT"):
  # python-xlib's stricter xauth lookup ignores the wildcard entry for a local
  # ":0" connection, and the window-icon helper needs it to authenticate.
  local cv
  cv="$(xauth nlist "$DISPLAY" 2>/dev/null | awk 'NR==1{print $NF}')"
  [ -n "$cv" ] && xauth -f "$ck" add "$CT/unix:${DISPLAY##*:}" MIT-MAGIC-COOKIE-1 "$cv" 2>/dev/null || true
}

# ----- preflight ------------------------------------------------------------
# preflight: used only by setup (container may not exist yet).
preflight() {
  command -v lxc >/dev/null 2>&1 || die "LXD not found. Install with: sudo snap install lxd && sudo lxd init --minimal"
  if ! lxc info >/dev/null 2>&1; then
    die "Can't talk to LXD. Are you in the 'lxd' group? Try: sudo usermod -aG lxd \$USER ; newgrp lxd"
  fi
  [ -n "${DISPLAY:-}" ] || die "No \$DISPLAY set. This script forwards X11; on pure Wayland start an Xwayland session or run from an X11 login."
  [ -S "/tmp/.X11-unix/X${DISPLAY##*:}" ] || warn "X socket for $DISPLAY not found at /tmp/.X11-unix — GUI may not appear."
}

# need_ct: single lxc info call that checks both LXD reachability and container
# existence, replacing the preflight + per-command lxc info double-round-trip.
need_ct() {
  command -v lxc >/dev/null 2>&1 || die "LXD not found. Install with: sudo snap install lxd && sudo lxd init --minimal"
  [ -n "${DISPLAY:-}" ] || die "No \$DISPLAY set. This script forwards X11; on pure Wayland start an Xwayland session or run from an X11 login."
  [ -S "/tmp/.X11-unix/X${DISPLAY##*:}" ] || warn "X socket for $DISPLAY not found at /tmp/.X11-unix — GUI may not appear."
  lxc info "$CT" >/dev/null 2>&1 || die "Container '$CT' missing or LXD unreachable. Run: ./teams-lxd.sh setup"
}

# ensure_running: start the container if it's stopped, then block until it can
# accept commands. Polls the real readiness condition (exec succeeds) rather
# than guessing a fixed delay. Important for the desktop launcher: clicking the
# icon when the box is off should just start it.
ensure_running() {
  local st
  st="$(lxc info "$CT" 2>/dev/null | awk -F': *' '/^Status/{print toupper($2)}')"
  [ "$st" = "RUNNING" ] && return 0
  log "Container '$CT' is ${st:-STOPPED} — starting..."
  lxc start "$CT" 2>/dev/null || true
  local i=0
  until lxc exec "$CT" -- true 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 150 ] && die "Container '$CT' did not become ready."
    sleep 0.1
  done
  ok "container running"
}

# ----- setup ----------------------------------------------------------------
cmd_setup() {
  preflight
  if lxc info "$CT" >/dev/null 2>&1; then
    warn "Container '$CT' already exists — skipping create. Re-run 'destroy' first for a clean rebuild."
  else
    log "Launching $IMAGE as '$CT'..."
    lxc launch "$IMAGE" "$CT"
    ok "container created"
  fi

  # Persistent home: bind-mount data/home over /home/ubuntu so the entire user
  # profile (Edge, keyrings, identity broker) survives container destroy/recreate.
  log "Mounting persistent home ($DATA_DIR/home -> /home/ubuntu)..."
  mkdir -p "$DATA_DIR/home"
  lxc config device add "$CT" home disk \
      source="$DATA_DIR/home" path=/home/ubuntu 2>/dev/null || true

  # Map host user <-> container 'ubuntu' (uid 1000) so the shared X socket and
  # cookie line up. Requires a restart to take effect.
  log "Mapping host uid/gid into container..."
  printf 'uid %s 1000\ngid %s 1000' "$(id -u)" "$(id -g)" | lxc config set "$CT" raw.idmap -
  lxc restart "$CT"
  sleep 3
  ok "idmap applied"

  # Devices: X11 socket, GPU, audio, camera.
  log "Attaching host devices (X11 / GPU / audio / camera)..."
  lxc config device add "$CT" x11 disk \
      source=/tmp/.X11-unix path=/tmp/.X11-unix 2>/dev/null || true
  # X11 auth cookie dir (cookie-based auth instead of insecure 'xhost +local:').
  mkdir -p "$XAUTH_DIR"
  lxc config device add "$CT" xauth disk \
      source="$XAUTH_DIR" path=/tmp/xauth 2>/dev/null || true
  lxc config device add "$CT" gpu gpu 2>/dev/null || warn "no GPU device added (software rendering will be used)"
  # Audio: bind-mount the host audio sockets to STABLE paths under /tmp.
  # Two non-obvious constraints drove this design:
  #  - A 'proxy' device won't work: the LXD daemon connects as root and
  #    PipeWire-pulse refuses a non-owner peer. A bind-mount preserves the
  #    caller's credentials, and idmap makes container uid 1000 = host uid 1000.
  #  - We must NOT mount under /run/user/1000: logind mounts a fresh tmpfs there
  #    when the lingering user session starts, shadowing anything we put under it.
  #    /tmp is untouched, so the mount survives. cmd_run points the clients at it.
  local audio_ok=0
  if [ -S "/run/user/$(id -u)/pulse/native" ]; then
    lxc config device add "$CT" pulse disk \
        source="/run/user/$(id -u)/pulse/native" path=/tmp/pulse-native 2>/dev/null \
        && audio_ok=1 || warn "PulseAudio mount not added"
  fi
  if [ -S "/run/user/$(id -u)/pipewire-0" ]; then
    lxc config device add "$CT" pipewire disk \
        source="/run/user/$(id -u)/pipewire-0" path=/tmp/pipewire-0 2>/dev/null \
        && audio_ok=1 || warn "PipeWire mount not added"
  fi
  [ "$audio_ok" -eq 1 ] || warn "no audio sockets found — call audio may not work"
  # Camera: pass through every /dev/video* present on the host.
  # gid=44 (the 'video' group, which ubuntu belongs to) + mode 0660 — without
  # this the unix-char node is created root:root and ubuntu cannot open it,
  # surfacing as a "NotFoundError: device not found" in the browser.
  local found_cam=0
  for dev in /dev/video*; do
    [ -c "$dev" ] || continue
    devname=$(basename "$dev")
    lxc config device add "$CT" "$devname" unix-char source="$dev" path="$dev" \
        gid=44 mode=0660 2>/dev/null && found_cam=1 || true
  done
  [ "$found_cam" -eq 1 ] || warn "no /dev/video* devices found — camera will not work"
  ok "devices attached"

  # Provision packages inside the container.
  log "Installing base + GUI + Microsoft packages (this takes a few minutes)..."
  ctexec bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl gpg apt-transport-https \
        dbus-x11 gnome-keyring libsecret-1-0 policykit-1 \
        fonts-liberation libnss3 libgbm1 libasound2t64 \
        x11-xserver-utils python3-xlib python3-pil >/dev/null

    # Microsoft signing key + repos (prod = Intune/broker, edge = browser).
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" \
        > /etc/apt/sources.list.d/microsoft-prod.list
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/edge stable main" \
        > /etc/apt/sources.list.d/microsoft-edge.list

    apt-get update -qq
    apt-get install -y -qq microsoft-identity-broker intune-portal microsoft-edge-stable >/dev/null
  '
  ok "packages installed"

  # GPU access: ubuntu must be in render+video groups or /dev/dri/* is denied.
  ctexec usermod -aG render,video ubuntu 2>/dev/null || true

  # Window-icon helper: stamps _NET_WM_ICON on the Teams window so the taskbar
  # shows our icon even if the desktop env hasn't matched the .desktop yet.
  if [ -f "$SCRIPT_DIR/set-window-icon.py" ]; then
    lxc file push -q "$SCRIPT_DIR/set-window-icon.py" "$CT/usr/local/bin/set-window-icon" 2>/dev/null || true
    ctexec chmod +x /usr/local/bin/set-window-icon 2>/dev/null || true
  fi

  # User session: linger keeps the user's systemd + dbus + broker alive so the
  # device-bound keys persist between launches.
  log "Configuring persistent user session + keyring..."
  ctexec loginctl enable-linger ubuntu

  # Drop a session-init helper that brings up dbus + an UNLOCKED gnome-keyring,
  # which is where the identity broker stores its device keys. This auto-unlock
  # is the single most fragile piece — if enrollment silently fails later, look
  # here first.
  ctexec bash -c "cat > /usr/local/bin/session-init <<'EOS'
#!/usr/bin/env bash
set -e
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
# Start a session bus if the systemd user bus isn't up yet.
if [ ! -S /run/user/1000/bus ]; then
  eval \"\$(dbus-launch --sh-syntax)\"
fi
# Unlock the login keyring non-interactively; socket check is faster than pgrep.
if [ ! -S /run/user/1000/keyring/secrets ]; then
  echo -n '${KEYRING_PASS}' | gnome-keyring-daemon --unlock --components=secrets,ssh >/dev/null 2>&1 || true
fi
EOS
chmod +x /usr/local/bin/session-init"
  # Initialise the keyring with our passphrase once.
  ctuser bash -c "export XDG_RUNTIME_DIR=/run/user/1000; \
      echo -n '${KEYRING_PASS}' | gnome-keyring-daemon --unlock --components=secrets,ssh >/dev/null 2>&1 || true"
  ok "session configured"

  echo
  ok "Setup complete. Next:  ./teams-lxd.sh enroll"
}

# ----- enroll (interactive) -------------------------------------------------
cmd_enroll() {
  need_ct
  # Make sure the persistent home exists so enrolment data lands on the host
  # mount (and survives destroy), even if setup was run before this dir existed.
  mkdir -p "$DATA_DIR/home"
  ensure_running
  log "Opening the Company Portal. Sign in with your work account and complete enrollment."
  prepare_xauth
  ctuser bash -c "source /usr/local/bin/session-init; \
      export DISPLAY='${DISPLAY}'; \
      export XAUTHORITY=/tmp/xauth/cookie; \
      intune-portal" || warn "Company Portal exited."
  echo
  ok "When the portal shows the device as compliant, run:  ./teams-lxd.sh run"
}

# raise_if_open: single-instance guard. If a Teams window (WM class 'teams-lxd')
# is already mapped, activate it and signal the caller to stop — so clicking the
# launcher twice just brings the existing window forward instead of opening a
# second one. Best-effort: needs xdotool on the host; otherwise we fall through.
raise_if_open() {
  command -v xdotool >/dev/null 2>&1 || return 1
  local wid
  wid="$(xdotool search --class teams-lxd 2>/dev/null | head -1)"
  [ -n "$wid" ] || return 1
  xdotool windowactivate "$wid" >/dev/null 2>&1 || xdotool windowraise "$wid" >/dev/null 2>&1 || true
  return 0
}

# ----- run ------------------------------------------------------------------
cmd_run() {
  need_ct
  if raise_if_open; then
    ok "Teams is already open — brought it to the front."
    return 0
  fi
  ensure_running
  log "Launching Teams in Edge..."
  prepare_xauth
  # Push the current icon in so the in-container helper can stamp the window.
  local icon; icon="$(pick_icon)"
  [ -f "$icon" ] && lxc file push -q "$icon" "$CT/usr/local/share/teams-lxd.png" 2>/dev/null || true
  ctuser bash -c "source /usr/local/bin/session-init; \
      export DISPLAY='${DISPLAY}'; \
      export XAUTHORITY=/tmp/xauth/cookie; \
      export PULSE_SERVER='unix:/tmp/pulse-native'; \
      export PIPEWIRE_REMOTE='/tmp/pipewire-0'; \
      microsoft-edge-stable --app='${TEAMS_URL}' \
          --class=teams-lxd \
          --no-first-run --no-default-browser-check \
          --use-gl=desktop --ignore-gpu-blocklist \
          --enable-gpu-rasterization \
          --disable-dev-shm-usage >/dev/null 2>&1 &" \
    || die "Edge failed to start — open a shell ('./teams-lxd.sh shell') and check the broker/keyring."
  # Stamp the window's _NET_WM_ICON so the taskbar shows our icon even if the
  # desktop env hasn't matched the .desktop yet. Runs in its own backgrounded
  # session (else it gets SIGHUP'd when the launch shell exits, unlike Edge
  # which self-daemonizes). Best-effort.
  ( ctuser bash -c "export DISPLAY='${DISPLAY}'; export XAUTHORITY=/tmp/xauth/cookie; \
      [ -x /usr/local/bin/set-window-icon ] && [ -f /usr/local/share/teams-lxd.png ] && \
        set-window-icon /usr/local/share/teams-lxd.png teams-lxd 25" >/dev/null 2>&1 & )
  ok "Teams window should be opening on your desktop."
}

# ----- helpers --------------------------------------------------------------
cmd_shell()  { need_ct; lxc exec "$CT" -- bash; }
cmd_status() {
  need_ct
  lxc list "$CT"
  echo
  log "Identity broker service:"
  ctuser systemctl --user status microsoft-identity-broker 2>/dev/null | head -n 5 || warn "broker not running"
}
cmd_destroy() {
  command -v lxc >/dev/null 2>&1 || die "LXD not found."
  read -rp "Delete container '$CT'? Profile data in $DATA_DIR/home is kept. [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }
  lxc delete --force "$CT"
  ok "container destroyed. Profile data preserved at $DATA_DIR/home"
  ok "Run './teams-lxd.sh setup' to get a fresh container with the same login."
}

# ----- desktop launcher -----------------------------------------------------
# Where the .desktop file and our absolute script/icon paths live.
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/teams-lxd.desktop"
SCRIPT_PATH="$SCRIPT_DIR/teams-lxd.sh"
ICON_PATH="$SCRIPT_DIR/teams-lxd.svg"

# pick_icon: SVG icons don't render in every menu/dock, so prefer a PNG. Try to
# render one from the bundled SVG with whatever converter is around; fall back to
# the SVG, then to a stock themed icon name. Echoes the chosen Icon= value.
pick_icon() {
  local png="$SCRIPT_DIR/teams-lxd.png"
  if [ -f "$ICON_PATH" ]; then
    if [ ! -f "$png" ] || [ "$ICON_PATH" -nt "$png" ]; then
      if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w 256 -h 256 "$ICON_PATH" -o "$png" 2>/dev/null || true
      elif command -v inkscape >/dev/null 2>&1; then
        inkscape "$ICON_PATH" -w 256 -h 256 -o "$png" >/dev/null 2>&1 || true
      elif command -v convert >/dev/null 2>&1; then
        convert -background none -resize 256x256 "$ICON_PATH" "$png" 2>/dev/null || true
      fi
    fi
    [ -f "$png" ] && { echo "$png"; return; }
    echo "$ICON_PATH"; return
  fi
  echo "preferences-desktop-remote-desktop"   # stock fallback if the SVG is gone
}

cmd_install_desktop() {
  [ -f "$SCRIPT_PATH" ] || die "Can't locate teams-lxd.sh at $SCRIPT_PATH"
  mkdir -p "$(dirname "$DESKTOP_FILE")"
  local icon; icon="$(pick_icon)"
  # Pass through TEAMS_CT so a custom container name keeps working from the menu.
  local exec_line="$SCRIPT_PATH run"
  [ "$CT" != "teams-box" ] && exec_line="env TEAMS_CT=$CT $exec_line"
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Microsoft Teams (LXD)
GenericName=Team collaboration
Comment=Launch Teams from the isolated, Intune-enrolled LXD container
Exec=$exec_line
Icon=$icon
Terminal=false
Categories=Network;InstantMessaging;Chat;
Keywords=teams;microsoft;chat;meeting;lxd;
StartupNotify=true
StartupWMClass=teams-lxd
EOF
  chmod +x "$DESKTOP_FILE"
  command -v update-desktop-database >/dev/null 2>&1 \
      && update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
  ok "Installed launcher: $DESKTOP_FILE"
  ok "Look for 'Microsoft Teams (LXD)' in your application menu."
}

cmd_uninstall_desktop() {
  if [ -f "$DESKTOP_FILE" ]; then
    rm -f "$DESKTOP_FILE"
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$(dirname "$DESKTOP_FILE")" >/dev/null 2>&1 || true
    ok "Removed launcher: $DESKTOP_FILE"
  else
    warn "No launcher found at $DESKTOP_FILE"
  fi
}

# ----- dispatch -------------------------------------------------------------
case "${1:-}" in
  setup)             cmd_setup ;;
  enroll)            cmd_enroll ;;
  run)               cmd_run ;;
  shell)             cmd_shell ;;
  status)            cmd_status ;;
  destroy)           cmd_destroy ;;
  install-desktop)   cmd_install_desktop ;;
  uninstall-desktop) cmd_uninstall_desktop ;;
  *) echo "Usage: $0 {setup|enroll|run|shell|status|destroy|install-desktop|uninstall-desktop}"; exit 1 ;;
esac
