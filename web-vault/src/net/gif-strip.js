// A GIF with nothing in it but its picture (DM privacy, Tron 2026-11-14). A GIF can carry comments, XMP (where and with
// what it was made), ICC and Photoshop blocks and plain-text captions, all of which a redraw would lose but would also
// lose the animation. So it is rebuilt block by block instead: header, screen and colour table, each frame with its
// graphic control (delay, transparency) and the NETSCAPE loop count, rewritten from the number alone. Everything else,
// and anything after the trailer, is left behind. A GIF that doesn't parse to the end is refused, never sent as it is.

const bad = () => new Error("not a whole GIF")

/** -> the GIF's bytes with only its frames, their timing and its loop count. Throws when it isn't a whole GIF. */
export function stripGif(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  const sig = String.fromCharCode(...b.subarray(0, 6))
  if (sig !== "GIF87a" && sig !== "GIF89a") throw bad()
  let i = 13
  if (b.length < i) throw bad()
  if (b[10] & 0x80) i += 3 * (1 << ((b[10] & 7) + 1)) // global colour table
  if (b.length < i) throw bad()
  const out = [b.subarray(0, i)]
  // Sub-blocks from `at`: -> the index after the 0 terminator, and with `keep`, the first `keep` data bytes (only the
  // loop block needs any). Frame bytes are never copied: a 50 MB GIF as a JS array was 1.5 GB (Tron, #2075 review).
  const blocks = (at, keep = 0) => {
    const data = []
    for (;;) {
      if (at >= b.length) throw bad()
      const n = b[at++]
      if (n === 0) return { end: at, data }
      if (at + n > b.length) throw bad()
      for (let k = 0; k < n && data.length < keep; k++) data.push(b[at + k])
      at += n
    }
  }
  let control = null // a graphic control waits for what it controls: a frame keeps it, a dropped text block takes it along
  let looped = false, frames = 0
  for (;;) {
    if (i >= b.length) throw bad()
    const kind = b[i]
    if (kind === 0x3b) { out.push(Uint8Array.of(0x3b)); break }
    if (kind === 0x2c) {
      if (i + 10 > b.length) throw bad()
      let at = i + 10
      if (b[i + 9] & 0x80) at += 3 * (1 << ((b[i + 9] & 7) + 1)) // local colour table
      at += 1 // LZW minimum code size
      if (at > b.length) throw bad()
      const { end } = blocks(at)
      if (control) out.push(control)
      control = null
      out.push(b.subarray(i, end))
      frames++
      i = end
      continue
    }
    if (kind !== 0x21 || i + 2 > b.length) throw bad()
    const label = b[i + 1]
    const { end, data } = blocks(i + 2, label === 0xff ? 14 : 0)
    if (label === 0xf9) {
      if (end - i !== 8 || b[i + 2] !== 4) throw bad()
      control = b.subarray(i, end)
    } else if (label === 0x01) {
      control = null // plain text: dropped, and its timing with it
    } else if (label === 0xff && !looped && data.length >= 14) {
      const id = String.fromCharCode(...data.slice(0, 11))
      // The loop block: its first sub-block is 3 bytes, [1, loops lo, loops hi].
      if ((id === "NETSCAPE2.0" || id === "ANIMEXTS1.0") && b[i + 2] === 11 && b[i + 14] === 3 && data[11] === 1) {
        out.push(Uint8Array.of(0x21, 0xff, 11, ...[..."NETSCAPE2.0"].map(c => c.charCodeAt(0)), 3, 1, data[12], data[13], 0))
        looped = true
      }
    }
    // 0xfe comments, every other application block (XMP, ICC, Photoshop, …) and unknown labels: left behind.
    i = end
  }
  if (!frames) throw bad() // a GIF with no frame is no picture
  const total = out.reduce((n, p) => n + p.length, 0)
  const res = new Uint8Array(total)
  let at = 0
  for (const p of out) { res.set(p, at); at += p.length }
  return res
}
