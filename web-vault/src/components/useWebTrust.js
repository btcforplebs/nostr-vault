import { useBlocks } from "./useBlocks.js"
import { useGateWeb } from "./useGateWeb.js"
import { judge, VERDICTS } from "../net/web-gate.js"

// Inside your web for what other people send (thread replies, live chat, zappers, article comments, Tagged): the one
// gate (net/web-gate.js), with the open account's web, its own keys and its blocks. Until the follows' lists are in it
// fails closed to you and your follows, so a stranger never shows and then goes. `also`: keys this view always shows
// (the note's author, the stream's host). A blocked person is never inside.
export function useWebTrust(ctx) {
  const { blocked } = useBlocks(ctx)
  const gate = useGateWeb(ctx, blocked)
  const verdict = (pk, also = []) => judge({ signer: pk ?? "", related: [], muted: [], refs: [] }, gate, { always: also })
  return { gate, verdict, inside: (pk, also = []) => verdict(pk, also) === VERDICTS.inside }
}
