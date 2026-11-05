// What a diVine carries, ported from the iPhone's DivineComposeView (Views/DivineComposeView.swift): a NIP-71 addressable
// short-video event (kind 34236) shaped like the ones diVine's own app publishes, sent to diVine's relay as well as the
// account's. The iPhone trims a longer video to its first 6.3 s; a browser can't cut a video without re-recording it,
// so the web takes videos that already fit and says so.
import { hashtags } from "../../net/hashtags.js"
import { DIVINE_RELAY, REEL_KIND } from "../../readers/reels.js"
export { DIVINE_RELAY, REEL_KIND }

/** diVine's camera records six-second loops (DivineComposeView.recordLimit). */
export const RECORD_LIMIT_S = 6.3
/** Whole seconds, as people say it. */
export const LIMIT_SECONDS = Math.floor(RECORD_LIMIT_S)

/** The video types diVine's players can count on, and what browsers record. */
export const VIDEO_TYPES = ["video/mp4", "video/quicktime", "video/webm"]

/** Why a picked video can't be a diVine, or null when it can. `clip`: { mime, duration }. */
export function clipProblem({ mime, duration }) {
  if (!VIDEO_TYPES.includes(mime)) return "That isn't a video diVine can play. Choose an MP4, MOV or WebM."
  if (!Number.isFinite(duration) || duration <= 0) return "Couldn't read that video's length."
  if (duration > RECORD_LIMIT_S) return `That video is ${duration.toFixed(1)} seconds. diVines are up to ${LIMIT_SECONDS} seconds: trim it first, or record one.`
  return null
}

/** "4.2s of 6s" (the length meter). */
export const lengthText = duration => `${duration.toFixed(1)}s of ${LIMIT_SECONDS}s`
/** How much of the limit it uses, 0..1. */
export const lengthShare = duration => Math.min(1, duration / LIMIT_SECONDS)

/**
 * DivineComposeView.tags: in the order and shape diVine's own events use. `video`: the upload ({ url, sha256, size,
 * mime }); `poster`: the cover's URL; `clip`: { width, height, duration }.
 */
export function divineTags({ video, poster, clip, title, caption, publishedAt }) {
  const tags = [["d", video.sha256], ["imeta", `url ${video.url}`, `m ${video.mime || "video/mp4"}`, `image ${poster}`,
    `dim ${Math.round(clip.width)}x${Math.round(clip.height)}`, `x ${video.sha256}`, `size ${video.size}`]]
  if (title) tags.push(["title", title])
  tags.push(["published_at", String(publishedAt)])
  tags.push(["duration", String(Math.max(1, Math.round(clip.duration)))])
  tags.push(["alt", title || (caption ? [...caption].slice(0, 140).join("") : "Short video")])
  for (const t of hashtags(`${title} ${caption}`)) tags.push(["t", t])
  return tags
}

/** Where the post goes: the account's write relays and diVine's, once. */
export const divineRelays = write => [...new Set([...write.map(u => String(u).replace(/\/+$/, "")), DIVINE_RELAY])]

/** diVine's relay's answer from publishKind's results, or null when it wasn't asked. */
export const divineAnswer = relays => relays.find(r => r.url.replace(/\/+$/, "") === DIVINE_RELAY) ?? null

/** The warning when diVine's relay didn't take it (the iPhone's banner). */
export const divineRefused = message => `Posted to your relays, but diVine's relay didn't take it: ${message || "no reason given"}`
