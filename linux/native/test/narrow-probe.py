"""How narrow the desktop window lets a tiling window manager make it.
  python3 -I narrow-probe.py <path to nostr-vault-desktop>
Loads the window's script as a module, builds its window (make_window: the same minimum size), asks for 600x700, as
a half-width tile on a 1280 px screen does, and prints "SIZE <width>x<height>" once GTK has laid it out. A minimum
wider than 600 px leaves the window wider than the tile, so the tile clips it. Needs a display."""
import importlib.machinery
import importlib.util
import os
import sys

path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("nv_desktop", path)
spec = importlib.util.spec_from_loader("nv_desktop", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
from gi.repository import GLib, Gtk  # noqa: E402

if not Gtk.init_check()[0]:
    print("narrow-probe: no display", file=sys.stderr)
    sys.exit(1)
app = m.App()
app.register(None)
app.make_window()
win = app.window
loop = GLib.MainLoop()


def ask():
    win.resize(600, 700)
    GLib.timeout_add(2000, read)
    return False


def read():
    w, h = win.get_size()
    print("SIZE %dx%d" % (w, h), flush=True)
    loop.quit()
    return False


GLib.timeout_add(1500, ask)
GLib.timeout_add_seconds(30, lambda: (print("narrow-probe: timed out", file=sys.stderr), loop.quit()))
loop.run()
os._exit(0)
