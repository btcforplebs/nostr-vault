// Articles on a profile (and in Vault) open the Markdown reader, as the iPhone's profile article cards open
// ArticleReaderView; the card is the Articles feed's own.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({ load(url, context, next) {
  if (!url.endsWith(".jsx")) return next(url, context)
  const { code } = transformSync(fileURLToPath(url), readFileSync(fileURLToPath(url), "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
  return { format: "module", source: code, shortCircuit: true }
} })
const { ArticleCard, openArticle } = await import("../src/components/ArticleCard.jsx")
const { ArticleRow } = await import("../src/readers/ArticlesScreen.jsx")

const article = { id: "a".repeat(64), kind: 30023, pubkey: "b".repeat(64), created_at: 1_700_000_000, tags: [["d", "x"], ["title", "Hello"]], content: "# Body" }

test("the card is the Articles feed's card, and a tap opens the article's reader", () => {
  const card = ArticleCard({ event: article })
  assert.equal(card.type, ArticleRow)
  assert.equal(card.props.event, article)
  globalThis.location = { hash: "#/profile" }
  try {
    card.props.onOpen()
    assert.equal(location.hash, `#/thread/${article.id}`)
  } finally { delete globalThis.location }
})

test("the thread route draws a 30023 with the Markdown reader", () => {
  const thread = readFileSync(new URL("../src/screens/ThreadScreen.jsx", import.meta.url), "utf8")
  assert.match(thread, /thread\?\.root\?\.kind === 30023 && !rootBlocked\) return <main class="screen"><ArticleReader /)
  assert.match(readFileSync(new URL("../src/readers/ArticlesScreen.jsx", import.meta.url), "utf8"), /<Markdown body=\{event\.content\} \/>/)
  assert.equal(typeof openArticle, "function")
})
