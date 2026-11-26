// Settings as a napplet (plan NV_WEB_ONE_PLAN.md step 10a): the Settings list and the plain preference pages (Feed,
// Media & Cache, Privacy, Notifications) on the desktop while napplets are on. The shell reads and writes each
// preference with the page's own module (send-delay.js, media-prefs.js, notify-watch.js, notify-prefs.js) and hands the
// napplet words and values only (settings-answer.js). Every other Settings page stays the shell's own screen.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { usePaneNapplet } from "./usePaneNapplet.js"
import { SETTINGS_DTAG } from "./first-party.js"
import { settingsAnswer, settingsHandlers, SETTINGS_TOPIC } from "./settings-answer.js"
import { sendDelaySeconds, setSendDelaySeconds } from "../net/send-delay.js"
import { autoplayOn, setAutoplay } from "../net/media-prefs.js"
import { setUploadQuality, uploadQuality } from "../net/upload-quality.js"
import { notifyOn, onNotifyPref, permission, setNotifyOn, turnOn } from "../net/notify-watch.js"
import { readTypes, setType, onTypes } from "../net/notify-prefs.js"
import { APP_VERSION, APP_COMMIT, commitUrl, SUPPORT_NPUB, PRIVACY_URL } from "../net/settings.js"
import { learn } from "../shell.js"
import { BOX } from "../box/mode.js"
import { hasKeyPage } from "../screens/SettingsScreen.jsx"
import { FEED_RELAYS_NOTE, FEED_NOTE } from "../screens/settings/FeedSettingsPage.jsx"
import { CACHE_NOTE } from "../screens/settings/MediaCachePage.jsx"
import { PRIVACY_SECTIONS, WEB_NOTE } from "../screens/settings/PrivacyPage.jsx"
import { autoplayNote } from "../components/AutoplaySwitch.jsx"
import { NOTIFY_NOTE, NOT_ALLOWED, WHY } from "../components/NotifySwitch.jsx"
import "./napplet.css"

const STORAGE_LINE = "This browser keeps a copy of your notes, and the browser can clear it. Your phone's vault is the real one."
const WORDS = {
  feedRelaysNote: FEED_RELAYS_NOTE, feedNote: FEED_NOTE, autoplayNote, cacheNote: CACHE_NOTE, privacy: { sections: PRIVACY_SECTIONS, note: WEB_NOTE },
  notifyNote: NOTIFY_NOTE, storageLine: STORAGE_LINE, version: APP_VERSION, commit: APP_COMMIT, hasCommitLink: !!commitUrl(APP_COMMIT),
}

export function SettingsPane({ ctx, page = "" }) {
  const host = useRef(null)
  const [tick, setTick] = useState(0)
  const bump = () => setTick(n => n + 1)
  const [events, setEvents] = useState(null)
  const [kept, setKept] = useState(undefined)
  const [why, setWhy] = useState("")
  const [copied, setCopied] = useState(false)
  useEffect(() => {
    navigator.storage?.persisted?.().then(setKept).catch(() => setKept(null))
    ctx.vault.outbox.count({ authors: [ctx.session.pubkey] }).then(setEvents).catch(() => {})
  }, [ctx.session.pubkey])
  useEffect(() => { const a = onNotifyPref(bump), b = onTypes(bump); return () => { a(); b() } }, [])
  const read = () => ({ keyPage: hasKeyPage(ctx), box: !!BOX, events, kept, sendDelay: sendDelaySeconds(), autoplay: autoplayOn(), uploadQuality: uploadQuality(),
    notify: { on: notifyOn() && permission() === "granted", why }, types: readTypes(), copied })
  const latest = useRef(read)
  latest.current = read
  const pageRef = useRef(page)
  pageRef.current = page
  const pipe = useMemo(() => ({ answer: () => settingsAnswer(pageRef.current, latest.current(), WORDS), keyPage: () => hasKeyPage(ctx), box: () => !!BOX, ctl: null }), [])
  pipe.ctl = {
    go: hash => { location.hash = hash },
    learn: () => learn(),
    open: what => open(what === "docs" ? "/docs/" : what === "privacy-policy" ? PRIVACY_URL : commitUrl(APP_COMMIT), "_blank", "noopener"),
    copy: () => { navigator.clipboard?.writeText(SUPPORT_NPUB).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500) }).catch(() => {}) },
    set: async (key, value) => {
      if (key === "sendDelay") setSendDelaySeconds(value)
      else if (key === "autoplay") setAutoplay(value)
      else if (key === "uploadQuality") setUploadQuality(value)
      else if (key === "alert") setType(value.id, value.on)
      else if (key === "notify") {
        setWhy("")
        if (!value) setNotifyOn(false)
        else { const p = await turnOn().catch(() => "denied"); if (p !== "granted") setWhy(WHY[p] ?? NOT_ALLOWED) }
      }
      bump()
    },
  }
  const handlers = useMemo(() => settingsHandlers(pipe).map(h => ({ id: `shell:${SETTINGS_DTAG}`, title: "Nostr Vault", conventions: [], ...h })), [])
  const { live, note, ready } = usePaneNapplet(ctx, host, { dTag: SETTINGS_DTAG, handlers })
  // The napplet draws the page in the address: tell it to ask again when the page or anything on it changes.
  const key = ready ? JSON.stringify(pipe.answer()) : ""
  useEffect(() => { if (ready) live.current?.bus.emit(live.current.me, SETTINGS_TOPIC, {}) }, [key, tick])
  return (
    <main class="screen settings settings-napplet">
      {note && <p class="muted small">{note}</p>}
      <div class="napplet-host on" ref={host} />
    </main>
  )
}
