// A user's lists are never overwritten by accident (Logen 2026-10-31): kind 0, 3, 10000, 10002, 10006, 10015, 10050
// and 10063 are signed only from the places listed here. A new file that signs anything, a list template in a file
// that signs, or a new publishList call fails this test until someone reviews it and adds it. Paths from Tron's audit
// at 633d5552 (RESEARCH/NV_LIST_OVERWRITE_AUDIT_633D5552.md). Twins: Android UserListSignGuardTest.kt, iOS/Mac
// UserListSignGuardTests.swift.
//
// The three "list safety" tests at the end were the audit's web live paths, skipped until fixed; they run now
// (fixed by "Web list safety": refuse to save when relays don't answer, re-read the list at Save).
import test from "node:test"
import assert from "node:assert/strict"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join, relative } from "node:path"
import { fileURLToPath } from "node:url"

const here = fileURLToPath(new URL(".", import.meta.url))
const pkg = join(here, "..")
const LIST_KINDS = new Set(["0", "3", "10000", "10002", "10006", "10015", "10050", "10063"])

const walk = dir => readdirSync(dir).flatMap(n => { const p = join(dir, n); return statSync(p).isDirectory() ? walk(p) : /\.(js|jsx|mjs)$/.test(n) ? [p] : [] })
/** Every web source (the vault app and the relay page), whitespace collapsed, keyed by path from web-vault/. */
const sources = Object.fromEntries([join(pkg, "src"), join(pkg, "../web-relay/src")]
  .flatMap(walk).map(p => [relative(pkg, p), readFileSync(p, "utf8").replace(/\s+/g, " ")]))

const signs = s => /\.signEvent\(|\bsignEvent: /.test(s)
const listKindsIn = s => [...new Set([...s.matchAll(/\bkind: (\d+)\b/g)].map(m => m[1]).filter(k => LIST_KINDS.has(k)))].sort((a, b) => a - b)
const publishListArgs = s => [...s.matchAll(/(?<!function )\bpublishList\(\s*ctx\s*,\s*([A-Za-z0-9_.]+)/g)].map(m => m[1])

function scan() {
  const signers = [], lists = {}, publishes = {}
  for (const [path, s] of Object.entries(sources).sort(([a], [b]) => a.localeCompare(b))) {
    if (signs(s)) { signers.push(path); const k = listKindsIn(s); if (k.length) lists[path] = k }
    const p = publishListArgs(s); if (p.length) publishes[path] = [...new Set(p)].sort()
  }
  return { signers, lists, publishes }
}

test("the pattern catches every way a list is signed", () => {
  assert.ok(Object.keys(sources).length > 100, "the sources were found")
  assert.ok(signs("checkSigned(await ctx.signer.signEvent(template), template, me)"))
  assert.deepEqual(listKindsIn("const template = { kind: 3, created_at: 1, tags }; { kind: 10063 } { kind: 1 } { kind: 30023 }"), ["3", "10063"])
  assert.deepEqual(publishListArgs("await publishList(ctx, 10002, tags) export async function publishList(ctx, kind, tags"), ["10002"])
})

test("only these files sign anything", () => {
  // A new one could sign a list; review it, then add it here.
  assert.deepEqual(scan().signers, [
    "src/box/api.js", "src/box/box-vault.js", "src/guest/guest.js", "src/net/actions.js", "src/net/blocks.js",
    "src/net/blossom-gallery.js", "src/net/dms.js", "src/net/follow-backup.js", "src/net/follows.js",
    "src/net/list-edit.js", "src/net/new-account.js", "src/net/profile-edit.js", "src/net/reports.js",
    "src/net/sync.js", "src/net/upload.js", "src/net/zaps.js", "src/readers/LiveChat.jsx", "src/signer/local.js",
    "src/signer/nip07.js", "src/signer/nip46.js", "src/signer/readonly.js",
  ])
})

test("only these places sign a user list", () => {
  const { lists, publishes } = scan()
  assert.deepEqual(lists, {
    "src/net/blocks.js": ["10000"],                          // Block / unblock tap
    "src/net/follow-backup.js": ["3"],                       // Restore a follow backup (tap)
    "src/net/follows.js": ["3"],                             // Follow / unfollow tap (wipeGuard)
    "src/net/new-account.js": ["0", "3", "10002", "10050"],  // A new account: no list exists yet
    "src/net/profile-edit.js": ["0"],                        // Save in Edit profile
  })
  // list-edit.js publishList: Save on these pages only. RelayUrlList is handed its kind (10050 DMs, 10006).
  assert.deepEqual(publishes, {
    "src/screens/MediaServersPage.jsx": ["10063"],
    "src/screens/RelayUrlList.jsx": ["kind"],
    "src/screens/RelaysPage.jsx": ["10002"],
  })
})

// ---- List safety (Tron audit 633d5552 web live paths, fixed; these were skipped until then). ----

const known = (line, name, fn) => test(`${name} (${line})`, fn)
const fn = (path, name) => sources[path].split(`function ${name}`)[1]?.split(/ export (async )?function /)[0] ?? ""

known("was ⚠️ Tron 633d5552: latestList said checked:true when every relay failed",
  "an edit is 'checked' only when a relay answered", () => {
    assert.ok(fn("src/net/list-edit.js", "latestList"))
    assert.doesNotMatch(fn("src/net/list-edit.js", "latestList"), /return \{ event: best, checked: true \}/)
  })

known("was ⚠️ Tron 633d5552: Media servers started an edit from the defaults when no list was found",
  "Media servers never starts an edit from the defaults", () => {
    assert.doesNotMatch(sources["src/screens/MediaServersPage.jsx"], /ev \? serverEntries\(ev\) : DEFAULT_MEDIA_SERVERS/)
  })

known("was 🔵 Tron 633d5552: publishList signed over the copy read when the page opened (10002/10050/10006/10063)",
  "Save reads the newest list before signing", () => {
    const publish = fn("src/net/list-edit.js", "publishList")
    assert.match(publish, /ctx\.signer\.signEvent\(template\)/, "found publishList")
    assert.match(publish, /latestList\(/)
  })
