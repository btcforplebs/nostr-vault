# Emoji note fixtures (custom emoji v1)

Shared by the Apple, Android and web PRs (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.1). Each file is one or more kind 1063
file notes as a vault's `/files` room serves them, with the result every platform must reach in `expected.json`.

An **emoji note** is a valid file note (x, m, size, one p) with `["t","nv-emoji"]`. Its `["emoji", code, url]` tags
(code = letters, digits, `_`, `-`) say which shortcodes use the image; its `["a","30030:<pk>:<d>"]` tags say which sets.
A tag that breaks those shapes is skipped, the note is still an emoji note.

**Media rule:** a hash is hidden from Media when every live note for it is an emoji note. One plain note keeps it in Media.

Signatures are not real: these test parsing only.
