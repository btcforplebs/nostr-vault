"""Which desktop screens the window draws: the phone's own (FeedScreen) or the napplets (ReaderPane's frames).
  python3 -I desk-probe.py <path to nostr-vault-desktop> <owner pubkey hex>
Loads the window's script as a module, builds its window (make_window: the same web view, the same 1240x860 size),
signs the web app in as the owner with a stub NIP-07 signer (its signatures are junk: nothing it signs is accepted, and
nothing here needs to be), opens the vault's #/feed and prints "DESK {desk, napplets, feed}" once the desktop layout
has drawn: desk = the desktop layout (.desk), napplets = napplet frames (.napplet-host), feed = the Feed screen's header
(.feed-head, FeedScreen; the Reader napplet has none). Needs a display and the vault answering. Exits 1 if the desktop
layout never draws in 60 s."""
import importlib.machinery
import importlib.util
import json
import os
import sys

path, owner = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("nv_desktop", path)
spec = importlib.util.spec_from_loader("nv_desktop", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
from gi.repository import GLib, Gtk, WebKit2  # noqa: E402

if not Gtk.init_check()[0]:
    print("desk-probe: no display", file=sys.stderr)
    sys.exit(1)
app = m.App()
app.register(None)
app.make_window()
view = app.view
pk = json.dumps(owner)
# Before the page's own script: the session (main.jsx loadSession), past the first-run steps (nv-ready), and a signer.
stub = f"""(() => {{ if (location.origin !== {json.dumps(app.origin())}) return
  localStorage.setItem("nv-session", JSON.stringify({{ pubkey: {pk}, method: "nip07" }}))
  localStorage.setItem("nv-ready", JSON.stringify([{pk}]))
  window.nostr = {{ getPublicKey: async () => {pk}, signEvent: async t => ({{ ...t, pubkey: {pk}, id: "0".repeat(64), sig: "0".repeat(128) }}) }} }})()"""
view.get_user_content_manager().add_script(WebKit2.UserScript.new(
    stub, WebKit2.UserContentInjectedFrames.TOP_FRAME, WebKit2.UserScriptInjectionTime.START, None, None))
LOOK = """JSON.stringify({ desk: !!document.querySelector(".desk"), napplets: document.querySelectorAll(".napplet-host").length,
  feed: !!document.querySelector(".feed-head") })"""
loop = GLib.MainLoop()
out = {"tries": 0}


def got(v, res, _data):
    try:
        out["last"] = json.loads(v.run_javascript_finish(res).get_js_value().to_string())
    except GLib.Error as e:
        out["err"] = e.message
    s = out.get("last") or {}
    if s.get("desk") and (s.get("feed") or s.get("napplets")):
        GLib.timeout_add_seconds(3, settle)  # a moment more: lazy screens and the side column's cards
    else:
        GLib.timeout_add_seconds(1, poll)


def settle():
    view.run_javascript(LOOK, None, final, None)
    return False


def final(v, res, _data):
    out["last"] = json.loads(v.run_javascript_finish(res).get_js_value().to_string())
    out["done"] = True
    loop.quit()


def poll():
    out["tries"] += 1
    if out["tries"] > 60:
        loop.quit()
        return False
    view.run_javascript(LOOK, None, got, None)
    return False


app.page = "vault"
view.load_uri(app.origin() + "/#/feed")
GLib.timeout_add_seconds(3, poll)
loop.run()
if not out.get("done"):
    print("desk-probe: the desktop layout never drew:", out.get("last"), out.get("err", ""), file=sys.stderr)
    os._exit(1)
print("DESK " + json.dumps(out["last"]), flush=True)
os._exit(0)
