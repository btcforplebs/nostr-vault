#ifndef FIPS_BRIDGE_H
#define FIPS_BRIDGE_H

#include <stdint.h>

/// Bind the embedded FIPS endpoint under a throwaway identity, and stand up
/// QUIC over it. Returns 0 on success, negative on failure. Idempotent.
///
/// A fresh identity every launch means a peer that saw this endpoint's npub
/// cannot reach it again, so this is for probes. An app calls
/// FipsBridgeStartWithIdentity.
int FipsBridgeStart(void);

/// As above, under a caller-supplied nsec (bech32 or hex). NULL or empty means
/// "generate a throwaway one", so this is a strict superset of the call above.
/// Persist the nsec: the npub derived from it is the address peers dial.
/// Dials the public transit seeds; call FipsBridgeStartWithOptions to choose.
int FipsBridgeStartWithIdentity(const char *nsec);

/// As above, choosing whether the public transit seeds are dialled.
/// use_public_seeds == 0 is direct only, with the identity kept.
///
/// App builds pass 0. A live seed can win the payload route, and a relayed hop
/// cannot carry the 1200-byte packets QUIC's floor needs, so a fetch from
/// another vault fails rather than running slowly. Passing 1 buys two-NAT
/// traversal at that risk. The two calls above are thin wrappers on this one:
/// FipsBridgeStart is (throwaway identity, 0), FipsBridgeStartWithIdentity is
/// (nsec, 1) — neither changed behaviour.
int FipsBridgeStartWithOptions(const char *nsec, int use_public_seeds);

/// A fresh network identity for the caller to persist. Caller frees with
/// FipsBridgeFreeString. Deliberately separate from the user's Nostr identity.
char *FipsBridgeGenerateNsec(void);

/// JSON snapshot of bridge state. Caller frees with FipsBridgeFreeString.
char *FipsBridgeStatusJSON(void);

/// Export a local TCP port to the mesh (provider role). 0 on success.
int FipsBridgeExport(uint16_t local_port);

/// Open a loopback listener proxying to `npub` over the mesh (consumer role).
/// Returns the bound loopback port, or negative on error.
int FipsBridgeIngress(const char *npub);

/// Shut down the endpoint and drop the runtime.
void FipsBridgeStop(void);

/// Free a string returned by this library.
void FipsBridgeFreeString(char *ptr);

#endif /* FIPS_BRIDGE_H */
