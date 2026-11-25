// A key's fixed angle round a flat far ring and a 0-1 wobble, both from the key alone, so a dot never moves: the web
// twin of Apple Models/GlobeHazeField.swift. The picked hop's sphere (globe-sphere-field.js) uses the wobble to break up
// its spiral. Each part folds 8 UTF-8 bytes as h * 31 + byte, which stays exact in a JS number (under 2^53), so it
// matches Swift's UInt64 fold. test/globe-hop-ring.test.mjs pins it against the Swift function's own output.
const fold = bytes => bytes.reduce((h, b) => h * 31 + b, 0)

/** -> { angle: radians 0..2π from the key's first 8 characters, wobble: 0..1 from its next 8 } */
export function hazeHash(key) {
  const bytes = [...new TextEncoder().encode(String(key))]
  const head = fold(bytes.slice(0, 8)), next = fold(bytes.slice(8, 16))
  return { angle: (head % 3600) / 3600 * 2 * Math.PI, wobble: (next % 1000) / 1000 }
}
