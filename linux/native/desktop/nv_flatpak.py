"""Nostr Vault for Linux, the Flatpak's half of the window (nostr-vault-desktop imports this only inside a Flatpak).

The .deb runs the vault as a system service (systemd, its own users, pkexec setup). A Flatpak has none of that, so
here the window runs the vault itself, while someone is logged in:
  - settings: $XDG_CONFIG_HOME/nostr-vault/vault.env (the same KEY=value lines; an npub, a port and a path, no secrets)
  - data:     $XDG_DATA_HOME/nostr-vault (inside the sandbox: ~/.var/app/app.nostrvault.Desktop/data/nostr-vault)
  - log:      $XDG_STATE_HOME/nostr-vault/havend.log
  - havend runs as a child, started again when it exits (supervise.sh's backoff: 1 s doubling to 30 s, back to 1 s
    once it ran a minute). When the app ends, the sandbox's pid namespace ends with it, so no havend is left behind.
  - start at login: the Background portal (asked once; the portal writes the autostart entry).
The mesh (nv-mesh) is not in the Flatpak yet: its key must stay apart from the vault, and that design is reviewed
on its own before it is built.
"""
import os
import re
import shutil
import socket

from gi.repository import Gio, GLib

APP_ID = "app.nostrvault.Desktop"
APP = os.environ.get("NV_FLATPAK_PREFIX", "/app")
HAVEND = os.path.join(APP, "lib", "nostr-vault", "havend")
ENGINE = os.path.join(APP, "lib", "nostr-vault", "haven-engine")
WEB = os.path.join(APP, "share", "nostr-vault", "web")
NPUB = re.compile(r"^npub1[02-9ac-hj-np-z]{58}$")
LOG_MAX = 5 * 1024 * 1024


def active():
    return os.path.exists("/.flatpak-info") or os.environ.get("NV_FLATPAK") == "1"


def config_dir():
    return os.path.join(GLib.get_user_config_dir(), "nostr-vault")


def env_file():
    return os.path.join(config_dir(), "vault.env")


def data_dir():
    return os.path.join(GLib.get_user_data_dir(), "nostr-vault")


def log_file():
    return os.path.join(GLib.get_user_state_dir(), "nostr-vault", "havend.log")


def drives():
    """The setup page's one choice: the app's own data folder (a Flatpak can't reach other drives in v1)."""
    d = data_dir()
    os.makedirs(d, exist_ok=True)
    try:
        free = shutil.disk_usage(d).free
    except OSError:
        free = 0
    return [{"path": d, "free": free, "sd": False}]


def _free(port, host):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def pick_port():
    """8080 when it and 8081 (the mesh door) are free, else the next free pair up to 8199: a .deb on the same
    machine keeps 8080. The pick is saved, so phones keep finding the vault on the same port."""
    for p in range(8080, 8200, 2):
        if _free(p, "0.0.0.0") and _free(p + 1, "127.0.0.1"):
            return p
    return 0


def engine_port():
    """The engine's loopback port: 3355, or any free one when a .deb's vault holds 3355. Not saved: only havend uses it."""
    if _free(3355, "127.0.0.1"):
        return 3355
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def write_env(values):
    os.makedirs(config_dir(), mode=0o700, exist_ok=True)
    path = env_file()
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# Nostr Vault (Flatpak): written by the app's setup. An npub, a port and a path; no secrets.\n")
        for k in ("NV_OWNER", "NV_PORT", "NV_DATA_DIR"):
            if values.get(k):
                f.write(f"{k}={values[k]}\n")
    os.replace(tmp, path)


def setup(owner, current):
    """The setup page's Start: check the npub, pick the port, write vault.env. Returns (ok, text)."""
    owner = owner.strip()
    if not NPUB.match(owner):
        return False, "That isn't an npub (npub1 and 58 more letters and digits)."
    port = current.get("NV_PORT") or ""
    if not port:
        p = pick_port()
        if not p:
            return False, "No free port between 8080 and 8199 for the vault."
        port = str(p)
    os.makedirs(data_dir(), mode=0o700, exist_ok=True)
    write_env({"NV_OWNER": owner, "NV_PORT": port, "NV_DATA_DIR": data_dir()})
    return True, f"Your vault is set up on port {port}."


def request_background(on_done=None):
    """Ask the Background portal to start the app at login with only the tray (asked once; GNOME then lists it under
    Background Apps). on_done(granted) is called with the answer when there is one."""
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error:
        return
    opts = {
        "reason": GLib.Variant("s", "Keep your vault running while you're logged in, and start it when you log in."),
        "autostart": GLib.Variant("b", True),
        "commandline": GLib.Variant("as", ["nostr-vault-desktop", "--tray"]),
        "dbus-activatable": GLib.Variant("b", False),
    }

    def answered(_c, _s, _p, _i, _sig, params):
        code, results = params.unpack()
        if on_done:
            on_done(code == 0 and bool(results.get("background")))

    def sent(conn, res):
        try:
            handle = conn.call_finish(res).unpack()[0]
        except GLib.Error:
            if on_done:
                on_done(False)
            return
        conn.signal_subscribe("org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request", "Response",
                              handle, None, Gio.DBusSignalFlags.NO_MATCH_RULE, answered)

    bus.call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Background",
             "RequestBackground", GLib.Variant("(sa{sv})", ("", opts)), GLib.VariantType("(o)"),
             Gio.DBusCallFlags.NONE, -1, None, sent)


class Supervisor:
    """Runs havend and starts it again when it exits, as supervise.sh does in the container."""

    def __init__(self):
        self.proc = None
        self.state_word = "inactive"  # systemd's words, as the window already speaks them
        self.wanted = False
        self.wait_s = 1
        self.started = 0
        self.timer = 0

    def state(self):
        return self.state_word

    def start(self, env):
        self.env = dict(env)
        self.wanted = True
        if self.proc is None and not self.timer:
            self._spawn()

    def stop(self):
        self.wanted = False
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
        if self.proc is not None:
            self.proc.send_signal(15)
        self.state_word = "inactive"

    def _spawn(self):
        self.timer = 0
        env = self.env
        os.makedirs(env["NV_DATA_DIR"], mode=0o700, exist_ok=True)
        log = log_file()
        os.makedirs(os.path.dirname(log), exist_ok=True)
        try:
            if os.path.getsize(log) > LOG_MAX:
                os.replace(log, log + ".1")
        except OSError:
            pass
        port = int(env.get("NV_PORT", "8080"))
        launcher = Gio.SubprocessLauncher.new(Gio.SubprocessFlags.STDERR_MERGE)
        for k, v in {
            "NV_OWNER": env["NV_OWNER"], "NV_DATA_DIR": env["NV_DATA_DIR"], "NV_PORT": str(port),
            "NV_MESH_DOOR_PORT": str(port + 1), "HAVEN_MESH_PLAIN_PORT": str(port + 1),
            "NV_ENGINE_PORT": str(engine_port()), "NV_ENGINE_BIN": ENGINE, "NV_WEB_DIR": WEB,
        }.items():
            launcher.setenv(k, v, True)
        for k in ("NV_UPDATE_HOOK", "NV_MOVE_ROOT"):  # updates come from Flatpak; no moving out of the sandbox in v1
            launcher.unsetenv(k)
        fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC, 0o600)
        launcher.take_stdout_fd(fd)
        try:
            self.proc = launcher.spawnv([HAVEND])
        except GLib.Error as e:
            self.proc = None
            self.state_word = "failed"
            self._again(f"couldn't start havend: {e.message}")
            return
        self.started = GLib.get_monotonic_time() // 1_000_000
        self.state_word = "active"
        self.proc.wait_async(None, self._exited)

    def _exited(self, proc, res):
        try:
            proc.wait_finish(res)
        except GLib.Error:
            pass
        self.proc = None
        if not self.wanted:
            self.state_word = "inactive"
            return
        self.state_word = "failed"
        ran = GLib.get_monotonic_time() // 1_000_000 - self.started
        if ran >= 60:
            self.wait_s = 1
        self._again(f"havend exited ({proc.get_exit_status() if proc.get_if_exited() else 'signal'}) after {ran}s")

    def _again(self, why):
        if not self.wanted:
            return
        try:
            with open(log_file(), "a", encoding="utf-8") as f:
                f.write(f"nostr-vault-desktop: {why}, starting it again in {self.wait_s}s\n")
        except OSError:
            pass
        self.timer = GLib.timeout_add_seconds(self.wait_s, lambda: (self._spawn(), False)[1])
        self.state_word = "activating"
        self.wait_s = min(self.wait_s * 2, 30)
