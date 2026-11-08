// Settings › Media Servers as an unsaved draft (iPhone/Mac MediaServersDraft, Android MediaServersDraft.kt): adds and
// removes only change the list on screen, Save publishes the kind 10063 once. Pure, for the tests.

/** Servers (and mesh vaults) added or removed on screen since the list was loaded or saved. A list that differs only
 *  in order still counts as one change, so Save never shows nothing to save for a list it would publish. */
export function changeCount(urls, saved) {
  const a = new Set(urls), b = new Set(saved)
  const n = [...a].filter(u => !b.has(u)).length + [...b].filter(u => !a.has(u)).length
  return n || (JSON.stringify(urls) === JSON.stringify(saved) ? 0 : 1)
}

/** "1 change", "3 changes" (MediaServersDraft.changesLabel). */
export const changesLabel = n => n === 1 ? "1 change" : `${n} changes`

/** The Save button: "Save", or "Save (2 changes)". */
export const saveLabel = n => n ? `Save (${changesLabel(n)})` : "Save"

/** Under the Save button, as the iPhone's. */
export const ONLY_SAVE = "Only Save publishes your media server list."

/** The question when leaving with unsaved changes, and what it says (iPhone/Mac confirmationDialog). */
export const leaveQuestion = n => `Save ${changesLabel(n)}?`
export const LEAVE_NOTE = "Your media server list hasn't been saved or published."
