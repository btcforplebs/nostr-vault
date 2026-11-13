// The Emoji page's data (EmojiScreen.jsx): your emoji list (10030) and its sets, the copies the apps saved in this
// browser's vault (read from /files when this browser is the home vault), and which links are dead.
import { useEffect, useRef, useState } from "preact/hooks"
import { readEmojiList, listedSets, fetchSets, setRelays, changeSet } from "../../net/emoji-sets.js"
import { checkLinks } from "../../net/emoji-links.js"
import { savedCopyFor } from "../../net/emoji-notes.js"
import { watchFileNotes } from "../../net/file-notes-live.js"
import { sealMeshAuth } from "../../net/pair-hello.js"
import { mediaServers, DEFAULT_MEDIA_SERVERS } from "../../net/upload.js"
import { authorServers } from "../../net/blossom-uri.js"
import { ListNotSaved } from "../../net/list-edit.js"

/** -> { list, listChecked, sets: [set] | null, others: [set] (copies filed under sets not in the list), copies, homeVault,
 *  links: Map url -> state, saved(set, emoji), setOn(set, add) -> Promise<message> } */
export function useEmojiVault(ctx) {
  const me = ctx.session.pubkey
  const [list, setList] = useState({ event: undefined, checked: false })
  const [sets, setSets] = useState(null)
  const [others, setOthers] = useState([])
  const [copies, setCopies] = useState(() => new Map())
  const [links, setLinks] = useState(() => new Map())
  const run = useRef(0)
  const homeVault = !!ctx.vault?.owners

  const load = async () => {
    const n = ++run.current
    const r = await readEmojiList(ctx, { on: ({ event }) => n === run.current && setList(l => ({ ...l, event })) }).catch(() => ({ event: null, checked: false }))
    if (n !== run.current) return
    setList({ event: r.event ?? null, checked: !!r.checked })
    const addresses = listedSets(r.event)
    const got = await fetchSets(ctx, addresses).catch(() => new Map())
    if (n !== run.current) return
    setSets(addresses.map(a => got.get(a) ?? { address: a, missing: true, title: a.split(":").slice(2).join(":") || "Emoji set", author: a.split(":")[1], emoji: [] }))
  }
  useEffect(() => { setSets(null); load() }, [me])

  // The apps' saved copies, live from this browser vault's /files (its own stream name: Media keeps one open too).
  useEffect(() => {
    setCopies(new Map())
    if (!homeVault) return
    return watchFileNotes({ haven: ctx.vault.haven, owner: me, name: "ui-files-emoji", auth: challenge => sealMeshAuth({ challenge }),
      onChange: (_, state) => setCopies(state.emojiCopies()) })
  }, [me, ctx.vault])

  // Sets your saved copies are filed under that your list no longer names: still shown, as "not in your list".
  const listed = new Set((sets ?? []).map(s => s.address))
  const unlisted = [...new Set([...copies.values()].flatMap(c => c.sets))].filter(a => !listed.has(a))
  useEffect(() => {
    if (!sets || !unlisted.length) { setOthers([]); return }
    let live = true
    fetchSets(ctx, unlisted).then(m => live && setOthers([...m.values()])).catch(() => {})
    return () => { live = false }
  }, [sets, unlisted.join(" ")])

  // Each image once; a dead one is looked for on other servers by its hash. Links already checked keep their answer.
  const shown = [...(sets ?? []), ...others]
  const urls = shown.flatMap(s => s.emoji.map(e => e.url))
  useEffect(() => { setLinks(new Map()) }, [me])
  useEffect(() => {
    const todo = urls.filter(u => !links.has(u))
    if (!todo.length) return
    let live = true
    const author = new Map(shown.flatMap(s => s.emoji.map(e => [e.url, s.author])))
    const mine = mediaServers(ctx).catch(() => [])
    const servers = async url => [await mine, await authorServers(author.get(url), setRelays(ctx)), DEFAULT_MEDIA_SERVERS]
    checkLinks(todo, { servers, onResult: (url, state) => live && setLinks(m => new Map(m).set(url, state)) })
    return () => { live = false }
  }, [urls.join(" ")])

  const saved = (set, e) => savedCopyFor(copies, set, e)

  /** Add or remove a set. -> what to tell the user. The list reloads after, so the page shows what was saved. */
  const setOn = async (set, add) => {
    try {
      const r = await changeSet(ctx, { set, add, previous: list.event })
      setList({ event: r.event, checked: true })
      await load()
      if (!add) return `Removed "${set.title}" from your emoji list.`
      const k = r.kept
      const sent = k?.error ? ` Its own copy wasn't sent on: ${k.error}` : k ? ` Sent its original to ${k.sent} of your ${k.of} relays${k.vault ? `; your vault didn't keep it (${k.vault})` : " and kept it in your vault"}.` : ""
      return `Added "${set.title}" to your emoji list.${sent}`
    } catch (e) {
      if (e instanceof ListNotSaved && e.checked) setList({ event: e.latest ?? null, checked: true })
      return e?.message ?? String(e)
    }
  }
  return { list, sets, others, copies, homeVault, links, saved, setOn, reload: load }
}
