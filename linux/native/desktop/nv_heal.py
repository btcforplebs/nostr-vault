"""Nostr Vault for Linux: the window gets itself out of two traps, a page that never answers and old WebKit processes.

A page whose JavaScript never answers (its web process at 100% CPU, making no system calls: a pure script or engine
spin, Guy's window, 2026-11-27) is not a drawing problem. A new drawing mode loads the same copy of the web app from
WebKit's cache, and it spins again. So the first time a page never answers (nv_paint.Checker.failed), before it tries
another drawing mode, the window moves WebKit's cache aside and starts over, and the web app is fetched fresh from the
vault (reset_cache):
  - What moves: everything in ~/.cache/nostr-vault-desktop except window.log (WebKit's HTTP cache, the service
    worker's CacheStorage, HSTS), plus the service worker registrations in ~/.local/share/nostr-vault-desktop
    (serviceworkers: the stored sw.js and its scope). Into ~/.cache/nostr-vault-desktop.bak-<time>, kept (the newest 3).
  - What never moves: localStorage (nv-session and nv-accounts: every sign-in, and a key made in this window, kept as
    an ncryptsec), IndexedDB (the keyring that seals it, the web app's stores) and cookies.sqlite. Moving any of
    those signs people out, or loses a key nobody saved (web-vault/src/session.js, signer/local.js, signer/keyring.js).
  - At most once a day (renderer.json's cache_reset), and once per start-over chain (NV_DESKTOP_CACHE_RESET), so a
    spin that comes from saved data goes on down the drawing ladder to the browser page, as before.
The move happens in the new process, before WebKit loads (pending_reset, from nv_paint.choose()): nothing of this
process has the cache open then. A WebKit process left from before the exec that still writes, writes into the .bak.

A page that still never answers after the fresh cache (the safe start, pending_safe): the web app's saved data may
be what spins it (a feed store it reads at start). Once (a day, and a chain), the window starts over with the web app's
refillable IndexedDB caches moved aside, and nothing else:
  - When: only after a fresh cache, and only where a GPU or sandbox hang is ruled out (it gives the same "never
    answered" signal, and the drawing ladder is for that): this drawing mode drew before (renderer.json's works), or
    every drawing mode failed too (nv_paint.Checker.failed). Tron, PR 2653 review. And only when there is something
    to move (movable): a hung web process with no saved caches (the blank stage, the setup page) goes straight on.
  - Moved: only the databases MOVE_DBS names, the caches the vault and the relays fill again: haven:<pk>:feed,
    inbox, private, chat, lists, blossom and wotlists, and nv-napplet-apps:<pk> (installed apps' pages, by hash:
    fetched again only while the app's server is up; until then, the copy in the .safe folder is the one there is).
    Each database's folder as it is, into <data>.safe-<time> under the same path, which is kept. Nothing is deleted
    or written over: a fresh folder, os.rename (one file system).
  - Kept in place, everything else: localStorage (nv-session, nv-accounts, a key's ncryptsec, the device key, paired
    vaults), cookies.sqlite, nv-keyring (the key that seals the ncryptsec, signer/keyring.js), and every database
    that may be the only copy: each account's wallet (an NWC secret), drafts (unsent), deleted (Un-delete copies:
    the kind 5 is out), followbackup (the undo of an unfollow), outbox, blobs and listsimport, nv-napplets:<pk>
    (napplet storage), /relay/'s haven:relay:..., a store added later, and a database whose name can't be read.
    A list of what may move, not of what stays: a new store is kept until someone adds it here.
  - Before WebKit loads (pending_safe, from nv_paint.choose()), as the cache move. A database that can't be moved
    stays where it is and the rest still move; the log names each one moved, and each one that couldn't be.

Stray WebKit processes (reap_strays): a web process that outlived its window (two sandboxed ones, 3 days old, at
99.9% CPU on Guy's machine, under a bwrap whose window was long gone) holds CPU and memory forever. Every start of the
window ends each one that is ours and that no running window owns, with its whole process tree:
  - ours: this user's, named WebKit* (or bwrap / xdg-dbus-proxy, WebKit's sandbox), with NV_DESKTOP_RENDERER in its
    environment (set by nv_paint.choose() and inherited by everything WebKit starts). Another app's WebKit (a browser,
    a mail client) has no such variable and is never touched.
  - owned: one of its ancestors is this process (those are nv_paint's leftovers, reaped there) or another window,
    still running: a process whose command line runs this program (nostr-vault-desktop, by its shebang or as
    python3 -I .../nostr-vault-desktop after starting over). Not by its command name: a window started by its
    shebang is named "nostr-vault-des", not python (Tron, PR 2622 review). Nor by the variable: choose() sets it
    after the exec, so /proc/<pid>/environ of a window started from the launcher doesn't show it.
  - Only the primary instance reaps (Checker.startup, from do_startup): a second launch (the launcher, the tray, an
    --open link) hands off to the running window over D-Bus and exits; it never reaps.
  - Nothing this window starts carries the variable (launch_uri, child_env): another WebKit app opened from a link
    (a mail client, a WebKit browser) would otherwise be "ours" and be ended once our window had gone.
SIGTERM, then SIGKILL after STRAY_TERM_S. (A web process of this process's own WebKit is never killed here: one that
hadn't finished its handshake made WebKit abort the window, see nv_paint.reap_leftovers. Strays have no window.)
"""
import os
import re
import shutil
import sqlite3
import signal
import time

RESET = "NV_DESKTOP_CACHE_RESET"  # "pending": move the cache aside before WebKit loads; "done": this chain did
RESET_EVERY_S = 24 * 3600
KEEP = ("window.log",)  # this app's own files in the cache folder; the rest is WebKit's
SW_DIR = "serviceworkers"  # WebKit's service worker registrations, in the data folder
STRAY_TERM_S = 2
SANDBOX = ("bwrap", "xdg-dbus-proxy")
MARK = b"NV_DESKTOP_RENDERER="
# The window's own variables, never handed to what it starts: the marker, the start-over chain's, and the drawing
# mode's (WebKit's, set by nv_paint.set_mode; another app's WebKit must draw its own way).
OWN_VARS = ("NV_DESKTOP_RENDERER", "NV_DESKTOP_TRIED", RESET, "NV_DESKTOP_SAFE_START",
            "WEBKIT_DISABLE_DMABUF_RENDERER", "WEBKIT_DISABLE_COMPOSITING_MODE")
PROGRAM = "nostr-vault-desktop"
SAFE = "NV_DESKTOP_SAFE_START"  # "pending": move the saved data aside before WebKit loads; "done": this chain did
IDB_FILE = "IndexedDB.sqlite3"  # one per database, in its own folder (with its -wal, -shm and blob files)
# The only databases a safe start moves: caches the vault, the relays or an app's server fill again. Everything else
# stays (see the top of this file).
MOVE_DBS = re.compile(r"haven:[0-9a-f]{64}:(feed|inbox|private|chat|lists|blossom|wotlists)|nv-napplet-apps:[0-9a-f]{64}")
KEEP_BAKS = 3  # reset_cache keeps the newest this many old caches (at most one a day), and deletes the rest

note = ""  # what pending_reset did, for the log (it runs before the log is set up)


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "nostr-vault-desktop")


def data_dir():
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "nostr-vault-desktop")


# ---- a page that never answers: a fresh cache

def may_reset(state):
    """The page never answered: may this chain move the cache aside now? (Not twice in a chain, nor within a day.)"""
    if os.environ.get(RESET):
        return False
    last = state.get("cache_reset")
    return not (isinstance(last, (int, float)) and 0 <= time.time() - last < RESET_EVERY_S)


def ask_reset(state):
    """Before the window starts over: the next process moves the cache aside first (pending_reset). state is
    renderer.json's dict, saved by the caller."""
    os.environ[RESET] = "pending"
    state["cache_reset"] = int(time.time())


def pending_reset():
    """In nv_paint.choose(), before WebKit loads: do the move a failed check asked for (ask_reset)."""
    global note
    if os.environ.get(RESET) != "pending":
        return
    os.environ[RESET] = "done"
    try:
        bak, moved = reset_cache()
        note = (f"moved WebKit's cache aside ({', '.join(moved)}) to {bak}; sign-ins, localStorage, IndexedDB and "
                "cookies kept") if moved else "no WebKit cache to move aside"
    except OSError as e:
        note = "couldn't move WebKit's cache aside: " + repr(e)


def reset_cache():
    """Moves WebKit's cache and service worker registrations into <cache>.bak-<time> -> (that folder, names moved)."""
    src, bak = cache_dir(), cache_dir() + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    n = 1
    while os.path.exists(bak):
        n += 1
        bak = cache_dir() + ".bak-" + time.strftime("%Y%m%d-%H%M%S") + f"-{n}"
    moved = []
    names = sorted(os.listdir(src)) if os.path.isdir(src) else []
    for name in names:
        if name in KEEP:
            continue
        os.makedirs(bak, exist_ok=True)
        os.rename(os.path.join(src, name), os.path.join(bak, name))  # the same folder's parent: one file system
        moved.append(name)
    sw = os.path.join(data_dir(), SW_DIR)
    if os.path.isdir(sw):
        os.makedirs(bak, exist_ok=True)
        shutil.move(sw, os.path.join(bak, SW_DIR))  # ~/.local/share may be another file system than ~/.cache
        moved.append(SW_DIR)
    prune_baks()
    return bak, moved


def prune_baks():
    """Deletes all but the newest KEEP_BAKS <cache>.bak-* folders (by name: their time, sortable)."""
    parent, prefix = os.path.dirname(cache_dir()), os.path.basename(cache_dir()) + ".bak-"
    try:
        baks = sorted(n for n in os.listdir(parent) if n.startswith(prefix))
    except OSError:
        return
    for n in baks[:-KEEP_BAKS]:
        shutil.rmtree(os.path.join(parent, n), ignore_errors=True)


# ---- a page that never answers even then: a safe start, its saved data moved aside

def may_safe(state):
    """The page never answered after a fresh cache (this chain's, or one within a day): may it start safe now?"""
    if os.environ.get(SAFE) or (os.environ.get(RESET) != "done" and may_reset(state)):
        return False
    last = state.get("safe_start")
    if isinstance(last, (int, float)) and 0 <= time.time() - last < RESET_EVERY_S:
        return False
    return movable()  # nothing to move aside: starting over would only cost the ladder time


def _dbs():
    """Each IndexedDB database under the data folder: (its folder, its name or None)."""
    for root, dirs, files in os.walk(data_dir()):
        if IDB_FILE in files:
            dirs[:] = []  # a database's own folder: nothing below it is another database
            yield root, db_name(os.path.join(root, IDB_FILE))


def movable():
    """Is there a database a safe start would move (MOVE_DBS)? Read-only, as safe_start reads the names."""
    return any(name is not None and MOVE_DBS.fullmatch(name) for _root, name in _dbs())


def ask_safe(state):
    os.environ[SAFE] = "pending"
    state["safe_start"] = int(time.time())


def pending_safe():
    """In nv_paint.choose(), before WebKit loads: do the move a failed check asked for (ask_safe)."""
    global note
    if os.environ.get(SAFE) != "pending":
        return
    os.environ[SAFE] = "done"
    try:
        bak, moved, kept, failed = safe_start()
    except OSError as e:  # its folder couldn't be listed: nothing moved
        note = "couldn't move the saved data aside: " + repr(e)
        return
    note = ((f"safe start: moved {len(moved)} saved database(s) aside to {bak}: {', '.join(moved)}" if moved
             else "safe start: no saved database to move aside")
            + (f"; couldn't move (left in place): {'; '.join(failed)}" if failed else "")
            + f"; kept in place: localStorage, cookies and {', '.join(kept) or 'no other database'}")


def db_name(path):
    """The name a page gave the IndexedDB database in path (WebKit's IDBDatabaseInfo), or None if it can't be read."""
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1)
        try:
            row = con.execute("SELECT value FROM IDBDatabaseInfo WHERE key = 'DatabaseName'").fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    v = row[0] if row else None
    if isinstance(v, bytes):  # WebKit keeps it as UTF-16 (little-endian), a blob
        try:
            v = v.decode("utf-16-le")
        except UnicodeDecodeError:
            return None
    return v if isinstance(v, str) else None


def safe_start():
    """Moves every IndexedDB database MOVE_DBS names into <data>.safe-<time> -> (that folder, moved, kept, failed:
    "<name> (<error>)" for each one that couldn't be moved, left in place)."""
    src = data_dir()
    bak, n = src + ".safe-" + time.strftime("%Y%m%d-%H%M%S"), 1
    while os.path.exists(bak):
        n += 1
        bak = src + ".safe-" + time.strftime("%Y%m%d-%H%M%S") + f"-{n}"
    moved, kept, failed = [], [], []
    for root, name in list(_dbs()):  # the whole list first: nothing is walked after it moved
        if name is None or not MOVE_DBS.fullmatch(name):
            kept.append(name or os.path.relpath(root, src) + " (unread)")
            continue
        to = os.path.join(bak, os.path.relpath(root, src))
        try:
            os.makedirs(os.path.dirname(to), exist_ok=True)
            os.rename(root, to)  # bak is new, so this never writes over anything; same parent: one file system
        except OSError as e:
            failed.append(f"{name} ({e})")
            continue
        moved.append(name)
    return bak, sorted(moved), sorted(kept), failed


# ---- what the window starts: without its own variables

def child_env(env=None):
    """A copy of env (default: this process's) without OWN_VARS, for a process this window starts."""
    env = dict(os.environ if env is None else env)
    for k in OWN_VARS:
        env.pop(k, None)
    return env


def launch_context():
    """A Gio.AppLaunchContext that leaves OWN_VARS out of what it launches."""
    from gi.repository import Gio
    ctx = Gio.AppLaunchContext()
    for k in OWN_VARS:
        ctx.unsetenv(k)
    return ctx


def launch_uri(uri):
    """Gio.AppInfo.launch_default_for_uri, without OWN_VARS (raises GLib.Error as it does)."""
    from gi.repository import Gio
    return Gio.AppInfo.launch_default_for_uri(uri, launch_context())


# ---- stray WebKit processes

def _procs():
    """This user's processes: pid -> (parent pid, command name)."""
    uid, out = os.getuid(), {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if os.stat(f"/proc/{p}").st_uid != uid:
                continue
            with open(f"/proc/{p}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
            with open(f"/proc/{p}/comm") as f:
                comm = f.read().strip()
        except (OSError, IndexError):
            continue
        if fields[0] != "Z":
            out[int(p)] = (int(fields[1]), comm)
    return out


def _marked(pid):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            return (b"\0" + MARK) in (b"\0" + f.read())
    except OSError:
        return False


def _window(pid):
    """pid runs this program: one of its first three arguments (python3 [-I] <script>, or the shebang's) is it."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            args = f.read().split(b"\0")[:3]
    except OSError:
        return False
    return any(os.path.basename(a) == PROGRAM.encode() for a in args)


def _web(comm):
    return comm.startswith("WebKit") or comm in SANDBOX


def _owned(pid, procs):
    """An ancestor of pid is this process, or another running window (this program)."""
    me, seen, p = os.getpid(), set(), procs.get(pid, (0, ""))[0]
    while p > 1 and p not in seen:
        seen.add(p)
        if p == me:
            return True
        if p not in procs:
            return False  # another user's (or gone): not a window of ours
        if _window(p):
            return True
        p = procs[p][0]
    return False


def strays():
    """Roots of the stray trees: [(pid, command name, every pid in its tree)]."""
    procs = _procs()
    stray = {p for p, (_pp, c) in procs.items() if _web(c) and _marked(p) and not _owned(p, procs)}
    kids = {}
    for p, (pp, _c) in procs.items():
        kids.setdefault(pp, []).append(p)
    out = []
    for root in sorted(p for p in stray if procs[p][0] not in stray):
        tree, todo = [], [root]
        while todo:
            q = todo.pop()
            tree.append(q)
            todo.extend(kids.get(q, []))
        out.append((root, procs[root][1], tree))
    return out


def reap_strays(log):
    """Ends every stray WebKit tree (see the top of this file) -> how many processes it ended."""
    found = strays()
    if not found:
        return 0
    tree = [p for _r, _c, t in found for p in t]
    log(f"ending {len(found)} stray WebKit process tree(s) no window owns ({len(tree)} processes: "
        + ", ".join(f"{c} {r}" for r, c, _t in found) + ")")
    for p in tree:
        try:
            os.kill(p, signal.SIGTERM)
            os.kill(p, signal.SIGCONT)  # a stopped one handles its SIGTERM only once it runs
        except OSError:
            pass
    end = time.monotonic() + STRAY_TERM_S
    while time.monotonic() < end and any(_alive(p) for p in tree):
        time.sleep(0.1)
    left = [p for p in tree if _alive(p)]
    for p in left:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass
    if left:
        log(f"{len(left)} of them didn't end on SIGTERM within {STRAY_TERM_S} s: killed")
    return len(tree)


def _alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False
