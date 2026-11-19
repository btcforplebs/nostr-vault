"""Runs inside the installed Flatpak (flatpak run --command=python3 app.nostrvault.Desktop -I - < smoke.py NPUB):
the window's own Flatpak code sets the vault up for a throwaway npub, starts havend, waits for it to answer on its
port, then stops it. Also checks that the libraries the window and tray load are in the sandbox."""
import os
import sys
import urllib.error
import urllib.request

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3, GLib, WebKit2  # noqa: E402,F401

sys.path.insert(0, "/app/share/nostr-vault/desktop")
import nv_flatpak as fp  # noqa: E402

assert os.path.exists("/.flatpak-info"), "not in a Flatpak"
assert fp.active()
owner = os.environ["NV_TEST_NPUB"]
ok, text = fp.setup("npub1notreal", {})
assert not ok, "a bad npub was taken"
ok, text = fp.setup(owner, {})
assert ok, text
print("setup:", text)
env = {}
for line in open(fp.env_file(), encoding="utf-8"):
    if "=" in line and not line.startswith("#"):
        k, v = line.strip().split("=", 1)
        env[k] = v
assert env["NV_OWNER"] == owner and env["NV_DATA_DIR"] == fp.data_dir(), env
port = int(env["NV_PORT"])

sup = fp.Supervisor()
sup.start(env)
loop = GLib.MainLoop()
result = {"up": False, "tries": 0}


def poll():
    result["tries"] += 1
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2).close()
        result["up"] = True
    except urllib.error.HTTPError:
        result["up"] = True
    except Exception:  # noqa: BLE001
        pass
    if result["up"] or result["tries"] >= 90:
        loop.quit()
        return False
    return True


GLib.timeout_add_seconds(1, poll)
loop.run()
state = sup.state()
sup.stop()
GLib.timeout_add_seconds(3, loop.quit)
loop.run()
if not result["up"]:
    print(open(fp.log_file(), encoding="utf-8").read()[-4000:])
    sys.exit(f"havend never answered on {port} (state {state})")
assert sup.proc is None, "havend didn't stop"
print(f"smoke: havend answered on port {port} after {result['tries']} s, stopped cleanly")
