// Box screen, Public on the web (PublicOnWeb.jsx) for the box's own web address. `state`: the status call's { value } | { error }.
import { Part } from "./Parts.jsx"
import { PublicOnWeb } from "../PublicOnWeb.jsx"

export function PublicSection({ ctx, state }) {
  const status = state?.value
  return (
    <Part title="Public on the web" state={state}>
      {status && <PublicOnWeb ctx={ctx} relayUrl={status.relay_url} />}
    </Part>
  )
}
