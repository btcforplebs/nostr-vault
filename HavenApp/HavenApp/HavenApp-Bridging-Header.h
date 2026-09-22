#ifndef HavenApp_Bridging_Header_h
#define HavenApp_Bridging_Header_h

#include "../build/libhaven.h"
// The Rust FIPS mesh bridge. Copied into build/ by build_fips_macos.sh so
// this include and libhaven.h resolve through the same search path.
#include "../build/fips_bridge.h"

#endif /* HavenApp_Bridging_Header_h */
