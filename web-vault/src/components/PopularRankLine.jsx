// "🔥 #3 · 1.2k" above a post in the Popular feed while ranks are on (iPhone PopularRankLine; parity #21). It sits
// outside the card so it never covers the post's time or menu.
import { rankScore } from "../net/popular.js"

export function PopularRankLine({ rank, score }) {
  return (
    <div class="popular-rank" role="note" aria-label={`Popular rank ${rank}, score ${rankScore(score)}`} title="Rank in this feed · engagement score">
      <span class="popular-rank-flame" aria-hidden="true">🔥</span><b>#{rank}</b><span aria-hidden="true">·</span><span class="mono">{rankScore(score)}</span>
    </div>
  )
}

/** The rank line for `id` when `rankOf` has one, then the card. */
export const Ranked = ({ id, rankOf, children }) => {
  const r = rankOf?.(id)
  return r ? <><PopularRankLine rank={r.rank} score={r.score} />{children}</> : children
}
