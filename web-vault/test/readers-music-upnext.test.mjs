// Up Next against the iPhone's NowPlayingView: the songs after this one with their places, Shuffled, a tap plays that
// song now, and the empty wording follows repeat.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { element, playList, playerState, current, jump, upNext, cycleRepeat, toggleShuffle, resetPlayer } from "../src/readers/player.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
function fakeAudio() { const on = {}; return { paused: true, currentTime: 0, src: "", addEventListener: (k, f) => { on[k] = f }, removeAttribute() {}, play() { this.paused = false; on.play?.(); return Promise.resolve() }, pause() { this.paused = true; on.pause?.() } } }
const song = id => ({ id, title: `T${id}`, artist: "A", mediaUrl: `https://c/${id}.mp3`, duration: 60 })
const list = ["1", "2", "3", "4"].map(song)
const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(x => walk(x, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
const { UpNext } = await import("../src/readers/UpNext.jsx")
const text = n => walk(n).filter(x => typeof x === "string").join(" ")

test("Up Next lists the songs after this one; a tap plays that song now", () => {
  resetPlayer(); element(fakeAudio)
  playList(list, 1)
  assert.deepEqual(upNext().map(u => [u.track.id, u.position]), [["3", 2], ["4", 3]])
  const nodes = walk(UpNext({ state: playerState() }))
  const buttons = nodes.filter(n => n.type === "button")
  assert.equal(buttons.length, 2)
  buttons[1].props.onClick()
  assert.equal(current().id, "4")
  jump(3)
  assert.equal(current().id, "4", "jumping to the song playing does nothing")
  jump(99)
  assert.equal(current().id, "4")
})

test("empty Up Next says so, or that the queue starts over under repeat all; Shuffled shows", () => {
  resetPlayer(); element(fakeAudio)
  playList(list, 3)
  assert.match(text(UpNext({ state: playerState() })), /Nothing after this song\./)
  cycleRepeat()
  assert.match(text(UpNext({ state: playerState() })), /The queue starts over after this song\./)
  playList(list, 0)
  toggleShuffle()
  assert.match(text(UpNext({ state: playerState() })), /Shuffled/)
  resetPlayer()
})

test("the bar has an Up Next button that shows the queue", () => {
  const src = readFileSync(new URL("../src/readers/PlayerBar.jsx", import.meta.url), "utf8")
  assert.match(src, /aria-label="Up Next"/)
  assert.match(src, /\{queue && <UpNext state=\{s\} \/>\}/)
})
