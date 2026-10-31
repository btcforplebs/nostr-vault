// Profile polish against the iPhone (ShareProfileSheet, ProfileContent+Header, FeedProfileCard): Share with a QR of the
// nostrvault.app/p/<npub> page on both profiles. Source checks where the screens need a signed-in app around them.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { decode } from "nostr-tools/nip19"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { profileLink } = await import("../src/components/ShareProfile.jsx")
const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const PK = "a".repeat(64)

test("the shared link is the person's nostrvault.app/p/<npub> page", () => {
  const link = profileLink(PK)
  assert.match(link, /^https:\/\/nostrvault\.app\/p\/npub1/)
  assert.equal(decode(link.split("/p/")[1]).data, PK)
})

test("Share is on your own profile and beside the ••• on anyone else's; the sheet has QR, Copy link, Share", () => {
  assert.match(src("screens/ProfileScreen.jsx"), /<ShareProfileButton pubkey=\{me\} own \/>/)
  assert.match(src("screens/PersonScreen.jsx"), /<ShareProfileButton pubkey=\{pubkey\} \/>\n\s*<MoreMenu/)
  const sheet = src("components/ShareProfile.jsx")
  assert.match(sheet, /<QrCode text=\{link\}/)
  assert.match(sheet, /Copy link/)
  assert.match(sheet, /navigator\.share\(/)
})

test("Follow changes at once, toasts once the list is out, and a tap while your list loads waits for it", () => {
  const s = src("screens/PersonScreen.jsx")
  assert.match(s, /const shown = want \?\? iFollow/)
  assert.match(s, /class=\{shown \? "follow-btn on" : "follow-btn"\} disabled=\{busy \|\| ctx\.signer\?\.readOnly\}/, "not disabled while the list loads")
  assert.match(s, /if \(account\.loaded\) run\(follow\)/)
  assert.match(s, /useEffect\(\(\) => \{ if \(account\.loaded && want != null && !busy\) run\(want\) \}, \[account\.loaded\]\)/)
  assert.match(s, /setToast\(follow \? `Following \$\{name\}` : `Unfollowed \$\{name\}`\)/)
  assert.match(s, /finally \{ setBusy\(false\); setWant\(null\) \}/, "a failed follow goes back to what your list says")
})
