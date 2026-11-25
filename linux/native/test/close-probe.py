"""Closing the window frees its web view: WebKit's web and network processes end, and opening it again still works,
signed in.
  python3 -I close-probe.py <path to nostr-vault-desktop> [hide]
Loads the window's script as a module, as if it had a tray, opens the vault's #/feed, writes a marker into the web
app's localStorage (where its sign-in lives), closes the window the way its close button does (close_window), and waits
up to 20 s for the WebKit processes it started to end. Then opens the window again and reads the marker back. Prints
"CLOSE {json}": open = the WebKit processes while it was open, closed = those still running 20 s after the close,
reopened = those after it opened again, rss_open / rss_closed = this process's own memory (kB) before and after the
close, marker = the marker read back after reopening matches. With "hide" it hides the window instead (what close did
before 2026-11-25): the control, whose WebKit processes must stay. Needs a display and the vault answering."""
import importlib.machinery
import importlib.util
import json
import os
import sys
import time

path = sys.argv[1]
hide = len(sys.argv) > 2 and sys.argv[2] == "hide"
loader = importlib.machinery.SourceFileLoader("nv_desktop", path)
spec = importlib.util.spec_from_loader("nv_desktop", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
from gi.repository import GLib, Gtk  # noqa: E402

if not Gtk.init_check()[0]:
    print("close-probe: no display", file=sys.stderr)
    sys.exit(1)
app = m.App()
app.register(None)
app.indicator = object()  # as if the tray were up: close keeps the app running (without one, close quits)
# The restart as the tray alone (restart_as_tray, an exec) would replace this probe: record that it was asked for.
app.restart_as_tray = lambda: (out.__setitem__("restart_asked", True), False)[1]
MARK = "nv-close-probe"
token = "%d-%d" % (os.getpid(), time.time())
out = {"open": [], "closed": [], "reopened": [], "marker": False, "steps": []}
loop = GLib.MainLoop()


def webkit_children():
    """This process's WebKit helpers (web, network, GPU): WebKitGTK starts them as its own children."""
    kids = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/status") as f:
                st = dict(line.split(":", 1) for line in f if ":" in line)
        except OSError:
            continue
        if st.get("PPid", "").strip() == str(os.getpid()) and st.get("Name", "").strip().startswith("WebKit"):
            kids.append({"name": st["Name"].strip(), "pid": int(pid), "rss": int(st.get("VmRSS", "0 kB").split()[0])})
    return kids


def rss():
    """This process's resident memory (kB): all of it, and the part that is its own heap (not shared library pages)."""
    with open("/proc/self/status") as f:
        st = dict(line.split(":", 1) for line in f if ":" in line)
    return {k: int(st[k].split()[0]) for k in ("VmRSS", "RssAnon", "RssFile")}


def js(code, then):
    def got(v, res, _data):
        try:
            then(v.run_javascript_finish(res).get_js_value().to_string())
        except Exception as e:  # noqa: BLE001 - a page not there yet: try again
            then(None, e)
    app.view.run_javascript(code, None, got, None)


def when_loaded(then, tries=[0]):
    """then() once the window shows the vault's web app (its own origin, the document loaded)."""
    tries[0] += 1
    if tries[0] > 90:
        out["steps"].append("the vault's page never loaded")
        loop.quit()
        return False
    if app.view is None or app.page != "vault" or not (app.view.get_uri() or "").startswith(app.origin()):
        GLib.timeout_add(1000, when_loaded, then)
        return False

    def ready(v, *_e):
        if v == "complete":
            tries[0] = 0
            then()
        else:
            GLib.timeout_add(1000, when_loaded, then)
    js("document.readyState", ready)
    return False


def opened():
    out["steps"].append("opened")

    def written(v, *e):
        out["open"] = webkit_children()
        out["rss_open"] = rss()
        out["steps"].append("marker written" if v == token else f"marker not written ({v} {e})")
        if hide:
            app.window.hide()
        else:
            app.close_window()
        out["closed_at"] = time.monotonic()
        GLib.timeout_add(1000, gone)
    js(f"localStorage.setItem({json.dumps(MARK)}, {json.dumps(token)}); localStorage.getItem({json.dumps(MARK)})", written)


def gone():
    left = webkit_children()
    # Also wait for the restart to be asked for (RESTART_AFTER_CLOSE_S after the close): opening the window again
    # cancels it, so reopening before it fires would hide whether close asks for it at all.
    waiting = left or (not hide and not out.get("restart_asked"))
    if waiting and time.monotonic() - out["closed_at"] < 20:
        return True
    out["closed"] = left
    out["rss_closed"] = rss()
    out["window_after_close"] = app.window is not None
    if hide:
        finish()
        return False
    app.show("feed")
    GLib.timeout_add(1000, when_loaded, reopened)
    return False


def reopened():
    out["steps"].append("reopened")

    def read(v, *_e):
        out["marker"] = v == token
        out["reopened"] = webkit_children()
        finish()
    js(f"localStorage.getItem({json.dumps(MARK)})", read)


def finish():
    loop.quit()


app.show("feed")
GLib.timeout_add(1000, when_loaded, opened)
GLib.timeout_add_seconds(180, lambda: (out["steps"].append("timed out"), loop.quit(), False)[2])
loop.run()
print("CLOSE " + json.dumps(out), flush=True)
os._exit(0)
