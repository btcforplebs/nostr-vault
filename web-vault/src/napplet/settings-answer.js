// Settings as a napplet (plan NV_WEB_ONE_PLAN.md step 10, part a): the Settings list and its plain preference pages
// (Feed, Media & Cache, Privacy, Notifications) are the Settings napplet on the desktop while napplets are on. The shell
// reads each preference with the page's own module and hands the napplet the words, the rows and the values; a change
// comes back by name and the shell writes it with the same module. Every other row (keys, accounts, Blocked, Relays,
// Media Servers, the vault and backup pages, Wallet, Appearance) opens the shell's own page, as before.
//   napplet:settings/state {}             -> { data } (settingsAnswer) for the page in the address: "" (the list) or one
//                                            of PAGES_HERE
//   napplet:settings/go { to }            -> a row id, "key" (only with a key in this browser), "box" (box mode), "list", "close",
//                                            "learn", "docs", "privacy-policy" or "commit"
//   napplet:settings/set { key, value }   -> sendDelay (a choice), uploadQuality ("standard"/"original"), autoplay (true/false), notify (true/false),
//                                            alert { id, on } (an alert type)
//   napplet:settings/copy { what: "support" } -> the support npub to the clipboard (the shell's)
// A change comes as inc nv.settings.changed.
import { SETTINGS_GROUPS, SETTINGS_ICONS, PAGES, SUPPORT_NPUB } from "../net/settings.js"
import { SEND_DELAY_CHOICES, sendDelayNote } from "../net/send-delay.js"
import { TYPES } from "../net/notify-prefs.js"
import { helpTopic } from "../net/settings-help.js"
import { UPLOAD_QUALITY_CHOICES, UPLOAD_QUALITY_FOOTER, uploadQualityNote } from "../net/upload-quality.js"

export const SETTINGS_TOPIC = "nv.settings.changed"
/** The pages the napplet draws; "" is the list. */
export const PAGES_HERE = ["feed", "media", "privacy", "notifications"]
export const drawsHere = page => page === "" || page == null || PAGES_HERE.includes(page)
const ORDER = ["Account", "Feed & Display", "Notifications", "Relays", "Your Vault", "Mesh", "Help", "Advanced"]
const rank = g => { const i = ORDER.indexOf(g.title); return i < 0 ? ORDER.length : i }
const COLOR = /^(#[0-9a-f]{6}|var\(--accent\))$/i
const info = topic => { const t = helpTopic(topic); return t ? { title: String(t.title), text: String(t.text) } : null }
const choiceLabel = s => (s === 0 ? "Off" : `${s}s`)

/**
 * `page`: "" or one of PAGES_HERE. `x`: what the shell read now: { keyPage, box, events, kept, sendDelay, autoplay,
 * notify: { on, why }, types, copied }. `w`: the pages' own words { feedRelaysNote, feedNote, autoplayNote(on),
 * cacheNote, privacy: { sections, note }, notifyNote, storageLine, version, commit, hasCommitLink }.
 */
export function settingsAnswer(page, x, w) {
  const p = drawsHere(page) ? page || "" : ""
  if (p === "") {
    const groups = [...SETTINGS_GROUPS].sort((a, b) => rank(a) - rank(b)).map(g => ({
      title: g.title,
      rows: g.rows.map(r => ({ id: r.id, title: r.title, icon: SETTINGS_ICONS[r.icon] ?? "", color: COLOR.test(r.color) ? r.color : "#8e8e93" })),
    }))
    return {
      page: "", title: "Settings",
      box: !!x.box,
      status: x.box ? null : { events: Number.isFinite(x.events) ? x.events : null, kept: x.kept === undefined ? null : !!x.kept, line: w.storageLine },
      learn: [{ id: "learn", title: "Learn about Nostr Vault", icon: SETTINGS_ICONS.learn, color: "var(--accent)" }, { id: "docs", title: "Docs", icon: SETTINGS_ICONS.docs, color: "#0a84ff", side: "New tab" }],
      key: x.keyPage ? { id: "key", title: "Your Secret Key", icon: SETTINGS_ICONS.secretKey, color: "#ff9f0a" } : null,
      groups,
      about: { version: String(w.version), commit: String(w.commit ?? ""), commitLink: !!w.hasCommitLink, support: SUPPORT_NPUB, copied: !!x.copied },
    }
  }
  const title = PAGES[p].title
  if (p === "feed") {
    return { page: p, title, relaysNote: w.feedRelaysNote, relaysInfo: info("feed.relays"), note: w.feedNote,
      sendDelay: { seconds: x.sendDelay, choices: SEND_DELAY_CHOICES.map(s => ({ value: s, label: choiceLabel(s) })), note: sendDelayNote(x.sendDelay), info: info("post.sendDelay") } }
  }
  if (p === "media") return { page: p, title, autoplay: { on: !!x.autoplay, note: w.autoplayNote(!!x.autoplay), info: info("media.autoplay") },
    uploadQuality: { value: x.uploadQuality, choices: UPLOAD_QUALITY_CHOICES, note: `${uploadQualityNote(x.uploadQuality)} ${UPLOAD_QUALITY_FOOTER}` }, cacheNote: w.cacheNote }
  if (p === "privacy") return { page: p, title, sections: w.privacy.sections.map(s => ({ label: s.label, note: s.note, title: s.title, info: info(s.info) })), note: w.privacy.note }
  return { page: p, title, on: !!x.notify.on, info: info("notify.enable"), alertsInfo: info("notify.perAccount"),
    types: x.notify.on ? TYPES.map(t => ({ id: t.id, title: t.title, on: !!x.types[t.id] })) : [], note: x.notify.why || w.notifyNote }
}

/** Where a row goes: its own address from SETTINGS_GROUPS, or one of the list's few others. -> a hash, or "" */
export function settingsHref(to, { keyPage = false, box = false } = {}) {
  const row = SETTINGS_GROUPS.flatMap(g => g.rows).find(r => r.id === to)
  if (row) return row.href
  if (to === "key") return keyPage ? "#/settings/key" : ""
  if (to === "list") return "#/settings"
  if (to === "close") return "#/profile"
  if (to === "box") return box ? "#/box" : ""
  return ""
}

/** `pipe`: { answer() -> data for the page in the address, ctl: { go(hash), learn(), open(url name), set(key, value), copy() }, keyPage() }.
 *  -> handlers for usePaneNapplet (one napplet on its own bus). */
export function settingsHandlers(pipe) {
  const h = (action, run) => ({ archetype: "settings", actions: [action], deliver: p => run(p ?? {}) })
  const ok = { ok: true }
  return [
    h("state", () => ({ ok: true, data: pipe.answer() })),
    h("go", p => {
      const to = typeof p.to === "string" ? p.to : ""
      if (to === "learn") { pipe.ctl.learn(); return ok }
      if (to === "docs" || to === "privacy-policy" || to === "commit") { pipe.ctl.open(to); return ok }
      const href = settingsHref(to, { keyPage: pipe.keyPage(), box: pipe.box() })
      if (!href) return { ok: false, error: "not a Settings row" }
      pipe.ctl.go(href)
      return ok
    }),
    h("set", p => {
      if (p.key === "sendDelay" && SEND_DELAY_CHOICES.includes(p.value)) { pipe.ctl.set("sendDelay", p.value); return ok }
      if (p.key === "uploadQuality" && UPLOAD_QUALITY_CHOICES.some(c => c.value === p.value)) { pipe.ctl.set("uploadQuality", p.value); return ok }
      if ((p.key === "autoplay" || p.key === "notify") && typeof p.value === "boolean") { pipe.ctl.set(p.key, p.value); return ok }
      if (p.key === "alert" && TYPES.some(t => t.id === p.value?.id) && typeof p.value?.on === "boolean") { pipe.ctl.set("alert", { id: p.value.id, on: p.value.on }); return ok }
      return { ok: false, error: "not a setting this page changes" }
    }),
    h("copy", p => (p.what === "support" ? (pipe.ctl.copy(), ok) : { ok: false, error: "nothing else to copy" })),
  ]
}
