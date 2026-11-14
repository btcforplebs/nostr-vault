# Napplets P5: Vault › Media as the Media napplet, NAP-BLOSSOM in the shell, video in the Reader

Plan: RESEARCH/NV_WEB_NAPPLET_PLAN.md §6 (P5). Local only: nothing published, nothing deployed.

## What changes for the user

With the napplet switch on:

- **Vault › Media** (All, Photos, Videos, GIFs) is the Media napplet (`napplets/media/index.html`, `MediaPane.jsx`).
  It shows your files on your media servers, merged by hash and badged with how many of your servers hold each
  one. You can filter, sort (newest, oldest, type, kept in its storage) and open a file. The file view shows its
  link, which servers hold it, **Copy link**, **Copy to missing servers**, **Delete from mirrors**, and plays video
  and audio on a tap. **Upload** sends one or more files. "In your notes" stays the classic grid.
- **The Reader** plays a note's video on a tap, from bytes the shell fetches.

Switch off: the classic Media page and the classic feed, unchanged.

## NAP-BLOSSOM in the shell (`src/napplet/blossom-dispatch.js`)

This is napplet/naps PR 71's wire (`{ type, id, request }` → `{ type: "<type>.result", id, result | error }`), the
subset the Media napplet needs:

| Request | What the shell does |
|---|---|
| `blossom.servers` | The user's media servers (kind 10063, else the defaults). |
| `blossom.list { server, pubkey }` | That server's list, signed if it wants that. Only the user's own servers and pubkey. Descriptors only (url, sha256, size, type, uploaded). |
| `blossom.mirror { server, url, sha256 }` | BUD-04 copy to one of the user's servers. https url and a hash are required. |
| `blossom.delete { server, sha256 }` | BUD-02 delete from one of the user's servers. The user is **always asked first, our own napplet included**, once per file for a minute: Delete from mirrors is one request per server and one question. The shell builds the target from server + hash, checks the server isn't the user's own vault (that one keeps its copy, 409), and scopes the auth to that server. |
| anything else | `unsupported`. Bytes come through `resource`, uploads through `upload`. |

- **Signing:** every Blossom auth (kind 24242) is signed by the shell's existing gallery and upload code
  (`net/blossom-gallery.js`, `net/upload.js`) and never reaches a napplet. `policy.js` is unchanged: 24242 stays
  NEVER_SIGN for napplets.
- **Outside napplets:** they need the private-data grant to see the server list or the file list, and are asked
  before a mirror. Grant rules are unchanged; `blossom` is now one of the domains the consent sheet can offer.

## Not in P5 yet

- **Long video:** it arrives whole (up to the shell's 100 MB cap) before it plays. A ranged/streaming player
  (MediaSource over `resource.bytes` ranges) is the next step.
- **Shim timeouts:** uploads and `resource.bytes` time out after 30 s, so very large files on a slow link fail.
- **Missing from the classic page:** the "Posted in N notes" list, the file-notes live tiles, the per-server stats
  panel, and testing a server.
- **Copy link:** falls back to selecting the text where the frame's clipboard is refused.

## Checked

- `npm test`: 2356, 10 new (`napplet-media.test.mjs`: the napplet's pure block as shipped, plus every blossom
  rule). Mutation: dropping the delete ask, or the own-pubkey check, each turns a test red.
- **Real app** (headless Chrome, vite dev, throwaway key; a fake relay holds its 10063; two fake Blossom servers):
  - Grid: 3 files from 2 servers, Today/Yesterday sections, Videos filter shows 1.
  - File view: photo bytes shown, hosts 1 of 2. Copy to missing → `PUT /mirror` on the missing server with a
    24242 `upload` auth.
  - Delete from mirrors: **one** question, then for each server an own-vault check (`GET /`, NIP-11) followed by
    `DELETE` with a 24242 `delete` auth scoped to that server.
  - Upload → `HEAD` + `PUT /upload`; the list reloads.
  - Video plays from bytes in both the Media viewer and the Reader.
  - Every Blossom request came from the vault's own page, none from a napplet's origin.
- **Bugs caught before merge:** the filter chips overflowed (Videos and GIFs hidden), the Delete button was red text
  on orange, and the ask sheet had "…." punctuation.
