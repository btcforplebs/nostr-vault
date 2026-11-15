// Your space's icon rail (src/desktop/space/SpaceDock.jsx, Logen 2026-11-04, the iPad's SpaceColumn.swift): always on
// the right edge, folded or not; the dashboard on top, then one icon per shown panel; a click opens just that panel.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
const dock = src("desktop/space/SpaceDock.jsx")

test("folded, the dock is the rail alone; open, the rail sits after the panels", () => {
  assert.match(dock, /if \(folded\) return <aside class="space-dock folded" aria-label="Your space">\{rail\}<\/aside>/)
  assert.ok(dock.indexOf("</div>\n      {rail}\n    </aside>") > 0, "open: the rail is the last thing in the dock")
})

test("the rail: dashboard first, then one icon per shown panel, each with an icon", () => {
  assert.match(dock, /<RailButton d=\{DASHBOARD\} title="Your space" open=\{!folded && !single\} onClick=\{\(\) => tap\(null\)\} \/>/)
  assert.match(dock, /\{shown\.map\(\(\{ id \}\) => \(\s*<RailButton key=\{id\}/)
  const { PANEL_IDS } = { PANEL_IDS: ["live-vault", "wot-mini", "messages", "my-devices", "live-now", "on-this-day"] }
  // The glyphs moved to card-icons.js (plan step 4: the widget cards' headers draw the same ones).
  assert.match(dock, /const RAIL_ICON = CARD_ICON/)
  const icons = src("desktop/space/card-icons.js")
  for (const id of PANEL_IDS) assert.match(icons, new RegExp(`"?${id}"?: `), `${id} has a rail icon`)
})

test("a click: folded opens on it, the open one folds, another switches", () => {
  assert.match(dock, /if \(folded\) \{ setOnly\(id\); onFold\(false\) \}\s*else if \(single === id\) onFold\(true\)\s*else \{ setOnly\(id\); onEdit\(false\) \}/)
  assert.match(dock, /: Only \? <Only\.Panel ctx=\{ctx\} open tools=\{null\} \/>/, "one panel alone, open")
  assert.match(dock, /isWidget\(single\) \? <WidgetCard ctx=\{ctx\} id=\{single\} name=\{onlyName\} open editing=\{false\} tools=\{null\} side=\{RIGHT\} full \/>/, "napplets on: its widget, full height")
  assert.match(src("styles/space.css"), /\.sp-panels\.sp-only > \.sp-panel \{ flex: 1; max-height: none; \}/, "full height")
})

test("the open dock makes room for the rail", () => {
  assert.match(src("styles/desktop.css"), /\.desk-app:has\(\.desk\.space\) \{ --dock-w: 436px; \}/)
  assert.match(src("styles/desktop.css"), /\.desk-app:has\(\.desk\.space\.folded\) \{ --dock-w: 56px; \}/)
})
