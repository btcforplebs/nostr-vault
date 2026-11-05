// How the web reads a QR code from the camera (plan §5): the browser's own BarcodeDetector where it reads qr_code
// (Chromium; feature-detected, never by browser name), else jsQR, loaded only now, when a scan screen opens, so the
// vault's first load doesn't carry it (Firefox always takes this path). QrReader.jsx calls this; kept apart so node
// tests can reach it.

/** -> { kind: "native" | "js", decode(video) -> text | null }. `BD` and `loadJs` are for tests. */
export async function pickDecoder({ BD = globalThis.BarcodeDetector, loadJs = () => import("jsqr").then(m => m.default), doc = globalThis.document } = {}) {
  if (typeof BD === "function") {
    try {
      const formats = typeof BD.getSupportedFormats === "function" ? await BD.getSupportedFormats() : ["qr_code"]
      if (formats.includes("qr_code")) {
        const d = new BD({ formats: ["qr_code"] })
        return { kind: "native", decode: async src => (await d.detect(src))?.find(c => typeof c?.rawValue === "string")?.rawValue ?? null }
      }
    } catch {}
  }
  const jsQR = await loadJs()
  let canvas, g
  return {
    kind: "js",
    decode: async video => {
      const w = video?.videoWidth, h = video?.videoHeight
      if (!w || !h) return null
      // Big camera frames are slow in JS and gain nothing for a code held up to the camera.
      const scale = Math.min(1, 800 / Math.max(w, h))
      const cw = Math.round(w * scale), ch = Math.round(h * scale)
      canvas ??= doc.createElement("canvas")
      if (canvas.width !== cw || canvas.height !== ch) { canvas.width = cw; canvas.height = ch; g = null }
      g ??= canvas.getContext("2d", { willReadFrequently: true })
      g.drawImage(video, 0, 0, cw, ch)
      const img = g.getImageData(0, 0, cw, ch)
      return jsQR(img.data, cw, ch, { inversionAttempts: "attemptBoth" })?.data || null
    },
  }
}

/** Passes each new code once: the camera sees the same code many times a second. A code seen again after `gapMs`
 *  without it counts again (the person tries the same code after a refusal). */
export function onceEach(onCode, { gapMs = 3000, now = () => Date.now() } = {}) {
  let last = null, at = 0
  return text => {
    if (!text) return
    const t = now()
    if (text === last && t - at < gapMs) { at = t; return }
    last = text; at = t
    onCode(text)
  }
}
