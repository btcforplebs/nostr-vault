"""Nostr Vault for Linux: the window checks that it draws, and finds a way to draw if it doesn't.

Some graphics stacks leave WebKitGTK's window empty with no crash and no error: the GTK frame and title draw, the
inside stays the window's own grey (a Zorin OS 18 desktop on a Radeon 780M under Wayland, beta 9, 2026-11-25), or it
stays black (the NVIDIA driver with the DMA-BUF renderer, beta 4). Nobody can fix that from inside the page, and the
person looking at it shouldn't have to change a setting. So:

  - Before WebKit loads (choose()), the window picks how WebKit draws, a "mode":
        dmabuf          WebKit's default, the DMA-BUF renderer (the healthy path on Mesa: AMD, Intel, a Pi)
        no-dmabuf       WEBKIT_DISABLE_DMABUF_RENDERER=1 (what the NVIDIA driver needs; the first try there)
        no-compositing  that, plus WEBKIT_DISABLE_COMPOSITING_MODE=1 (no GPU at all: always draws, a little slower)
    the one that worked last time first, if one did (renderer.json, next to window.log's folder in ~/.config).
  - After a window opens (Checker.watch), it checks every 2 s, for up to 45 s, that the page answers JavaScript and
    that WebKit put pixels into the window (the view drawn into an offscreen picture: nothing at all = not drawn).
    The first check that passes ends it, and the mode is remembered.
  - If the time runs out, or the page's web process ends first, the window starts over (exec, the same process id)
    in the next mode. When none works it shows a page drawn by GTK alone (no web process) that opens the vault in
    the browser, and remembers that for this WebKitGTK version (an update tries again; so does its button).
  - Someone who set either WEBKIT_ variable themselves keeps it: the check runs, and on a failure the window shows
    the browser page instead of changing their setting.
The .deb's postinst sends the window SIGUSR2 after an update (listen_for_update): it starts over on the new code.
(SIGUSR2, not SIGUSR1: JavaScriptCore takes SIGUSR1 in this process to pause its threads for garbage collection, and
a SIGUSR1 from outside froze the window's main thread on CI.)
Windows from before this file was shipped don't handle SIGUSR2 and quit, so no old window lingers after an update.

Test knob: NV_PAINT_GIVE_UP_S (default 45), so the window test can run the whole ladder in a minute.
"""
import glob
import json
import os
import signal
import sys
import time
import weakref

MODES = ("dmabuf", "no-dmabuf", "no-compositing")
DMABUF = "WEBKIT_DISABLE_DMABUF_RENDERER"
COMPOSITING = "WEBKIT_DISABLE_COMPOSITING_MODE"
OURS = "NV_DESKTOP_RENDERER"  # the mode this process runs in, set by choose() (and "user")
TRIED = "NV_DESKTOP_TRIED"  # the modes that failed before this exec, comma-separated
FIRST_CHECK_S = 2
EVERY_S = 2
try:
    GIVE_UP_S = max(4, int(os.environ.get("NV_PAINT_GIVE_UP_S", "45")))
except ValueError:
    GIVE_UP_S = 45
KILL_AFTER_S = 4  # a restart waits this long for WebKit's processes (and bwrap) to end, then kills them (a hung or
# stopped one won't end; the network process lives as long as this process would)
WAIT_S = 10  # then this long for every other child (xdg-dbus-proxy ends once its sandbox is gone)
MIN_COLOURS = 8  # a drawn page has many (anti-aliased text); an empty view is one flat colour (or WebKit's background)

mode = None
tried = []
why = ""  # how choose() picked the mode, for the log


def nvidia():
    """The NVIDIA driver is loaded (a hybrid laptop counts: its DMA-BUF path is the one that drew black)."""
    if os.path.exists("/proc/driver/nvidia/version") or os.path.isdir("/sys/module/nvidia_drm"):
        return True
    for d in glob.glob("/sys/class/drm/card*/device/driver"):
        try:
            if os.path.basename(os.path.realpath(d)) == "nvidia":
                return True
        except OSError:
            pass
    return False


def ladder():
    first = "no-dmabuf" if nvidia() else "dmabuf"
    return [first] + [m for m in MODES if m != first]


def state_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "nostr-vault-desktop", "renderer.json")


def load_state():
    try:
        with open(state_path(), encoding="utf-8") as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(d):
    path = state_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w", encoding="utf-8") as f:
            json.dump(d, f)
        os.replace(path + ".tmp", path)
    except OSError:
        pass


def apply(m):
    """The environment WebKit reads for mode m (its web processes read it as they start; the UI side once)."""
    os.environ.pop(DMABUF, None)
    os.environ.pop(COMPOSITING, None)
    if m in ("no-dmabuf", "no-compositing"):
        os.environ[DMABUF] = "1"
    if m == "no-compositing":
        os.environ[COMPOSITING] = "1"
    os.environ[OURS] = m


def choose():
    """Before WebKit loads: the mode this process draws in."""
    global mode, tried, why
    own = os.environ.get(OURS)
    if own in MODES or own == "user":
        mode, why = own, "carried over from before this process started over"
        tried = [t for t in os.environ.get(TRIED, "").split(",") if t in MODES]
        if own == "user":
            return
    elif DMABUF in os.environ or COMPOSITING in os.environ:
        mode, why = "user", "set by hand (%s)" % ", ".join(
            f"{k}={os.environ[k]}" for k in (DMABUF, COMPOSITING) if k in os.environ)
        os.environ[OURS] = mode
        return
    else:
        saved = load_state().get("works")
        if saved in MODES:
            mode, why = saved, "it worked last time"
        else:
            mode = ladder()[0]
            why = "the NVIDIA driver is loaded" if mode == "no-dmabuf" else "the default"
        tried = []
    apply(mode)


def webkit_version_string():
    from gi.repository import WebKit2
    return "%d.%d.%d" % (WebKit2.get_major_version(), WebKit2.get_minor_version(), WebKit2.get_micro_version())


def descendants(root):
    """Every process under root: (pid, command name)."""
    kids = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
        except (OSError, IndexError):
            continue
        kids.setdefault(int(fields[1]), []).append((int(pid), comm, fields[0]))
    out, todo = [], [root]
    while todo:
        for pid, comm, st in kids.get(todo.pop(), []):
            out.append((pid, comm, st))
            todo.append(pid)
    return out


def children():
    """This process's own children (every one, not just WebKit's): (pid, command name, state)."""
    me = os.getpid()
    return [k for k in descendants(me) if _parent(k[0]) == me]


def _parent(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, IndexError, ValueError):
        return None


class Checker:
    """One per app: watches each new window's first 45 s, and starts the process over when it must."""

    def __init__(self, app, log, supervisor=None):
        self.app = app
        self.log = log
        self.supervisor = supervisor  # the Flatpak's havend: stopped before an exec, so the new process can start it
        self._view = None  # a weak reference: a closed window's view must be free to go (and its WebKit processes)
        self.deadline = 0
        self.js_ok = False
        self.done = True
        self._browser = None  # (weak) the window showing the browser page, while it does
        self.restarting = False
        self.cairo_ok = True
        log(f"drawing mode {mode} ({why})" + (f"; failed before: {', '.join(tried)}" if tried else ""))

    @property
    def view(self):
        return self._view() if self._view is not None else None

    @view.setter
    def view(self, v):
        self._view = weakref.ref(v) if v is not None else None

    @property
    def browser_window(self):
        return self._browser() if self._browser is not None else None

    # ---- the check

    def watch(self, view):
        """A new window and its web view (make_window): check that it draws."""
        self.view = view
        self.js_ok = False
        self.done = False
        self.deadline = time.monotonic() + GIVE_UP_S
        failed = load_state().get("failed")
        if mode != "user" and not tried and failed and failed == webkit_version_string():
            self.done = True
            self.log(f"no drawing mode worked with WebKitGTK {failed} last time: showing the browser page")
            self.show_browser_page(True)
            return
        from gi.repository import GLib
        GLib.timeout_add_seconds(FIRST_CHECK_S, self.poll)

    def poll(self):
        view = self.view
        if self.done or view is None or view is not self.app.view:
            return False
        if not view.get_mapped():
            self.deadline = time.monotonic() + GIVE_UP_S  # not on screen (minimised): nothing to judge yet
            return True
        d = self.drew_or_unknown(view)
        self.log(f"drawing check: js={'yes' if self.js_ok else 'no'} drew={d}")
        if self.js_ok and d is not False:
            self.done = True
            self.worked()
            return False
        if time.monotonic() >= self.deadline:
            self.done = True
            self.failed("nothing drawn" if self.js_ok else "its page never answered")
            return False

        def answered(v, res, _data):
            try:
                v.run_javascript_finish(res)
            except Exception:  # noqa: BLE001 - a page that went away mid-call: no answer this time
                return
            if v is self.view:
                self.js_ok = True

        view.run_javascript("document.readyState", None, answered, None)
        return True

    def drew_or_unknown(self, view):
        """drew(): True, False, or "unknown" when the check can't tell (or fails itself). Only False starts the
        window over: a check that can't see must not walk a working window down the ladder."""
        try:
            d = self.drew(view)
        except Exception as e:  # noqa: BLE001 - logged; the window keeps running
            self.log("the drawing check failed (taken as drawn): " + repr(e))
            return "unknown"
        return "unknown" if d is None else d

    def drew(self, view):
        """WebKit put pixels into the view: drawn into an offscreen picture filled with a colour no page uses (a
        never-painting view leaves it untouched), or, without python3-gi-cairo, read back from the window (an empty
        view leaves the window's own flat background). Drawn = at least MIN_COLOURS colours besides the sentinel, so
        a view that paints only its flat background (the NVIDIA black window) is not drawn. None: can't tell."""
        a = view.get_allocation()
        w, h = a.width, a.height
        if w < 8 or h < 8:
            return None
        try:
            import cairo
        except ImportError:
            cairo = None
        if cairo is not None and self.cairo_ok:
            try:
                return self.drew_cairo(cairo, view, w, h)  # its answer stands: it sees GL content, the readback doesn't
            except TypeError as e:  # pycairo without PyGObject's cairo support (python3-gi-cairo)
                self.cairo_ok = False
                self.log("no offscreen drawing check (%r): reading the window back instead" % e)
        return self.drew_window(view, a, w, h)

    def drew_cairo(self, cairo, view, w, h):
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
        cr = cairo.Context(surf)
        cr.set_source_rgba(1, 0, 1, 1)
        cr.paint()
        view.draw(cr)
        surf.flush()
        data, stride = bytes(surf.get_data()), surf.get_stride()
        sentinel = bytes((255, 0, 255, 255))  # ARGB32 little-endian: B, G, R, A
        seen = set()
        for y in range(0, h, 9):
            for x in range(0, w, 9):
                i = y * stride + x * 4
                c = data[i:i + 4]
                if c != sentinel:
                    seen.add(c)
                    if len(seen) >= MIN_COLOURS:
                        return True
        return False

    def drew_window(self, view, a, w, h):
        """The window read back. None (can't tell) on Wayland, where the read misses what WebKit draws with GL, so
        a working window would read as empty; and when there is nothing to read."""
        from gi.repository import Gdk
        disp = Gdk.Display.get_default()
        if disp is not None and "Wayland" in type(disp).__name__:
            return None
        win = view.get_window()
        if win is None:
            return None
        x0, y0 = (0, 0) if view.get_has_window() else (a.x, a.y)
        pb = Gdk.pixbuf_get_from_window(win, x0, y0, w, h)
        if pb is None:
            return None
        px, stride, n = pb.get_pixels(), pb.get_rowstride(), pb.get_n_channels()
        seen = set()
        for y in range(0, pb.get_height(), 9):
            for x in range(0, pb.get_width(), 9):
                i = y * stride + x * n
                seen.add(bytes(px[i:i + 3]))
                if len(seen) >= MIN_COLOURS:
                    return True
        return False

    def web_process_ended(self, view):
        """The page's web process ended (the shell's web-process-terminated): True if that is this file's to handle.
        Before the first check passed it is this mode failing (the beta 4 DMA-BUF crash ended every renderer)."""
        if self.browser_window is not None and self.browser_window is self.app.window:
            return True  # the browser page ended it on purpose
        if self.done or view is not self.view:
            return False
        self.done = True
        from gi.repository import GLib
        # From the main loop, not inside WebKit's signal: failed() may destroy the window and its view.
        GLib.idle_add(lambda: (self.failed("its web process ended before it drew"), False)[1])
        return True

    def showing_browser_page(self):
        return self.browser_window is not None and self.browser_window is self.app.window

    # ---- results

    def worked(self):
        global tried
        self.log(f"the window draws (mode {mode})")
        os.environ[TRIED] = ""
        tried = []
        if mode == "user":
            return
        st = load_state()
        if st.get("works") != mode or "failed" in st:
            st.pop("failed", None)
            st["works"] = mode
            save_state(st)
            self.log(f"remembered drawing mode {mode}")

    def failed(self, reason):
        if mode == "user":
            self.log(f"the window didn't draw ({reason}); WebKit's drawing was set by hand, so it stays as set")
            self.show_browser_page(False)
            return
        done = tried + [mode]
        nxt = next((m for m in ladder() if m not in done), None)
        if nxt is None:
            self.log(f"the window didn't draw ({reason}) in any drawing mode ({', '.join(done)}): showing the "
                     "browser page")
            st = load_state()
            st.pop("works", None)
            st["failed"] = webkit_version_string()
            save_state(st)
            # Start over, and the new process shows the browser page (watch: "last time"), rather than ending this
            # page's web process here: a web process hung before its first message made WebKit abort this process
            # when it was ended (g_error "failed to receive credentials", Flatpak aarch64 CI 2026-11-25).
            os.environ[TRIED] = ""
            apply(ladder()[0])
            route = self.app.pending_route
            self.restart(["--open", route] if route else [], failing=True)
            return
        self.log(f"the window didn't draw in mode {mode} ({reason}): trying the window again with mode {nxt}")
        apply(nxt)
        os.environ[TRIED] = ",".join(done)
        route = self.app.pending_route
        self.restart(["--open", route] if route else [], failing=True)

    def show_browser_page(self, after_all):
        """A page drawn by GTK (no web process) in place of the web view: open the vault in the browser."""
        from gi.repository import Gio, GLib, Gtk
        app, win = self.app, self.app.window
        if win is None:
            return
        app.page = "browser"
        app.crashed = True
        origin = app.origin() + "/"
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        box.set_valign(Gtk.Align.CENTER)
        box.set_halign(Gtk.Align.CENTER)
        title = Gtk.Label()
        title.set_markup("<span size='x-large' weight='bold'>This window can't draw on this computer</span>")
        body = Gtk.Label(label=("It tried every way WebKit can draw here and none showed anything.\n" if after_all
                                else "Its page didn't show anything.\n")
                         + "Your vault is running. Open it in your web browser at " + origin)
        body.set_justify(Gtk.Justification.CENTER)
        body.set_line_wrap(True)
        open_b = Gtk.Button(label="Open in browser")

        def open_browser(*_):
            try:
                Gio.AppInfo.launch_default_for_uri(origin, None)
            except GLib.Error as e:
                self.log("couldn't open the browser: " + e.message)

        open_b.connect("clicked", open_browser)
        again = Gtk.Button(label="Try the window again")
        again.connect("clicked", lambda *_: self.try_again())
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        buttons.set_halign(Gtk.Align.CENTER)
        buttons.pack_start(open_b, False, False, 0)
        buttons.pack_start(again, False, False, 0)
        for w in (title, body, buttons):
            box.pack_start(w, False, False, 0)
        child = win.get_child()
        if child is not None:
            win.remove(child)
            if child is getattr(app, "stopped", None):
                child.destroy()
                app.stopped = None
        win.add(box)
        box.show_all()
        self._browser = weakref.ref(win)
        if app.view is not None and hasattr(app.view, "terminate_web_process"):
            app.view.terminate_web_process()  # it draws nothing: don't leave it running (or hung) behind the page

    def try_again(self):
        """The browser page's button: forget what failed and start over from the first mode."""
        st = load_state()
        st.pop("failed", None)
        st.pop("works", None)
        save_state(st)
        for k in (OURS, TRIED, DMABUF, COMPOSITING):
            if mode != "user" or k in (OURS, TRIED):
                os.environ.pop(k, None)
        self.log("trying the window again from the first drawing mode")
        self.restart([])

    # ---- starting over

    def restart(self, args, failing=False):
        """Start this program over (exec, the same process id) with args, once every child of this process has
        ended, so none is left for nothing to reap (as restart_as_tray: WebKit's helpers, their bwrap sandboxes and
        xdg-dbus-proxy). Waits for a running setup or pkexec (their results need this process) and for a tick's
        systemctl. WebKit's own processes get KILL_AFTER_S, then are killed; every other child then gets WAIT_S.
        failing: the check failed, so the page may be hung (see below)."""
        from gi.repository import GLib
        if self.restarting:
            return
        self.restarting = True
        app = self.app
        win, view = app.window, app.view
        app.window = app.view = None
        app.stopped = None
        app.page = None
        self.view = None
        self.done = True
        # A healthy page's web process: ended through WebKit (inside a Flatpak the portal starts it, so descendants()
        # can't see it). app.view is None first, so the shell's web-process-terminated handler leaves it alone.
        # Not after a failed check: ending a web process that hung before its first message made WebKit abort this
        # process (g_error "failed to receive credentials", Flatpak aarch64 CI 2026-11-25). There the exec ends it:
        # its socket to this process closes on exec, and a web process exits on that from its IPC thread, even with
        # its main thread hung (a stopped one, as in the test, waits for its signals).
        if not failing and view is not None and hasattr(view, "terminate_web_process"):
            try:
                view.terminate_web_process()
            except Exception as e:  # noqa: BLE001 - logged; the restart goes on
                self.log("couldn't end the page's web process: " + repr(e))
        if win is not None:
            win.destroy()
        if self.supervisor is not None:
            self.supervisor.stop()
        began = time.monotonic()
        state = {}

        def step():
            if getattr(app, "setup_running", False) or getattr(app, "root_running", 0):
                return True
            if self.supervisor is not None and self.supervisor.proc is not None and time.monotonic() - began < 10:
                return True  # the Flatpak's havend, ending
            if getattr(app, "ticking", False):
                return True  # tick's thread may be inside systemctl: exec'd now, it would be a zombie
            web = [p for p, c, st in descendants(os.getpid()) if (c.startswith("WebKit") or c == "bwrap") and st != "Z"]
            if web and time.monotonic() - began < KILL_AFTER_S:
                return True
            for pid in web:
                try:
                    os.kill(pid, signal.SIGKILL)  # hung, or stopped: it won't end by itself
                except OSError:
                    pass
            if web:
                state["killed"] = time.monotonic()
                return True  # next step: the rest
            live = [p for p, _c, st in children() if st != "Z"]
            if live and time.monotonic() - state.get("killed", began) < WAIT_S:
                return True
            for pid, _c, _st in children():
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
            sys.stdout.flush()
            sys.stderr.flush()
            try:
                os.execv(sys.executable, [sys.executable, "-I", os.path.abspath(sys.argv[0])] + args)
            except OSError as e:
                self.log("couldn't start over: " + repr(e))
                self.restarting = False
            return False

        GLib.timeout_add(250, step)


def listen_for_update(checker):
    """SIGUSR2 (the .deb's postinst, after an update): start over on the new code, the window open if it was."""
    from gi.repository import GLib

    def got():
        checker.log("updated: starting over on the new version")
        checker.restart([] if checker.app.window is not None else ["--tray"])
        return True

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR2, got)
