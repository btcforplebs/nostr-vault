// A list card that draws again only when what it shows changed, so a list that re-renders (a live note, a relay's
// answer, a wider draw window) doesn't redraw every card in it (profile perf review 2026-11-27 finding 4, Feed review
// findings 2 and 7). Notes never change once signed, so a card's note is compared by id: a list read again from Haven
// hands every card a new copy of the same event. Its other props are compared as they are; a context the card reads
// (useOutside, useBlocked) still reaches it, as Preact updates context readers past a skipped parent.
import { Component, createElement } from "preact"

export const sameNote = (a, b) => a === b || (!!a && !!b && a.id === b.id && a.kind === b.kind)

/**
 * `Inner` wrapped to skip a redraw while every prop is the same: by `compare[prop](a, b)` where given (`false`: not
 * compared, a callback whose old copy still works), else as the same value. The default compares `event` by note id.
 */
export function memoCard(Inner, compare = { event: sameNote }) {
  class MemoCard extends Component {
    shouldComponentUpdate(next) {
      const prev = this.props
      for (const k of new Set([...Object.keys(prev), ...Object.keys(next)])) {
        const same = compare[k]
        if (same === false) continue
        if (same ? !same(prev[k], next[k]) : prev[k] !== next[k]) return true
      }
      return false
    }
    render(props) { return createElement(Inner, props) }
  }
  MemoCard.displayName = `Memo(${Inner.name})`
  return MemoCard
}
