//! C ABI for the iOS app (Swift through a bridging header, `nvfips.h`).
//! Same calls and return codes as the JNI side. Returned strings are owned
//! by the caller and freed with `NvFipsFreeString`.

use super::*;
use std::ffi::{CStr, CString, c_char};

fn arg(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    // SAFETY: non-null, and the caller passes a NUL-terminated string.
    unsafe { CStr::from_ptr(p) }.to_str().ok().map(str::to_owned)
}

fn out(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// A panic must not unwind into Swift; report it as a failure code.
fn guarded<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
    std::panic::catch_unwind(f).unwrap_or(fallback)
}

#[unsafe(no_mangle)]
pub extern "C" fn NvFipsStart(nsec: *const c_char, options_json: *const c_char) -> i32 {
    init_logging();
    let Some(nsec) = arg(nsec).map(Zeroizing::new) else { return ERR_CONFIG };
    let opts_raw = arg(options_json).unwrap_or_default();
    let opts: StartOptions = if opts_raw.trim().is_empty() {
        StartOptions::default()
    } else {
        match serde_json::from_str(&opts_raw) {
            Ok(o) => o,
            Err(e) => {
                tracing::warn!("mesh options: {e}");
                return ERR_CONFIG;
            }
        }
    };
    if config_yaml(&nsec, &opts).is_err() {
        return ERR_CONFIG;
    }
    guarded(ERR_START, move || match start(&nsec, &opts) {
        Ok(()) => 0,
        Err(e) => {
            tracing::warn!("mesh start failed: {e:#}");
            ERR_START
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn NvFipsGenerateNsec() -> *mut c_char {
    guarded(None, || Some(generate_nsec())).map_or(std::ptr::null_mut(), out)
}

#[unsafe(no_mangle)]
pub extern "C" fn NvFipsStatusJSON() -> *mut c_char {
    out(guarded("{\"running\":false}".to_string(), status_json))
}

#[unsafe(no_mangle)]
pub extern "C" fn NvFipsExport(port: u16) -> i32 {
    guarded(ERR_START, move || export(port))
}

#[unsafe(no_mangle)]
pub extern "C" fn NvFipsUnexport() -> i32 {
    guarded(ERR_START, unexport)
}

/// 0 and `*url_out` set (free it with `NvFipsFreeString`), or a negative
/// code and `*url_out` left alone.
#[unsafe(no_mangle)]
pub extern "C" fn NvFipsIngress(npub: *const c_char, url_out: *mut *mut c_char) -> i32 {
    if url_out.is_null() {
        return ERR_CONFIG;
    }
    let Some(npub) = arg(npub) else { return ERR_BAD_NPUB };
    match guarded(Err(ERR_START), move || ingress(&npub)) {
        Ok(url) => {
            // SAFETY: checked non-null above; the caller owns the slot.
            unsafe { *url_out = out(url) };
            0
        }
        Err(code) => code,
    }
}

/// Hand signed events to a browser relay page; see [`relay_push`]. 0 and
/// `*result_out` set to the result JSON (free it with `NvFipsFreeString`),
/// or a negative code and `*result_out` left alone. Blocks up to
/// `timeout_ms`: call it off the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn NvFipsRelayPush(
    relay_npub: *const c_char,
    events_json: *const c_char,
    timeout_ms: u32,
    result_out: *mut *mut c_char,
) -> i32 {
    if result_out.is_null() {
        return ERR_CONFIG;
    }
    let Some(relay) = arg(relay_npub) else { return ERR_BAD_NPUB };
    let Some(events) = arg(events_json) else { return ERR_BAD_EVENTS };
    let timeout = Duration::from_millis(timeout_ms.into());
    match guarded(Err(ERR_START), move || relay_push(&relay, &events, timeout)) {
        Ok(json) => {
            // SAFETY: checked non-null above; the caller owns the slot.
            unsafe { *result_out = out(json) };
            0
        }
        Err(code) => code,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn NvFipsStop() {
    guarded((), stop);
}

/// Free a string returned by this library. Null is ignored.
#[unsafe(no_mangle)]
pub extern "C" fn NvFipsFreeString(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: `s` came from `CString::into_raw` in `out`.
        drop(unsafe { CString::from_raw(s) });
    }
}
