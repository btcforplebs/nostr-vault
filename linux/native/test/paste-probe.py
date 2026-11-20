"""One paste into the desktop window's own web view, with real keys (wtype) on a Wayland display.
  python3 -I paste-probe.py <path to nostr-vault-desktop> <expect>
Loads the window's script as a module, builds its window (make_window: the same web view and the same paste guard),
loads a page with a focused text field at the vault's origin, presses Ctrl+V with wtype and prints
"VALUE <the field's text>" and "GUARD <0|1>". <expect> is the text the field should hold after the paste; the probe
exits 0 when it does. A crash in WebKit kills this process (the caller sees the signal). Needs wtype and a display."""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys

path, expect = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("nv_desktop", path)
spec = importlib.util.spec_from_loader("nv_desktop", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
from gi.repository import GLib, Gtk, WebKit2  # noqa: E402

if not Gtk.init_check()[0]:
    print("paste-probe: no display", file=sys.stderr)
    sys.exit(1)
print("GUARD %d" % (1 if m.PASTE_GUARD else 0), flush=True)
print("WEBKIT %d.%d.%d" % m.webkit_version(), flush=True)
app = m.App()
app.register(None)
app.make_window()
view = app.view
loop = GLib.MainLoop()
out = {}


def read_value():
    view.run_javascript("document.getElementById('t').value", None, got_value, None)
    return False


def got_value(v, res, _data):
    try:
        out["value"] = v.run_javascript_finish(res).get_js_value().to_string()
    except GLib.Error as e:
        out["err"] = e.message
    loop.quit()


def press():
    # Real key events, through the compositor, into the focused window: as a person pressing Ctrl+V.
    subprocess.run(["wtype", "-M", "ctrl", "v", "-m", "ctrl"], check=False)
    GLib.timeout_add(3000, read_value)
    return False


def changed(v, event):
    if event == WebKit2.LoadEvent.FINISHED:
        app.window.present()
        GLib.timeout_add(2500, press)  # the window mapped and focused, the field focused


view.connect("load-changed", changed)
view.load_html("<!doctype html><textarea id=t autofocus></textarea>"
               "<script>document.getElementById('t').focus()</script>", app.origin() + "/")
GLib.timeout_add_seconds(45, lambda: (out.setdefault("err", "timed out"), loop.quit()))
loop.run()
if "value" not in out:
    print("paste-probe:", out.get("err"), file=sys.stderr)
    os._exit(1)
print("VALUE " + out["value"], flush=True)
os._exit(0 if out["value"] == expect else 3)
