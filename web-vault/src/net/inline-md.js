// The inline markdown a note's text honors, as iOS does (NostrContentFormatter: AttributedString markdown,
// inlineOnlyPreservingWhitespace): **bold** / __bold__, *italic* / _italic_, ~~strike~~ and `code`. Links the author
// typed as markdown stay as typed (MarkdownEscape.linkSyntax), and links and nostr: refs are split out before this
// runs, so it only ever sees plain text. An underscore inside a word (snake_case) is not italic.
const RE = /(\*\*|__)(?=\S)(.+?)(?<=\S)\1|~~(?=\S)(.+?)(?<=\S)~~|`([^`\n]+)`|(?<![\w*_])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\5(?![\w*_])/g

/** [{ type: "text" | "strong" | "em" | "del" | "code", text }] */
export function inlineMarks(text) {
  const out = []
  let at = 0
  for (const m of String(text).matchAll(RE)) {
    if (m.index > at) out.push({ type: "text", text: text.slice(at, m.index) })
    if (m[2] !== undefined) out.push({ type: "strong", text: m[2] })
    else if (m[3] !== undefined) out.push({ type: "del", text: m[3] })
    else if (m[4] !== undefined) out.push({ type: "code", text: m[4] })
    else out.push({ type: "em", text: m[6] })
    at = m.index + m[0].length
  }
  if (at < text.length) out.push({ type: "text", text: text.slice(at) })
  return out
}
