// The Vault tab's top-left menu (iPhone VaultTabView's mode pill): the Vault's lists, then Messages, a page of its own as
// Followers is (Logen, 2026-11-03: Messages left the toolbar, so no list wears the envelope any more), then the Vault
// Dashboard. The Vault tab and the Messages page both wear it, so each opens the other. The Messages item
// carries the unread count (useUnreadTotal, the Vault tab's own dot).
import { MODES } from "../net/vault-lists.js"
import { openDashboard } from "../net/dashboard-route.js"
import { useUnreadTotal, badgeCount } from "../components/useUnreadTotal.js"
import { ICONS, Icon, Chevron, Menu, MenuItem } from "./vault-ui.jsx"

/** Messages as one of the Vault's pages: its menu entry and where it opens. */
export const MESSAGES_PAGE = { id: "messages", title: "Messages", href: "#/messages" }
/** Bookmarks (kind 10003, BookmarksScreen.jsx), a page of its own too (parity N1). */
export const BOOKMARKS_PAGE = { id: "bookmarks", title: "Bookmarks", href: "#/bookmarks" }

/** What the closed pill and the Messages item say, from the page open (`current`: a Vault mode or "messages"), the
 *  modes with news (`fresh`) and the unread message count. Pure, for the tests. */
export function pagesMenuText(current, fresh, unread) {
  const page = current === MESSAGES_PAGE.id ? MESSAGES_PAGE : current === BOOKMARKS_PAGE.id ? BOOKMARKS_PAGE : MODES.find(x => x.id === current) ?? MODES[0]
  const elsewhere = fresh.size > 0 || (current !== MESSAGES_PAGE.id && unread > 0)
  const title = `Vault: ${page.title}${unread > 0 ? `, ${unread} unread ${unread === 1 ? "message" : "messages"}` : ""}`
  return { page, elsewhere, title, count: unread > 0 ? badgeCount(unread) : null }
}

/**
 * `current`: the page open. `onPick(mode)`: a Vault list picked (the Vault tab switches in place); without it the list
 * opens at #/vault/<mode>. No Refresh item: the Vault pages look again on their own (Logen 2026-11-04).
 */
export function VaultPagesMenu({ ctx, current, fresh = new Set(), onPick }) {
  const unread = useUnreadTotal(ctx)
  const { page, elsewhere, title, count } = pagesMenuText(current, fresh, unread)
  const pick = id => (onPick ? onPick(id) : (location.hash = `#/vault/${id}`))
  const onMessages = current === MESSAGES_PAGE.id
  return (
    <Menu label={<><Icon d={ICONS[onMessages ? "envelope" : page.id]} /><b>{page.title}</b>{elsewhere && <span class="vault-new-dot" aria-label="new on another page" />}<Chevron /></>} title={title}>
      {MODES.map(x => <MenuItem key={x.id} on={x.id === current} onClick={() => pick(x.id)}><Icon d={ICONS[x.id]} />{x.title}{fresh.has(x.id) && <span class="vault-new">New</span>}</MenuItem>)}
      <MenuItem on={onMessages} onClick={() => { if (!onMessages) location.hash = MESSAGES_PAGE.href }}>
        <Icon d={ICONS.envelope} />{MESSAGES_PAGE.title}{count && <span class="vault-count" aria-label={`${unread} unread`}>{count}</span>}
      </MenuItem>
      <MenuItem on={current === BOOKMARKS_PAGE.id} onClick={() => { if (current !== BOOKMARKS_PAGE.id) location.hash = BOOKMARKS_PAGE.href }}>
        <Icon d={ICONS.bookmarks} />{BOOKMARKS_PAGE.title}
      </MenuItem>
      <hr />
      <MenuItem onClick={openDashboard}><Icon d={ICONS.dashboard} />Vault Dashboard</MenuItem>
    </Menu>
  )
}
