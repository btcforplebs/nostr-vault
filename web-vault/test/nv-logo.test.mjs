// Settings › Posts › Hide Nostr Vault logo on posts (iPhone HavenConfig.hideNostrVaultBadge): off by default so the logo
// shows; Badges.jsx draws it only while it is not hidden; Settings has the switch.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { nvLogoHidden, setNvLogoHidden } from "../src/net/nv-logo.js"

const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("shown by default (never set); the switch hides and shows it again", () => {
  const s = store()
  assert.equal(nvLogoHidden(s), false)
  setNvLogoHidden(true, s)
  assert.equal(nvLogoHidden(s), true)
  setNvLogoHidden(false, s)
  assert.equal(nvLogoHidden(s), false)
  assert.equal(nvLogoHidden(undefined), false)
  assert.equal(nvLogoHidden({ getItem: () => { throw new Error("blocked") } }), false)
})

test("Badges draws the logo only when not hidden; Settings has the switch", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("components/Badges.jsx"), /\{fromNostrVault\(note\) && !nvLogoHidden\(\) && <span class="badge-nv"/)
  assert.match(src("screens/settings/AppearancePage.jsx"), /<Section label="Posts"><NostrVaultLogoSwitch \/><\/Section>/)
})
