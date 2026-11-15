// The Reader's Notifications source (reader-notifications.js): mounted while the desktop shows Notifications, so the
// visit's unread mark and the screen's own looking-again work as they do on the Notifications screen. It keeps the
// latest list in `pipe` and tells the Reader when what it would draw changed. Renders nothing.
import { useEffect } from "preact/hooks"
import { useNotifications } from "../screens/useNotifications.js"
import { onProfiles } from "../net/profiles.js"
import { useState } from "preact/hooks"

export function ReaderNotifSource({ ctx, pipe }) {
  const list = useNotifications(ctx, "all")
  const [tick, setTick] = useState(0)
  useEffect(() => { let t = null; const off = onProfiles(() => { if (!t) t = setTimeout(() => { t = null; setTick(n => n + 1) }, 500) }); return () => { off(); clearTimeout(t) } }, [])
  useEffect(() => { pipe.put(list) }, [list.shown, list.outside, list.notes, list.status, list.loading, list.more, list.unreadSince, tick])
  useEffect(() => () => pipe.put(null), [])
  return null
}
