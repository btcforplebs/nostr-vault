// Translate under a note in another language (NoteTranslateButton.swift). The iPhone translates on the device with
// Apple's Translation framework; the browser's own on-device Translator and LanguageDetector (Chrome 138+) do the same
// here, so the text never goes to a server. Where the browser has neither, no button. Offered when the note has at
// least 12 letters, the detector is at least 60% sure, and the language isn't yours (navigator.language).
import { useEffect, useState } from "preact/hooks"

const MIN_LETTERS = 12, MIN_CONFIDENCE = 0.6
const target = () => String(globalThis.navigator?.language ?? "en").split("-")[0].toLowerCase()
export const supported = () => typeof globalThis.Translator?.create === "function" && typeof globalThis.LanguageDetector?.create === "function"

/** The text worth translating: links and nostr: references out (NoteTranslation.translatableText). */
export const translatable = content => String(content ?? "").replace(/(https?:\/\/|nostr:)\S+/gi, " ").replace(/\s+/g, " ").trim()

/** Offer to translate from `detected` into `to`? (NoteTranslation.shouldOffer) */
export const shouldOffer = (detected, to) => !!detected && detected !== "und" && detected.split("-")[0] !== to

let detector = null
const languageOf = new Map() // note id -> language code or null
async function detect(id, text) {
  if (languageOf.has(id)) return languageOf.get(id)
  let code = null
  if ((text.match(/\p{L}/gu) ?? []).length >= MIN_LETTERS) {
    detector ??= globalThis.LanguageDetector.availability().then(a => a === "unavailable" ? null : globalThis.LanguageDetector.create())
    const d = await detector.catch(() => null)
    const [best] = d ? await d.detect(text).catch(() => []) : []
    if (best?.confidence >= MIN_CONFIDENCE) code = best.detectedLanguage
  }
  languageOf.set(id, code)
  return code
}

const nameOf = code => { try { return new Intl.DisplayNames([navigator.language], { type: "language" }).of(code) } catch { return "" } }

export function TranslateButton({ id, content }) {
  const text = translatable(content)
  const [lang, setLang] = useState(() => languageOf.get(id))
  const [translated, setTranslated] = useState(null)
  const [showing, setShowing] = useState(false)
  const [state, setState] = useState("") // "" | "busy" | "failed"
  useEffect(() => {
    if (!supported() || !text) return
    let live = true
    detect(id, text).then(c => { if (live) setLang(c) }).catch(() => {})
    return () => { live = false }
  }, [id])
  if (!supported() || !shouldOffer(lang, target())) return null
  const go = async e => {
    e.stopPropagation()
    if (translated) return setShowing(!showing)
    setState("busy")
    try {
      // Needs the click: a language pack the browser hasn't got yet downloads on a user gesture only.
      const t = await globalThis.Translator.create({ sourceLanguage: lang, targetLanguage: target() })
      setTranslated(await t.translate(text))
      setShowing(true)
      setState("")
    } catch { setState("failed") }
  }
  const name = nameOf(lang)
  const label = state === "busy" ? "Translating…" : state === "failed" ? "Couldn't translate — try again"
    : showing ? "Show original only" : name ? `Translate from ${name}` : "Translate"
  return (
    <div class="translate">
      {showing && translated && <p class="translate-text">{translated}</p>}
      <button type="button" class={`translate-button${state === "failed" ? " failed" : ""}`} onClick={go} disabled={state === "busy"} aria-label={label}>
        <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 5h9M8.5 3v2M6 5c.5 3 2.5 5.5 5 7M11 5c-.5 3-3 6.5-6.5 8M13 21l4-9 4 9M14.5 18h5" /></svg>
        {label}
      </button>
    </div>
  )
}
