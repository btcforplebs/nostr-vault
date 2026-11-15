# Step 2a: a note opens beside the list, and right-click works over the Reader

Plan: OUTBOX/NV_WEB_ONE_PLAN.md step 2 (part 1 of 2; the full composer is 2b).

- **Beside the list.** A tapped note (row, quoted note, kind card, j/k + Enter) asks the shell `napplet:note/beside`;
  the desktop shell puts `?note=<id>` in the address and the thread opens in the detail column as a second Reader
  (opened with `{ id, side: true }`: no title or Post of its own, the shell's bar names it and closes it with ×/Esc).
  Refused (the phone, an older shell, a thread already open in this Reader) the Reader opens it in place as before.
  The list Reader keeps its feed and scroll and marks the open row (`inc nv.note.open`).
- **Two columns where there's room.** `SplitPane beside` (napplets on, Feed): from 1000px of left column (container
  query in styles/desktop.css) the list stays on the left and the thread sits on the right; narrower, the thread
  covers the list with ‹ Back, as the classic desktop does.
- **Right-click.** The Reader passes a right-click on a note (the signed event) or a name (pubkey) as `inc nv.ctx`
  with frame coordinates; ReaderPane checks the signature (likedNote), moves the point into the page (`pageMenu`) and
  the shell's own ContextMenu opens (Copy link/ID/text, Quote, Report, Block; or the person menu). Shift, a link,
  a picture or a field keep the browser's menu; selected text too, read at pointerdown because Safari selects the word
  under a right-click.
- **Reply counts:** the classic desktop feed has none on rows (only threads, which the Reader already shows, plus the
  "N replies from outside your web" line), so nothing to catch up there.

Checked: test/napplet-beside.test.mjs (4); Chrome + WebKit at 1440x900, throwaway keys + fake relay: tap -> `?note=`,
side Reader with the focus row, list unchanged with the row marked and still on screen, right-click on a note and on
a name open the shell's menus.
