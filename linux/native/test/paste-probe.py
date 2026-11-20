"""One paste into the desktop window's own web view, with real keys (xdotool) on an X11 display.
  python3 -I paste-probe.py <path to nostr-vault-desktop> <expect>
Loads the window's script as a module, builds its window (make_window: the same web view and the same paste guard),
loads a page with a focused text field at the vault's origin, presses Ctrl+V with xdotool and prints
"VALUE <the field's text>" and "GUARD <0|1>". <expect> is the text the field should hold after the paste; the probe
exits 0 when it does. A crash in WebKit kills this process (the caller sees the signal). Needs xdotool and X11.
NV_PP_OWNER_LEAVES=1: the clipboard's owner (an xclip the caller started) is killed after the window has seen it and
before the keys, as when the app you copied from quits. It prints "HAD <True|False|None>" (what the guard knew of the
clipboard just before) and "AFTER <...>" (once the owner is gone), so a run where the window never saw the owner says so."""
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
from gi.repository import Gdk, GLib, Gtk, WebKit2  # noqa: E402

if not Gtk.init_check()[0]:
    print("paste-probe: no display", file=sys.stderr)
    sys.exit(1)
print("GUARD %d" % (1 if m.PASTE_GUARD else 0), flush=True)
print("WEBKIT %d.%d.%d" % m.webkit_version(), flush=True)
app = m.App()
app.register(None)
app.make_window()
view = app.view
# Every key the window gets (before the web view sees it), so a run whose keys never arrived says so.
app.window.connect("key-press-event", lambda _w, e: (print("KEY %s state %s" % (e.keyval, int(e.state)), flush=True), False)[1])
loop = GLib.MainLoop()
out = {}


def read_value():
    # What GTK itself sees on the clipboard (tells a clipboard the window can't see from a paste that didn't run).
    print("CLIPBOARD %r" % Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text(), flush=True)
    print("FOCUS %s" % type(app.window.get_focus()).__name__, flush=True)
    view.run_javascript("document.getElementById('t').value", None, got_value, None)
    return False


def got_value(v, res, _data):
    try:
        out["value"] = v.run_javascript_finish(res).get_js_value().to_string()
    except GLib.Error as e:
        out["err"] = e.message
    loop.quit()


def owner_leaves():
    print("HAD %s" % app.has_paste.get("CLIPBOARD"), flush=True)
    subprocess.run(["pkill", "-u", str(os.getuid()), "-x", "xclip"], check=False)
    GLib.timeout_add(2000, after_owner)  # owner-change and the TARGETS answer, on the main loop
    return False


def after_owner():
    print("AFTER %s" % app.has_paste.get("CLIPBOARD"), flush=True)
    GLib.idle_add(keys)
    return False


def press():
    if os.environ.get("NV_PP_OWNER_LEAVES") == "1":
        owner_leaves()
    else:
        keys()
    return False


def keys():
    # Real key events, as a person pressing Ctrl+V: xdotool (XTEST) on X11, into the focused window.
    subprocess.run(["xdotool", "key", "ctrl+v"], check=False)
    GLib.timeout_add(3000, read_value)
    return False


def changed(v, event):
    if event == WebKit2.LoadEvent.FINISHED:
        app.window.present()
        view.grab_focus()  # keys go to the web view (and on to the focused field), as after a click in the window
        view.run_javascript("document.getElementById('t').focus()", None, None, None)
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
