/**
 * FipsBridgeJNI.c
 *
 * JNI glue between Kotlin FipsBridge and the Rust C ABI exported by
 * libfips_bridge_ffi.so (fips-bridge/crates/fips-bridge-ffi).
 *
 * Mirrors HavenBridgeJNI.c on purpose: one FFI surface across macOS, iOS and
 * Android, no `jni` crate on the Rust side, and no AttachCurrentThread anywhere
 * — the bridge is polled, so nothing ever calls back into the JVM.
 *
 * Ownership: every char* the Rust side returns is freed with
 * FipsBridgeFreeString, never free(). They are the same allocator today, but a
 * Rust CString is Rust's to release and that is what the header promises.
 */

#include <jni.h>
#include <stdlib.h>

// Rust C-exported function declarations (fips-bridge-ffi/src/lib.rs).
extern int   FipsBridgeStart(void);
extern int   FipsBridgeStartWithIdentity(const char* nsec);
extern char* FipsBridgeGenerateNsec(void);
extern char* FipsBridgeStatusJSON(void);
extern int   FipsBridgeExport(unsigned short localPort);
extern int   FipsBridgeIngress(const char* npub);
extern void  FipsBridgeStop(void);
extern void  FipsBridgeFreeString(char* ptr);

// Helper: convert a Rust-owned char* to jstring, releasing it the Rust way.
static jstring rustStringToJstring(JNIEnv *env, char *rustStr) {
    if (rustStr == NULL) return NULL;
    jstring result = (*env)->NewStringUTF(env, rustStr);
    FipsBridgeFreeString(rustStr);
    return result;
}

#define GET_CSTR(env, jstr) ((jstr) ? (*env)->GetStringUTFChars(env, jstr, NULL) : NULL)
#define REL_CSTR(env, jstr, cstr) do { if (jstr && cstr) (*env)->ReleaseStringUTFChars(env, jstr, cstr); } while(0)

JNIEXPORT jint JNICALL
Java_com_nostrvault_fips_FipsBridge_nativeStart(JNIEnv *env, jobject thiz, jstring nsec) {
    // A NULL nsec is a throwaway identity, which is what the probes use. The
    // app always passes one: an address a peer can find twice has to survive a
    // restart.
    const char *cNsec = GET_CSTR(env, nsec);
    int rc = FipsBridgeStartWithIdentity(cNsec);
    REL_CSTR(env, nsec, cNsec);
    return rc;
}

JNIEXPORT jstring JNICALL
Java_com_nostrvault_fips_FipsBridge_nativeGenerateNsec(JNIEnv *env, jobject thiz) {
    return rustStringToJstring(env, FipsBridgeGenerateNsec());
}

JNIEXPORT jstring JNICALL
Java_com_nostrvault_fips_FipsBridge_nativeStatusJSON(JNIEnv *env, jobject thiz) {
    return rustStringToJstring(env, FipsBridgeStatusJSON());
}

JNIEXPORT jint JNICALL
Java_com_nostrvault_fips_FipsBridge_nativeExport(JNIEnv *env, jobject thiz, jint localPort) {
    return FipsBridgeExport((unsigned short)localPort);
}

JNIEXPORT jint JNICALL
Java_com_nostrvault_fips_FipsBridge_nativeIngress(JNIEnv *env, jobject thiz, jstring npub) {
    const char *cNpub = GET_CSTR(env, npub);
    int rc = FipsBridgeIngress(cNpub);
    REL_CSTR(env, npub, cNpub);
    return rc;
}

JNIEXPORT void JNICALL
Java_com_nostrvault_fips_FipsBridge_nativeStop(JNIEnv *env, jobject thiz) {
    FipsBridgeStop();
}
