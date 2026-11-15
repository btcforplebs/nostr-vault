// What four of our widget cards draw, worked out by the panels' own hooks (plan NV_WEB_ONE_PLAN.md step 4): the Live
// Vault, Messages, My devices and Web of Trust cards read with the same rules as their panels, and only the shaped
// answer (widget-answers.js) crosses into the card's frame. Each source renders nothing: it hands `put` the card's data,
// the routes its clicks may open (kept here, never handed over) and the header's badge, whenever they change.
import { useEffect, useState } from "preact/hooks"
import { getProfile, onProfiles } from "../../net/profiles.js"
import { lineHref, whoText } from "../../net/notify-watch.js"
import { lastPreview } from "../../net/dms.js"
import { badgeCount } from "../../components/useUnreadTotal.js"
import { verb } from "../../screens/VaultScreen.jsx"
import { useLiveVault } from "./LiveVault.jsx"
import { usePeek } from "./MessagesPeek.jsx"
import { useMyDevices } from "./MyDevices.jsx"
import { useWotMini } from "./WotMini.jsx"
import { rowText, facesText } from "./live-vault.js"
import { deviceStatus, statusLine, deviceName, MESH_HEADER } from "./my-devices.js"
import { vouchText } from "./wot-mini.js"
import { vaultData, devicesData, messagesData, wotData } from "./widget-answers.js"

/** Names and faces fill in as profiles land: a tick that moves when they do (at most every PROFILE_GAP_MS). */
const PROFILE_GAP_MS = 500
function useProfilesTick() {
  const [tick, setTick] = useState(0)
  useEffect(() => {
    let t = null
    const off = onProfiles(() => { if (!t) t = setTimeout(() => { t = null; setTick(n => n + 1) }, PROFILE_GAP_MS) })
    return () => { off(); clearTimeout(t) }
  }, [])
  return tick
}

function LiveVaultSource({ ctx, open, put }) {
  const v = useLiveVault(ctx)
  const tick = useProfilesTick()
  useEffect(() => {
    const { data, routes } = vaultData({ ...v, facesLine: facesText(v.faces.length + v.more, v.news.length > 0) },
      { profileOf: getProfile, verbOf: verb, whoOf: whoText, hrefOf: lineHref, textOf: rowText })
    // As the panel: the new count shows on the header while the card is collapsed.
    put({ data, routes, badge: !open && v.unread.size ? { text: String(v.unread.size), label: `${v.unread.size} new` } : null, live: true })
  }, [v.rows, v.unread, v.fetched, v.faces.join(), tick, open])
  return null
}

function MessagesSource({ ctx, put }) {
  const me = ctx.session.pubkey
  const peek = usePeek(ctx)
  const tick = useProfilesTick()
  useEffect(() => {
    const follows = new Set(ctx.account.follows)
    const { data, routes } = messagesData(peek, me, { profileOf: getProfile, previewOf: lastPreview, loadPic: pk => follows.has(pk) })
    const w = peek.waiting
    put({ data, routes, badge: w ? { text: badgeCount(w), label: `${w} unread ${w === 1 ? "chat" : "chats"}`, cls: "mp-count" } : null })
  }, [peek.rows, peek.open, peek.note, tick])
  return null
}

function DevicesSource({ ctx, put }) {
  const loaded = useMyDevices(ctx)
  useEffect(() => {
    const { data, onMesh, total } = devicesData(loaded, Math.floor(Date.now() / 1000), { deviceStatus, statusLine, deviceName, header: MESH_HEADER })
    put({ data, routes: new Map(), badge: total ? { text: `${onMesh}/${total}`, label: `${onMesh} of ${total} on the mesh`, cls: "md-count" } : null })
  }, [loaded])
  return null
}

function WotSource({ ctx, open, put }) {
  const w = useWotMini(ctx)
  const tick = useProfilesTick()
  useEffect(() => {
    const { data, routes } = wotData({ ...w, extendedMin: w.web?.extendedMin }, { profileOf: getProfile, vouchOf: pk => (w.web ? vouchText(w.web, pk) : "") })
    const n = w.fresh.length
    put({ data, routes, badge: !open && n ? { text: String(n), label: `${n} new in your web` } : null })
  }, [w.web, w.status, w.fresh, w.points, tick, open])
  return null
}

/** The source for card `id`, or undefined (Live now and On this day ask the shell directly, WidgetCard.jsx). */
export const SOURCES = { "live-vault": LiveVaultSource, messages: MessagesSource, "my-devices": DevicesSource, "wot-mini": WotSource }
