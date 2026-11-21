// Settings › Feed › What You See (iPhone FeedSettingsView): Show Reposts, Show Replies and Auto-Load New Posts, the same
// switches as the Feed's own menu (net/feed-filters.js). A Feed already open takes a change at once (onFilters).
import { useEffect, useState } from "preact/hooks"
import { loadFilters, saveFilters, onFilters } from "../net/feed-filters.js"
import { SettingInfo } from "./SettingInfo.jsx"

export const FEED_SWITCHES = [
  { key: "reposts", title: "Show Reposts", topic: "feed.reposts" },
  { key: "replies", title: "Show Replies", topic: "feed.replies" },
  { key: "autoLoad", title: "Auto-Load New Posts", topic: "feed.autoLoad" },
]

export function FeedFilterSwitches() {
  const [f, setF] = useState(loadFilters)
  useEffect(() => onFilters(() => setF(loadFilters())), [])
  const flip = (key, on) => saveFilters({ ...loadFilters(), [key]: on })
  return FEED_SWITCHES.map(s => (
    <label key={s.key} class="settings-row static notify-switch">
      <span class="settings-title">{s.title}<SettingInfo topic={s.topic} /></span>
      <input type="checkbox" role="switch" checked={f[s.key]} onChange={e => flip(s.key, e.currentTarget.checked)} />
    </label>
  ))
}
