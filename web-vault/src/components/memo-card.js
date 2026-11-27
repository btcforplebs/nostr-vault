// A list card that draws again only when what it shows changed, so a list that re-renders (a live note, a relay's
// answer, a wider draw window) doesn't redraw every card in it (profile perf review 2026-11-27 finding 4, Feed review
// findings 2 and 7). Notes never change once signed, so a card's note is compared by id: a list read again from Haven
// hands every card a new copy of the same event. Its other props are compared as they are; a context the card reads
// (useOutside, useBlocked) still reaches it, as Preact updates context readers past a skipped parent.
import { Component, createElement } from "preact"

const sameNote = (a, b) => a === b || (!!a && !!b && a.id === b.id && a.kind === b.kind)

/** `Inner` wrapped to skip a redraw while `noteProps` match by id and every other prop is the same value. */
export function memoCard(Inner, noteProps = ["event"]) {
  const notes = new Set(noteProps)
  class MemoCard extends Component {
    shouldComponentUpdate(next) {
      const prev = this.props
      const keys = new Set([...Object.keys(prev), ...Object.keys(next)])
      for (const k of keys) {
        if (k === "children" && !prev.children && !next.children) continue
        if (notes.has(k) ? !sameNote(prev[k], next[k]) : prev[k] !== next[k]) return true
      }
      return false
    }
    render(props) { return createElement(Inner, props) }
  }
  MemoCard.displayName = `Memo(${Inner.name})`
  return MemoCard
}
