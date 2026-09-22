#ifndef FIPS_BRIDGE_H
#define FIPS_BRIDGE_H

#include <stdint.h>

/// Bind the embedded FIPS endpoint and stand up QUIC over it.
/// Returns 0 on success, negative on failure. Idempotent.
int FipsBridgeStart(void);

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
