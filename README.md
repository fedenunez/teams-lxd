# teams-lxd — Company Teams, off your real laptop

Run Microsoft Teams (via Microsoft Edge) inside a disposable **LXD** container that enrols in
**Intune** on your behalf — so Microsoft's Conditional Access is satisfied, while your actual
machine stays **unmanaged and unenrolled**: no MDM agent ever runs on it.

Edge runs inside the container, but its window paints on your normal desktop through the shared
X11 socket — it looks and feels like a local app, while the compliance agent and the device-bound
keys are sealed inside the box.

> [!NOTE]
> A richer, animated version of this document lives in [`README.html`](README.html) — open it
> locally in a browser for the full diagram with flow animations and copy-to-clipboard commands.

---

## Install

**Requirements:** a Linux host with an X11 or Xwayland session (`$DISPLAY` set — a normal Ubuntu
desktop session, including GNOME Wayland, works). Tested with Ubuntu 24.04 (noble) containers;
26.04 is also a supported Intune target.

**1. Install LXD and join the `lxd` group:**

```bash
sudo snap install lxd && sudo lxd init --minimal
sudo usermod -aG lxd "$USER" && newgrp lxd
```

**2. Clone the repo:**

```bash
git clone https://github.com/fedenunez/teams-lxd.git
cd teams-lxd
```

**3. Set a strong keyring passphrase** (protects your Intune credentials at rest — don't skip it;
see [Security caveats](#security-caveats)). Add it to your `~/.bashrc` so it's always set:

```bash
export TEAMS_KEYRING_PASS='choose-a-strong-secret'
```

**4. Create and provision the container** (downloads Ubuntu, Edge and the Intune broker — takes a
few minutes):

```bash
./teams-lxd.sh setup
```

**5. Enrol** — sign in with your work account in the Company Portal window that opens:

```bash
./teams-lxd.sh enroll
```

**6. Launch Teams:**

```bash
./teams-lxd.sh run
```

**7. (Optional) Add an application-menu launcher** so you can start Teams with a click:

```bash
./teams-lxd.sh install-desktop
```

See [How to use it](#how-to-use-it) below for the full command reference.

---

## What it is

Microsoft requires that the device touching Teams be enrolled in Intune and pass a
Conditional-Access compliance check. Enrolling your laptop hands your employer an MDM agent with
deep reach into your personal machine. `teams-lxd` moves that burden into a throwaway box: a
Ubuntu 24.04 LXD system container is the thing that gets enrolled.

---

## How to use it

Six core subcommands (plus optional desktop-launcher helpers). You run `setup` and `enroll` once;
after that it's just `run`.

```text
setup  →  enroll  →  run  ↺  run … run …
```

**One-time: create the container, map your UID, attach devices, install Edge + the Intune broker.**

```bash
./teams-lxd.sh setup
```

**Interactive: open the Company Portal, sign in with your work account, finish enrolment.**

```bash
./teams-lxd.sh enroll
```

**Launch Teams in Edge on your desktop (audio, mic, camera and GPU wired through). Starts the container if it's stopped; if Teams is already open, it just brings the window to the front instead of opening a second one.**

```bash
./teams-lxd.sh run
```

**Drop into a root shell in the container for poking around / debugging.**

```bash
./teams-lxd.sh shell
```

**Show container state and whether the identity broker service is alive.**

```bash
./teams-lxd.sh status
```

**Remove the container; your login persists in `data/` (delete `data/` to erase it entirely).**

```bash
./teams-lxd.sh destroy
```

**Add a “Microsoft Teams (LXD)” launcher to your application menu / dock.**

```bash
./teams-lxd.sh install-desktop
```

After `install-desktop`, Teams shows up in your app menu like a native app — clicking it runs `run`
(starting the container if needed). The launcher is written to
`~/.local/share/applications/teams-lxd.desktop` with absolute paths, so don't move the repo
afterwards (just re-run `install-desktop` if you do). To remove it:

```bash
./teams-lxd.sh uninstall-desktop
```

### Configuration via env vars

**Container name (default: `teams-box`).**

```bash
export TEAMS_CT=teams-box
```

**gnome-keyring unlock passphrase — set this to a strong secret (see [Security caveats](#security-caveats)).**

```bash
export TEAMS_KEYRING_PASS=…
```

**Persistent data directory (default: `./data`).**

```bash
export TEAMS_DATA=./data
```

---

## How it works

The container is sealed except for a handful of deliberately punched holes. Edge, audio, video and
the GPU live on the host side of those holes; the Intune agent and its keys never leave the box.
The only things crossing the isolation boundary are a display socket, audio/camera/GPU device nodes
and an optional persistent home — never the management plane.

```mermaid
flowchart LR
    subgraph HOST["🖥️  YOUR LAPTOP · host — unmanaged, not enrolled"]
        direction TB
        TW["Teams window<br/>(painted via X11)"]
        HOME[("data/home<br/>on host disk")]
        AUD["🔊 PipeWire / PulseAudio"]
        CAM["🎥 /dev/video*"]
        GPU["⚡ GPU /dev/dri"]
        NOMDM(["❌ no MDM agent on host"])
    end

    subgraph CT["📦  LXD CONTAINER · teams-box — Ubuntu 24.04, the &quot;managed device&quot;"]
        direction TB
        EDGE["🌐 Microsoft Edge → Teams"]
        UHOME["📁 /home/ubuntu<br/>(persistent)"]
        EAUD["🎧 Edge audio + mic"]
        ECAM["📷 camera in Teams"]
        EGPU["🖼️ hardware rendering"]
        INTUNE["🛡️ Intune broker + 🔑 device keys<br/>sealed in the box"]
    end

    EDGE -->|X11 display| TW
    HOME -->|persistent profile| UHOME
    AUD  -->|audio · mic| EAUD
    CAM  -->|camera| ECAM
    GPU  -->|GPU| EGPU
    INTUNE -.->|blocked from host| NOMDM

    classDef host fill:#11203a,stroke:#3aa0ff,color:#cfe0ff;
    classDef ct fill:#16321f,stroke:#36d399,color:#bff0d6;
    classDef seal fill:#33260f,stroke:#f4a13b,color:#ffd9a6;
    classDef blocked fill:#3a1620,stroke:#ff5d6c,color:#ff9aa5;
    class TW,HOME,AUD,CAM,GPU host;
    class EDGE,UHOME,EAUD,ECAM,EGPU ct;
    class INTUNE seal;
    class NOMDM blocked;
```

---

## Why Intune never touches your laptop

Conditional Access asks one question: *"is the device on a compliant, enrolled machine?"*
teams-lxd answers **yes** — about the container. Everything the management plane installs,
fingerprints and trusts is created inside `teams-box`, on the far side of the isolation boundary.
No MDM agent ever runs on your host; the only place the enrolment exists on your disk is the
container's home directory, which you can wipe whenever you like.

| ✅ Stays inside the container | ❌ Never reaches your host |
| --- | --- |
| The Intune / identity-broker agent & daemon | No MDM agent installed or running on your laptop |
| Device-bound compliance keys (in gnome-keyring) | No compliance scan of your host disk or processes |
| The enrolled "managed device" record Microsoft sees | No fingerprint of your *real hardware* registered with the tenant |
| Edge's profile, cookies and work session | Your files, browser and other accounts stay private |
| Any policy or remote-wipe action targets the box | Enrolment lives only in `data/` — delete it to erase everything |

Because your UID is mapped 1:1 into the container, the shared sockets line up by ownership rather
than by loosening permissions on the host.

---

## What's wired through — and the trick that made each work

| Hole | Mechanism | The gotcha it avoids |
| --- | --- | --- |
| **display** | bind-mount `/tmp/.X11-unix` + per-display `XAUTHORITY` cookie | UID mapped 1:1 so socket ownership lines up; a wildcard MIT cookie authenticates the container's X clients **without** weakening the host via `xhost`. |
| **audio + mic** | bind-mount the Pulse/PipeWire sockets to `/tmp` | A proxy connects as root and PipeWire refuses it; a bind-mount keeps your credentials. Mounted under `/tmp`, not `/run/user`, so logind's tmpfs can't shadow it. |
| **camera** | `unix-char` device with `gid=44 mode=0660` | Default node is `root:root` → "device not found". Group `video` lets `ubuntu` open it. |
| **GPU** | `gpu` device + `ubuntu` in `render,video` | Without the groups `/dev/dri` is denied and Edge crawls on software rendering. |
| **persistence** | `data/home` bind-mounted over `/home/ubuntu` | Rebuild the box anytime without re-enrolling or logging back in. |

---

## Security caveats

> [!WARNING]
> This is a convenience tool, not a hardened security product. Be aware of the following before
> trusting it with work credentials:
>
> - **The keyring passphrase defaults to a weak, public value (`teams-sandbox`).** It unlocks the
>   gnome-keyring that holds your Intune **device-bound credentials**. **Always set
>   `TEAMS_KEYRING_PASS` to a strong secret** before `setup`/`enroll`.
> - **Your enrolment is persisted unencrypted in `data/`.** The keyring and Edge profile live on
>   your host disk in cleartext. Anyone who reads `data/` (backups, file sync, another local user,
>   a stolen disk) can unlock and reuse your enrolled identity. Protect that directory — or run
>   `destroy` *and* delete `data/` when you're done. It is `.gitignore`d so it won't be committed.
> - **The passphrase is written in cleartext** into a helper script (`/usr/local/bin/session-init`)
>   inside the container; any process in the container can read it.
> - **`$DISPLAY` is interpolated into a shell command.** Only run this from a session where you
>   trust the value of `$DISPLAY` (i.e. your own desktop).

---

*Built by **fedenunez** · `teams-lxd.sh`*
