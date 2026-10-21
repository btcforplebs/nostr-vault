// nvfips: the FIPS mesh engine, C ABI for the iOS app.
// Return codes: 0 ok; -1 config, -2 unsupported, -3 not running,
// -4 a different port is already shared, -5 start failed, -6 bad npub,
// -7 relay link off (no relay_socket at start), -8 not a list of signed events,
// -9 ingress to an npub outside own_devices.
// Strings returned here are freed with NvFipsFreeString.
#ifndef NVFIPS_H
#define NVFIPS_H

#include <stdint.h>

int32_t NvFipsStart(const char *nsec, const char *options_json);
char *NvFipsGenerateNsec(void);
char *NvFipsStatusJSON(void);
int32_t NvFipsExport(uint16_t port);
int32_t NvFipsUnexport(void);
// Blocks up to 10 s: call off the main thread. On 0, *url_out is a URL base,
// http://127.0.0.1:<port>/<token>; append the path. The token keeps other
// apps out: never log it.
int32_t NvFipsIngress(const char *npub, char **url_out);
// Hand signed events (one JSON object or a list) to the browser relay page
// `relay_npub` over the mesh. Blocks up to timeout_ms: call off the main
// thread. On 0, *result_out is the result JSON ({"ok":…,"acks":…}).
int32_t NvFipsRelayPush(const char *relay_npub, const char *events_json,
                        uint32_t timeout_ms, char **result_out);
void NvFipsStop(void);
void NvFipsFreeString(char *s);

#endif
