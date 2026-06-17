#!/usr/bin/env python3
"""Set _NET_WM_ICON on the Teams window(s) so the taskbar/dock shows our icon
regardless of whether the desktop environment matches the window to a .desktop
file (GNOME's StartupWMClass matching can lag behind a freshly-installed entry).

Usage: set-window-icon <png-path> <wm-class-substring> [timeout-seconds]

Runs inside the container, on the same X display as the launched Edge window.
Polls for matching windows for `timeout` seconds and stamps each one's icon.
"""
import sys
import time
from Xlib import display, X
from PIL import Image


def build_icon(path, sizes=(48, 64)):
    """_NET_WM_ICON = CARDINAL/32 array: per size [w, h, w*h ARGB pixels]."""
    base = Image.open(path).convert("RGBA")
    data = []
    for s in sizes:
        img = base.resize((s, s), Image.LANCZOS)
        data += [s, s]
        for (r, g, b, a) in img.getdata():
            data.append((a << 24) | (r << 16) | (g << 8) | b)
    return data


def walk(win):
    yield win
    try:
        children = win.query_tree().children
    except Exception:
        children = []
    for c in children:
        yield from walk(c)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: set-window-icon <png> <wm-class> [timeout]")
    png, wm_class = sys.argv[1], sys.argv[2]
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 25.0

    d = display.Display()
    root = d.screen().root
    net_wm_icon = d.intern_atom("_NET_WM_ICON")
    cardinal = d.intern_atom("CARDINAL")
    icon = build_icon(png)

    deadline = time.time() + timeout
    stamped = set()
    while time.time() < deadline:
        for w in walk(root):
            try:
                cls = w.get_wm_class()
            except Exception:
                cls = None
            if not cls or w.id in stamped:
                continue
            if any(wm_class in c for c in cls):
                try:
                    w.change_property(net_wm_icon, cardinal, 32, icon)
                    d.flush()
                    stamped.add(w.id)
                except Exception:
                    pass
        time.sleep(0.5)


if __name__ == "__main__":
    main()
