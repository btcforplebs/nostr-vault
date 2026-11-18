// Off-screen Feed cards skip their drawing (content-visibility: auto), but only once drawn and measured.
// The 11-10 try gave every card one guessed placeholder height (480, 260, 215 px): after Back the Feed is drawn again,
// every card above the opened note was a guess, and scrolling up jumped on almost every step in WebKit
// (RESEARCH/NV_WEB_CONTENT_VISIBILITY_CHECK_2026_11_10.md; card heights run 145 to 9000 px). Here every card is drawn in
// full first, as before (so after Back the cards above the note draw while feed-tap.js holds the spot); once measured,
// it gets data-cv and its own height as the placeholder. note-card.css has the rule; it is off while a menu or picker
// is open on the card. (Remembering heights across a Back, to skip from the first frame, measured worse in WebKit:
// a remembered card skips through the hold, so media that lands late moves the page after it.)
import { useLayoutEffect } from "preact/hooks"

/**
 * The cards directly in `main` (the Feed's <main>; the expanded layout draws them there, after the header) skip drawing
 * while off screen once measured, each with its own height. -> stop()
 */
export function watchCardSizes(main) {
  if (!main || !globalThis.ResizeObserver || !globalThis.CSS?.supports?.("content-visibility", "auto")) return () => {}
  const sized = new ResizeObserver(entries => {
    for (const e of entries) {
      const el = e.target
      // The content box: contain-intrinsic-size sizes the content, and the card's padding and border are added to it
      // (the border box made every placeholder ~31 px too tall, and WebKit jumped by that on each card drawn).
      const h = Math.round(e.contentRect.height)
      if (h <= 0 || !el.isConnected) continue
      // Once: from then on the browser keeps the card's last drawn size itself (the `auto` in the rule). Writing the
      // inherited --card-h again on each skip and draw restyled the whole card, and paint never dropped.
      el.style.setProperty("--card-h", `${h}px`)
      el.dataset.cv = ""
      sized.unobserve(el)
    }
  })
  const add = el => { if (el.nodeType === 1 && el.classList.contains("note-card") && el.dataset.cv == null) sized.observe(el) }
  for (const el of main.children) add(el)
  const added = new MutationObserver(list => {
    for (const m of list) { for (const el of m.addedNodes) add(el); for (const el of m.removedNodes) if (el.nodeType === 1) sized.unobserve(el) }
  })
  added.observe(main, { childList: true })
  return () => { added.disconnect(); sized.disconnect() }
}

/** watchCardSizes on `root` (a ref) while `on`. */
export function useCardSizes(root, on) {
  useLayoutEffect(() => on ? watchCardSizes(root.current) : undefined, [on])
}
