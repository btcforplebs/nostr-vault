# Space layout: rail pins and Your space panels

The desktop layout a user builds on one screen and finds on another: the left
rail's **pins** (the sections and the user's own favourites, in their order)
and the right column's **panels** (Your space). Kept on the user's own account,
encrypted, so the web vault and the iPad read and write the same thing.

Readers: `web-vault/src/desktop/space/space-layout.js` (web) and
`HavenApp/HavenApp/Models/SpaceLayout.swift` (iPad). Both follow this file.
If the code and this file disagree, fix one of them; do not add a rule here
that only one side keeps.

## The layout

```json
{
  "v": 1,
  "at": 1793736000,
  "pins": [
    { "type": "section", "id": "feed" },
    { "type": "section", "id": "search" },
    { "type": "list", "a": "30000:<hex pubkey>:<d>", "name": "Devs" },
    { "type": "hashtag", "t": "bitcoin" },
    { "type": "person", "p": "<hex pubkey>" },
    { "type": "relay", "url": "wss://relay.example.com" },
    { "type": "section", "id": "profile" },
    { "type": "section", "id": "wot" },
    { "type": "section", "id": "vault" }
  ],
  "panels": [
    { "id": "live-vault", "on": true, "open": true },
    { "id": "wot-mini", "on": true, "open": false },
    { "id": "messages", "on": false, "open": true }
  ]
}
```

- `v`: always `1`. An additive change (a new pin type, a new panel, a new
  field) keeps `v` at 1. A change an older reader would get wrong bumps it, and
  a reader leaves a layout with a higher `v` alone (draws its own default and
  does not write over it).
- `at`: unix seconds of the last edit, on any device. Every edit sets it.
- `pins`: the rail, top to bottom. The array's order is the order on screen.
- `panels`: Your space, top to bottom. The array's order is the order on screen.
- A writer keeps every top-level key and every entry it does not understand,
  exactly as read. That is what lets an older app and a newer one share a
  layout.

### Pins

| `type` | Field | Value | Opens |
|---|---|---|---|
| `section` | `id` | one of the section ids below | that section |
| `list` | `a` | NIP-51 address `<kind>:<hex pubkey>:<d>`, kind 30000 (follow set) or 39089 (follow pack) | a feed of the list's people |
| `person` | `p` | 64-char lowercase hex pubkey | their profile |
| `hashtag` | `t` | the tag, lowercase, no `#` | the hashtag feed |
| `relay` | `url` | `wss://` URL, host lowercased, no trailing `/` | that relay's notes |

- `name` (optional, any pin): the label at the time it was pinned, so the rail
  can draw it before the list or profile loads. The live name wins once known.
- **Section ids:** `feed`, `search`, `profile`, `wot`, `vault`, `messages`,
  `notifications`, `relay`, `settings`. They are the web's route names
  (`desktop/routes.js`). The iPad rail has `feed`, `search`, `profile`, `wot`,
  `vault` today.
- **Sections can move, not go.** The rail is how you get around, so a section
  pin is never removed. A layout that leaves out a section this app has gets it
  back at its default place (as for panels, below).
- **Favourites** (every type but `section`) can be added, moved and removed.
  At most 30. The same favourite is in the list once: two pins are the same
  when `type` and the value field are equal (after the normalising in the
  table).
- A section this app does not have (for example `notifications` on the iPad)
  and a pin `type` it does not know are kept in place and not drawn.

**Default pins:** the sections only, in this order: `feed`, `search`,
`profile`, `wot`, `vault`, `messages`, `notifications`, `relay`, `settings`.
Each app draws the ones it has.

### Panels

The `panels` rules are the ones `space-layout.js` already keeps:

- `id`: `live-vault`, `wot-mini`, `messages`, `my-devices`, `live-now`, `on-this-day` (`desktop/space/panels.js`). Ids
  are never renamed.
- `on`: drawn. A panel taken off stays in the array, so shown again it goes
  back where it was. Its live work (fetches, globe) stops while it is off.
- `open`: `false` draws only its header line and its count ("Messages 3").
- An unknown id is kept in place and not drawn.
- A panel this app has that the layout does not name goes in after the known
  panel that comes before it in the default order (at the top when none does),
  shown and open.
- **Default panels:** every panel, in `panels.js` order, `on` and `open`.

Folding the whole Your space column is **not** in the layout. It stays per
device (`nv-space-folded:<pubkey>`), because a narrow window and a wide one
want different answers.

### Normalising (both readers)

Any saved value goes through `normalize` before use:

1. Not an object, or `v` missing: the default layout.
2. Entries that are not objects, have a missing or empty value field, or
   repeat an earlier entry drop out. Pin values are normalised first
   (lowercased hex and tag, `#` stripped, relay URL host lowercased and
   trailing `/` removed).
3. Unknown pin types, section ids and panel ids stay where they are.
4. Missing known sections and panels go in as described above.
5. Favourites past the 30th drop out.
6. `at` is kept if it is a finite number, else 0.

`normalize` is a pure function with tests on both sides; the iPad's
`SpaceLayoutTests` and the web's `space-layout.test.mjs` cover the same cases.

## Kept on the device

Every edit writes at once to `nv-space-layout:<pubkey>`: localStorage on the
web (wiped on sign-out with the other account keys), UserDefaults on the iPad.
The app draws from this copy, so the rail and Your space never wait on a relay.

## Synced through the user's own account

One NIP-78 app-data event, the same way the wallet backup is kept
(`Models/NWCBackup.swift`):

```json
{
  "kind": 30078,
  "tags": [["d", "nostr-vault-space-layout"], ["client", "Nostr Vault"], ["encryption", "nip44"]],
  "content": "<NIP-44 v2 ciphertext of the layout JSON, encrypted to the author's own pubkey>"
}
```

- **Write:** 2 s after the last edit (dragging makes many), publish the whole
  normalised layout to the user's own vault relay and their NIP-65 write
  relays. Never publish plaintext: check the content is ciphertext before
  sending. A remote-signer (NIP-46 / NIP-07) user is asked once per edit
  session, thanks to the debounce.
- **Read:** on launch and on account switch, fetch `kinds: [30078]`,
  `authors: [me]`, `#d: ["nostr-vault-space-layout"]` from the same relays.
  Take the event with the newest `created_at`; decrypt; `normalize`.
- **Which wins:** the one with the larger `at`, the downloaded layout or the
  copy on the device. Equal: keep the device's copy. A downloaded layout that
  wins replaces the device copy and is drawn; one that loses is ignored (and
  the device's newer copy is published, so other devices catch up).
- **Account switch:** the layout belongs to one pubkey. Writing waits until
  the encrypt is done and checks the active account is still the one that
  made the edit, else drops the write.
- **Not readable** (no key, signer refused, bad ciphertext): keep the device
  copy, do not write over the event.

A `list` pin points at the list event itself (`a`), so editing who
is on the list (in any client) changes the feed without touching the layout.
