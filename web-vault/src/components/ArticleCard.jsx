// A kind 30023 long-form article (NIP-23) in a profile, Vault or Vault search list: the Articles feed's card (image,
// title, preview, author · date · minutes · Open in YakiHonne), and a tap opens the full reader with its Markdown body,
// as the iPhone's profile article cards open ArticleReaderView. The reader is the thread route's (ThreadScreen draws a
// 30023 root with ArticleReader), so Back returns to the list.
import { ArticleRow } from "../readers/ArticlesScreen.jsx"

export const openArticle = id => { location.hash = `#/thread/${id}` }

export function ArticleCard({ event }) {
  return <ArticleRow event={event} onOpen={() => openArticle(event.id)} />
}
