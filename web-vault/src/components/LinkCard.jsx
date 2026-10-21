// A link as a card (LinkPreviewCard.swift's fallback): a link glyph, the site's domain and an arrow out. The iPhone
// fills it with the page's og:image, title and description; a browser can't read another site's page, so here it
// stays the fallback until there is a preview endpoint. Opens in a new tab and never opens the card around it.
const domain = url => { try { return new URL(url).hostname.replace(/^www\./, "") } catch { return url } }

export function LinkCard({ url }) {
  return (
    <a class="link-card" href={url} target="_blank" rel="noopener noreferrer" onClick={e => e.stopPropagation()} title={url}>
      <svg class="link-card-glyph" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true">
        <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
      </svg>
      <span class="link-card-domain">{domain(url)}</span>
      <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9" /></svg>
    </a>
  )
}
