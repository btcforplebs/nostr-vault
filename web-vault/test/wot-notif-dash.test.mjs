// Parity #7 (your web as a list), #31 (Notifications: its own route and entry points), #30 (Dashboard Cache, and why
// Start/Stop and Import media aren't here, on the page).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { listPeople, rowLine, LIST_PAGE } from "../src/screens/wot-list.js"
import { sideOf, SPLIT } from "../src/desktop/routes.js"
import { RAIL_SECTIONS, shownPins, defaultPins } from "../src/desktop/rail/rail-favs.js"
import { wotStore } from "../src/net/wot-store.js"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const pk = c => c.repeat(64)

test("#7 the list: the layer's people in the globe's order, most linked first, through the Follow you back filter", () => {
  const web = { follows: [pk("1"), pk("2")], extended: [pk("3")], further: [pk("4"), pk("5")],
    linkers: new Map([[pk("2"), [1, 2]], [pk("3"), Array(12)], [pk("5"), [1]]]) }
  assert.deepEqual(listPeople(web).map(p => p.pk[0]), ["2", "1", "3", "5", "4"])
  assert.deepEqual(listPeople(web, "close").map(p => p.layer), ["extended"])
  assert.deepEqual(listPeople(web, "following", new Set([pk("1")])).map(p => p.pk[0]), ["1"])
  assert.equal(rowLine({ layer: "extended", links: 12 }), "Vouched · followed by 12 you follow")
  assert.equal(rowLine({ layer: "follow", links: 0 }), "You follow them")
  assert.deepEqual(listPeople(null), [])
  assert.equal(LIST_PAGE, 100)
  assert.match(src("screens/WotTopBar.jsx"), /aria-label="See your web as a list"/)
  assert.match(src("screens/WotScreen.jsx"), /onPick=\{pk => \{ setListOpen\(false\); setPicked\(pk\); setCentre\(pk\) \}\}/, "a row opens their card on the globe")
})

test("#31 Notifications: its own rail row and lit item on desktop, a Vault page on a phone", () => {
  assert.equal(sideOf("notifications"), "notifications")
  assert.ok(SPLIT.has("notifications"))
  assert.ok(RAIL_SECTIONS.includes("notifications"))
  assert.ok(shownPins(defaultPins()).some(p => p.id === "notifications"), "on the default rail")
  assert.match(src("desktop/icons.jsx"), /notifications: "M6 16V11/)
  assert.match(src("screens/VaultPagesMenu.jsx"), /NOTIFICATIONS_PAGE = \{ id: "notifications", title: "Notifications", href: "#\/notifications" \}/)
  assert.match(readFileSync(new URL("../main.jsx", import.meta.url), "utf8"), /\{route === "notifications" && <NotificationsScreen ctx=\{ctx\} vaultMenu \/>\}/)
  assert.match(src("screens/NotificationsScreen.jsx"), /vaultMenu \? <><VaultPagesMenu ctx=\{ctx\} current="notifications" \/>/)
})

test("#30 Cache: the phone's words where they fit the web, a count, Clear asks first; Start/Stop and Import media said on the page", async () => {
  const cache = src("components/dashboard/CacheRow.jsx")
  const swift = readFileSync(new URL("../../HavenApp/HavenApp/Views/Dashboard/VaultContentsSection.swift", import.meta.url), "utf8")
  assert.ok(swift.includes('"Clear the cache?"') && cache.includes('"Clear the cache?"'))
  assert.match(cache, /They download again when needed\./); assert.ok(swift.includes("They download again when needed."))
  assert.match(cache, /<RowButton title="Clear cache"/); assert.ok(swift.includes('RowButton(title: "Clear cache"'))
  assert.match(src("components/dashboard/ContentsSection.jsx"), /\{me && <CacheRow me=\{me\} \/>\}/)
  const none = wotStore(null)
  assert.equal(await none.count(), 0); await none.clear()
  assert.match(src("net/wot-store.js"), /store\.clear\(\); meta\.clear\(\)/)
  assert.match(src("components/dashboard/StatusCard.jsx"), /<span class="dash-sub">\{NO_START_STOP\}<\/span>/)
  assert.match(src("components/dashboard/StatusCard.jsx"), /no Start or Stop here/)
})
