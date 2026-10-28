// "Is it safe?" (VaultDashboardView safetySection): your key, your follow list, a backup file. The phone's fourth
// check, a second copy on your Mac, needs the Mac app, so here it is "N of 3".
import { Row, RowButton, Section } from "./parts.jsx"
import { relative } from "../../net/vault-history.js"

/** The key row's words for a sign-in method. */
export function keyRow(method) {
  if (method === "nip46" || method === "nip07") return { title: "Your key is in a signer app", detail: "Nostr Vault asks it to sign.", done: true }
  if (method === "local") return { title: "Your key is on this device", detail: "Encrypted with your password.", done: true }
  return { title: "No key on this device", detail: "You can read, but not post or sign.", done: false }
}

export function SafetySection({ method, followSavedAt, backupAt, onBackup, backupBusy = false }) {
  const key = keyRow(method)
  const done = [key.done, !!followSavedAt, !!backupAt].filter(Boolean).length
  return (
    <Section title="Is it safe?" detail={`${done} of 3`}>
      <Row icon="key" title={key.title} detail={key.detail} state={key.done ? "done" : "todo"} href="#/accounts" />
      <Row icon="people" title="Follow list saved" href="#/settings/following-backup" state={followSavedAt ? "done" : "todo"}
        detail={followSavedAt ? `Last saved ${relative(followSavedAt)}.` : "Not saved yet. If a client wipes it, you can't get it back."} />
      <Row icon="zip" title="Backup file" state={backupAt ? "done" : "todo"}
        detail={backupAt ? `Last made ${relative(backupAt)}.` : "Never made. Keep one somewhere off this device."}>
        <RowButton title={backupAt ? "Make new" : "Make one"} busy={backupBusy} onClick={onBackup} />
      </Row>
    </Section>
  )
}
