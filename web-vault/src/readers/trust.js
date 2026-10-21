// Global on the web of trust, for the reader feeds (the iPhone's FeedService.globalTrustSet and trustScopedFilters):
// who a Global view may show is you, your follows and the people they follow (net/popular.js trustSet, the same set
// Popular counts with). With no follows there is no web, and Global fails closed.
import { trustSet } from "../net/popular.js"

/** How many trusted authors the first filter names (FeedService.trustedAuthorsCap). */
export const TRUSTED_AUTHORS_CAP = 500

/** The filter once for trusted authors, so a page of strangers can't crowd them out, then once open for the trusted
 *  past the cap. The caller still keeps only trusted authors from both. */
export function trustedFilters(base, trust) {
  return [{ ...base, authors: [...trust].sort().slice(0, TRUSTED_AUTHORS_CAP) }, base]
}

/** The trust set, or null when there is no web yet (no follows). `trustOf` is for tests. */
export const globalTrust = async (me, follows, trustOf = trustSet) => (follows.length ? trustOf(me, follows) : null)
