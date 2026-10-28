// Who did it, as the phone's Vault and notification rows show it (VaultActivityRow): the faces and the names. Styled by
// styles/notifications.css, which the app loads with the Notifications screen.
import { Avatar } from "./Avatar.jsx"
import { AuthorName } from "./NoteCard.jsx"

/** The faces of who did it, overlapping, six at most and "+N" for the rest (VaultActivityRow.avatars). */
export const MAX_FACES = 6
export function Faces({ who, trusted = () => false }) {
  return (
    <span class="notif-faces" aria-hidden="true">
      {who.slice(0, MAX_FACES).map(pk => <Avatar key={pk} pubkey={pk} size={30} load={trusted(pk)} />)}
      {who.length > MAX_FACES && <span class="notif-more">+{who.length - MAX_FACES}</span>}
    </span>
  )
}

/** "Ann", "Ann and Bob", "Ann and 3 others" (VaultActivityRow.who). */
export function Who({ who }) {
  const [a, b] = who
  if (!a) return "Someone"
  if (!b) return <AuthorName pubkey={a} />
  if (who.length === 2) return <><AuthorName pubkey={a} /> and <AuthorName pubkey={b} /></>
  return <><AuthorName pubkey={a} /> and {who.length - 1} others</>
}
