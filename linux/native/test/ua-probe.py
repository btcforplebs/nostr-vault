"""The user agent the desktop window's own web view gives its pages (what the web app's client tag reads).
  python3 -I ua-probe.py <path to nostr-vault-desktop>     (inside a Flatpak: python3 -I - <path> < ua-probe.py)
Loads the window's script as a module, builds its window (make_window: the same web view, the same settings), loads a
page at the vault's origin and prints "UA <navigator.userAgent>". Needs a display. Exits 1 if it can't read it."""
import importlib.machinery
import importlib.util
import os
import sys

path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("nv_desktop", path)
spec = importlib.util.spec_from_loader("nv_desktop", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
from gi.repository import GLib, Gtk, WebKit2  # noqa: E402

if not Gtk.init_check()[0]:
    print("ua-probe: no display", file=sys.stderr)
    sys.exit(1)
app = m.App()
app.register(None)  # runs its start-up (tray, actions) as a real launch does
app.make_window()
view = app.view
loop = GLib.MainLoop()
out = {}


def done(v, res, _data):
    try:
        out["ua"] = v.run_javascript_finish(res).get_js_value().to_string()
    except GLib.Error as e:
        out["err"] = e.message
    loop.quit()


def changed(v, event):
    if event == WebKit2.LoadEvent.FINISHED:
        v.run_javascript("navigator.userAgent", None, done, None)


view.connect("load-changed", changed)
view.load_html("<!doctype html><p>ua</p>", app.origin() + "/")  # the vault's origin: the window lets it load
GLib.timeout_add_seconds(45, lambda: (out.setdefault("err", "timed out"), loop.quit()))
loop.run()
if "ua" not in out:
    print("ua-probe:", out.get("err"), file=sys.stderr)
    os._exit(1)
print("UA " + out["ua"], flush=True)
os._exit(0)
