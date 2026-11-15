# Step 1: the theme reaches every napplet, live

Plan: OUTBOX/NV_WEB_ONE_PLAN.md step 1 (design RESEARCH/NV_NAPPLET_EVERY_PAGE_PLAN.md §4).

## What changed

- **Shell side (`src/napplet/theme.js`).** `theme.get` now answers NIP-5D's three colours plus an `nv` block inside the
  theme object: `mode` (`dark`/`light`), `tokens` (every token of `styles/tokens.css`, as the page computes them now, so
  light.css and the accent are already applied) and `dark` (the dark set, for a dark island). `THEME_TOKENS` is kept
  equal to tokens.css by a test.
- **No flash.** `runtime.js` puts `themeHead()` into the srcdoc right after the bootstrap: a `:root:root { … }` block
  that outranks the napplet's own `:root` defaults. A napplet in Light is never black for a frame.
- **Live.** `runtime.js` subscribes each napplet given the theme to `onThemeChange` (Mode, accent, Auto following the
  device, another tab) and sends `theme.changed`; the subscription ends when the napplet closes.
- **Napplet side (`src/napplet/theme-client.js`).** One copy, put in at build where a napplet says `/*@nv-theme*/`
  (`theme-inject.js`, same path in the app and `tools/napplet-release.mjs`). It sets every token on `:root`, sets
  `color-scheme` and `data-theme`, follows `theme.onChanged`, and fires a window `nv-theme` event for canvas painters.
  `nvTheme(n, { island: "dark" })` keeps the dark set (the WoT globe, as the classic screen does).
- **Napplets.** Reader, Compose, Media, Messages, WoT, Emoji and the Note Drafts sample use the tokens.css names
  (`--s1`, `--text-2`, `--hair`, `--on-accent`, `--danger`, …) instead of hand-copied colours; Emoji and the sample now
  ask for the `theme` domain. Emoji follows the app's Mode, not the computer's.

## Checked

- `test/napplet-theme.test.mjs` (7 tests): token list = tokens.css, unsafe values dropped, first-paint order, marker
  injected once in every themed napplet, client applies tokens/mode/island/three-colour fallback, change listener fires
  once per burst and unsubscribes.
- Browser (Chrome + WebKit, localhost build, throwaway keys, fake relay): Light first paint carries the tokens; another
  tab → Dark, accent pink, Auto + device light, device flips dark — the Reader's `--bg`/`--accent` follow each time with
  the same document (no reload); WoT stays a dark island with the pink accent. The same driver on master fails the
  first-paint, Dark, accent, device-flip and WoT checks.
