//! libcurl's "easy" interface through hand-written declarations: one blocking HTTP(S) GET with timeouts and a response size cap, used by the session-server worker threads.
//! Each worker owns its own `Easy` handle (curl handles are not shared between threads); connections are kept alive between requests by the handle.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_long, c_void};
use std::sync::Once;

// libcurl is linked by its soname: only libcurl.so.4 is installed here (no libcurl-dev symlink), and `+verbatim` passes the name to the linker unchanged (-l:libcurl.so.4).
#[link(name = "libcurl.so.4", kind = "dylib", modifiers = "+verbatim")]
extern "C" {
    fn curl_global_init(flags: c_long) -> c_int;
    fn curl_easy_init() -> *mut c_void;
    fn curl_easy_cleanup(h: *mut c_void);
    fn curl_easy_setopt(h: *mut c_void, option: c_int, ...) -> c_int;
    fn curl_easy_perform(h: *mut c_void) -> c_int;
    fn curl_easy_getinfo(h: *mut c_void, info: c_int, ...) -> c_int;
    fn curl_easy_strerror(code: c_int) -> *const c_char;
}

const CURL_GLOBAL_DEFAULT: c_long = 3;
const CURLOPT_WRITEDATA: c_int = 10001;
const CURLOPT_URL: c_int = 10002;
const CURLOPT_USERAGENT: c_int = 10018;
const CURLOPT_FOLLOWLOCATION: c_int = 52;
const CURLOPT_NOSIGNAL: c_int = 99;
const CURLOPT_TIMEOUT_MS: c_int = 155;
const CURLOPT_CONNECTTIMEOUT_MS: c_int = 156;
const CURLOPT_WRITEFUNCTION: c_int = 20011;
const CURLOPT_PROTOCOLS_STR: c_int = 10318;
const CURLINFO_RESPONSE_CODE: c_int = 0x200000 + 2;

static INIT: Once = Once::new();

/// Must run once before any other thread uses curl (curl_global_init is not thread-safe).  Idempotent.
pub fn global_init() {
    INIT.call_once(|| {
        // SAFETY: called once, before worker threads exist (main calls this at start); the argument is a valid flag set.
        unsafe { curl_global_init(CURL_GLOBAL_DEFAULT) };
    });
}

struct Body {
    buf: Vec<u8>,
    cap: usize,
    overflow: bool,
}

extern "C" fn write_cb(ptr: *mut c_char, size: usize, nmemb: usize, userdata: *mut c_void) -> usize {
    let n = match size.checked_mul(nmemb) {
        Some(n) => n,
        None => return 0,
    };
    // SAFETY: `userdata` is the `Body` that `get` passed to CURLOPT_WRITEDATA and keeps alive for the duration of curl_easy_perform; curl guarantees `ptr` points to `n` readable bytes.
    let body = unsafe { &mut *(userdata as *mut Body) };
    if body.buf.len() + n > body.cap {
        body.overflow = true;
        return 0; // returning less than n aborts the transfer (CURLE_WRITE_ERROR)
    }
    let data = unsafe { std::slice::from_raw_parts(ptr as *const u8, n) };
    body.buf.extend_from_slice(data);
    n
}

#[derive(Debug)]
pub enum CurlError {
    Init,
    Setup(&'static str),
    /// curl_easy_perform failed (resolve, connect, timeout, TLS, aborted by the size cap ...)
    Transfer(String),
    TooLarge,
}

pub struct Easy {
    h: *mut c_void,
}

// A handle is used by one thread at a time (the worker that owns it).
unsafe impl Send for Easy {}

impl Easy {
    pub fn new() -> Result<Easy, CurlError> {
        global_init();
        // SAFETY: plain call, result checked.
        let h = unsafe { curl_easy_init() };
        if h.is_null() {
            return Err(CurlError::Init);
        }
        Ok(Easy { h })
    }

    /// GET `url` (http or https only, no redirects).  Returns (HTTP status, body of at most `cap` bytes).
    pub fn get(&mut self, url: &str, timeout_ms: u64, cap: usize) -> Result<(u32, Vec<u8>), CurlError> {
        let url_c = CString::new(url).map_err(|_| CurlError::Setup("url contains NUL"))?;
        let ua = CString::new("dbcraft-gateway/0.1").unwrap();
        let protocols = CString::new("http,https").unwrap();
        let mut body = Body { buf: Vec::new(), cap, overflow: false };
        let timeout = timeout_ms.min(i32::MAX as u64) as c_long;
        // SAFETY: every option receives the type libcurl documents for it (long, string pointer, function pointer, data pointer); the strings and `body` outlive the perform call below
        // (curl copies the strings it keeps); the write callback has the signature libcurl expects.
        unsafe {
            let ok = |rc: c_int| rc == 0;
            if !ok(curl_easy_setopt(self.h, CURLOPT_URL, url_c.as_ptr()))
                || !ok(curl_easy_setopt(self.h, CURLOPT_USERAGENT, ua.as_ptr()))
                || !ok(curl_easy_setopt(self.h, CURLOPT_PROTOCOLS_STR, protocols.as_ptr()))
                || !ok(curl_easy_setopt(self.h, CURLOPT_FOLLOWLOCATION, 0 as c_long))
                || !ok(curl_easy_setopt(self.h, CURLOPT_NOSIGNAL, 1 as c_long))
                || !ok(curl_easy_setopt(self.h, CURLOPT_TIMEOUT_MS, timeout))
                || !ok(curl_easy_setopt(self.h, CURLOPT_CONNECTTIMEOUT_MS, timeout))
                || !ok(curl_easy_setopt(self.h, CURLOPT_WRITEFUNCTION, write_cb as extern "C" fn(*mut c_char, usize, usize, *mut c_void) -> usize))
                || !ok(curl_easy_setopt(self.h, CURLOPT_WRITEDATA, &mut body as *mut Body as *mut c_void))
            {
                return Err(CurlError::Setup("curl_easy_setopt failed"));
            }
            let rc = curl_easy_perform(self.h);
            if body.overflow {
                return Err(CurlError::TooLarge);
            }
            if rc != 0 {
                let msg = CStr::from_ptr(curl_easy_strerror(rc)).to_string_lossy().into_owned();
                return Err(CurlError::Transfer(msg));
            }
            let mut code: c_long = 0;
            if curl_easy_getinfo(self.h, CURLINFO_RESPONSE_CODE, &mut code as *mut c_long) != 0 {
                return Err(CurlError::Transfer("no response code".into()));
            }
            Ok((code.max(0) as u32, body.buf))
        }
    }
}

impl Drop for Easy {
    fn drop(&mut self) {
        // SAFETY: we own the handle and free it once.
        unsafe { curl_easy_cleanup(self.h) };
    }
}

/// Percent-encodes everything except the RFC 3986 unreserved characters.
pub fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn percent_encoding() {
        assert_eq!(percent_encode("Notch_1"), "Notch_1");
        assert_eq!(percent_encode("a b&c=d"), "a%20b%26c%3Dd");
        assert_eq!(percent_encode("-7c9d"), "-7c9d");
        assert_eq!(percent_encode("é"), "%C3%A9");
    }
    #[test]
    fn a_closed_port_is_a_transfer_error_not_a_panic() {
        let mut e = Easy::new().unwrap();
        match e.get("http://127.0.0.1:1/x", 500, 1024) {
            Err(CurlError::Transfer(_)) => {}
            other => panic!("expected a transfer error, got {other:?}"),
        }
    }
}
