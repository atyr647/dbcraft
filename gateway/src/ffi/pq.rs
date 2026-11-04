//! libpq (PostgreSQL's C client library) through hand-written declarations: connect, simple and parameterised queries (binary parameters and results), and COPY IN.
//! The wrapper owns every pointer libpq hands out and frees it exactly once; results borrow nothing from the connection after they are created (libpq results are
//! self-contained), so a `PgResult` may outlive later queries.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_uint, c_void};

#[repr(C)]
struct PGconn {
    _p: [u8; 0],
}
#[repr(C)]
struct PGresult {
    _p: [u8; 0],
}

#[link(name = "pq")]
extern "C" {
    fn PQconnectdb(conninfo: *const c_char) -> *mut PGconn;
    fn PQstatus(conn: *const PGconn) -> c_int;
    fn PQerrorMessage(conn: *const PGconn) -> *const c_char;
    fn PQfinish(conn: *mut PGconn);
    fn PQreset(conn: *mut PGconn);
    fn PQexec(conn: *mut PGconn, query: *const c_char) -> *mut PGresult;
    fn PQexecParams(
        conn: *mut PGconn,
        command: *const c_char,
        n_params: c_int,
        param_types: *const c_uint,
        param_values: *const *const c_char,
        param_lengths: *const c_int,
        param_formats: *const c_int,
        result_format: c_int,
    ) -> *mut PGresult;
    fn PQprepare(conn: *mut PGconn, stmt_name: *const c_char, query: *const c_char, n_params: c_int, param_types: *const c_uint) -> *mut PGresult;
    fn PQexecPrepared(
        conn: *mut PGconn,
        stmt_name: *const c_char,
        n_params: c_int,
        param_values: *const *const c_char,
        param_lengths: *const c_int,
        param_formats: *const c_int,
        result_format: c_int,
    ) -> *mut PGresult;
    fn PQresultStatus(res: *const PGresult) -> c_int;
    fn PQresultErrorMessage(res: *const PGresult) -> *const c_char;
    fn PQclear(res: *mut PGresult);
    fn PQntuples(res: *const PGresult) -> c_int;
    fn PQnfields(res: *const PGresult) -> c_int;
    fn PQgetvalue(res: *const PGresult, row: c_int, col: c_int) -> *const c_char;
    fn PQgetlength(res: *const PGresult, row: c_int, col: c_int) -> c_int;
    fn PQgetisnull(res: *const PGresult, row: c_int, col: c_int) -> c_int;
    fn PQputCopyData(conn: *mut PGconn, buffer: *const c_char, nbytes: c_int) -> c_int;
    fn PQputCopyEnd(conn: *mut PGconn, errormsg: *const c_char) -> c_int;
    fn PQgetResult(conn: *mut PGconn) -> *mut PGresult;
    fn PQsetNoticeProcessor(conn: *mut PGconn, proc_: Option<extern "C" fn(*mut c_void, *const c_char)>, arg: *mut c_void) -> Option<extern "C" fn(*mut c_void, *const c_char)>;
}

const CONNECTION_OK: c_int = 0;
const PGRES_COMMAND_OK: c_int = 1;
const PGRES_TUPLES_OK: c_int = 2;
const PGRES_COPY_IN: c_int = 4;

pub const OID_BYTEA: u32 = 17;
pub const OID_INT8: u32 = 20;
pub const OID_INT4: u32 = 23;
pub const OID_TEXT: u32 = 25;
pub const OID_FLOAT8: u32 = 701;
pub const OID_INT8_ARRAY: u32 = 1016;
pub const OID_BYTEA_ARRAY: u32 = 1001;
pub const OID_TEXT_ARRAY: u32 = 1009;

#[derive(Debug)]
pub struct PgError(pub String);
impl std::fmt::Display for PgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for PgError {}

extern "C" fn ignore_notice(_arg: *mut c_void, _msg: *const c_char) {}

fn cstr_lossy(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    // SAFETY: libpq returns NUL-terminated strings that stay valid until the owning object is freed; we copy immediately.
    unsafe { CStr::from_ptr(p) }.to_string_lossy().trim().to_string()
}

/// One query parameter.  `val = None` is SQL NULL.  Text-format values must not contain NUL bytes.
pub struct Param<'a> {
    pub oid: u32,
    pub val: Option<&'a [u8]>,
    pub binary: bool,
}

impl<'a> Param<'a> {
    pub fn text(oid: u32, s: &'a str) -> Param<'a> {
        Param { oid, val: Some(s.as_bytes()), binary: false }
    }
    pub fn null(oid: u32) -> Param<'a> {
        Param { oid, val: None, binary: false }
    }
    pub fn bin(oid: u32, b: &'a [u8]) -> Param<'a> {
        Param { oid, val: Some(b), binary: true }
    }
}

/// The parameter arrays libpq wants, built from `Param`s.  Text-format values are copied with a NUL terminator; binary ones are borrowed.
struct Marshalled {
    texts: Vec<Vec<u8>>,
    types: Vec<c_uint>,
    values: Vec<*const c_char>,
    lengths: Vec<c_int>,
    formats: Vec<c_int>,
}

impl Marshalled {
    fn n(&self) -> c_int {
        self.types.len() as c_int
    }

    fn new(params: &[Param]) -> Result<Marshalled, PgError> {
        if params.len() > i32::MAX as usize {
            return Err(PgError("too many parameters".into()));
        }
        let n = params.len();
        let mut m = Marshalled { texts: Vec::with_capacity(n), types: Vec::with_capacity(n), values: Vec::with_capacity(n), lengths: Vec::with_capacity(n), formats: Vec::with_capacity(n) };
        for p in params {
            m.types.push(p.oid);
            match p.val {
                None => {
                    m.values.push(std::ptr::null());
                    m.lengths.push(0);
                    m.formats.push(0);
                }
                Some(b) if p.binary => {
                    if b.len() > i32::MAX as usize {
                        return Err(PgError("parameter too large".into()));
                    }
                    m.values.push(b.as_ptr() as *const c_char);
                    m.lengths.push(b.len() as c_int);
                    m.formats.push(1);
                }
                Some(b) => {
                    if b.contains(&0) {
                        return Err(PgError("text parameter contains NUL".into()));
                    }
                    let mut v = Vec::with_capacity(b.len() + 1);
                    v.extend_from_slice(b);
                    v.push(0);
                    m.texts.push(v);
                    m.values.push(std::ptr::null()); // patched below once `texts` stops growing
                    m.lengths.push(0);
                    m.formats.push(0);
                }
            }
        }
        // second pass: point text parameters at their NUL-terminated copies (texts no longer reallocates)
        let mut ti = 0;
        for (i, p) in params.iter().enumerate() {
            if p.val.is_some() && !p.binary {
                m.values[i] = m.texts[ti].as_ptr() as *const c_char;
                ti += 1;
            }
        }
        Ok(m)
    }
}

pub struct Pg {
    conn: *mut PGconn,
    url: CString,
    /// names of the statements prepared on the current connection (a reset forgets them)
    prepared: Vec<String>,
}

// A connection is used by exactly one thread at a time (the loop thread owns it); libpq connections may move between threads.
unsafe impl Send for Pg {}

impl Pg {
    pub fn connect(url: &str) -> Result<Pg, PgError> {
        let url = CString::new(url).map_err(|_| PgError("connection string contains NUL".into()))?;
        // SAFETY: `url` is a valid NUL-terminated string; PQconnectdb always returns a (possibly failed) connection object that we must free.
        let conn = unsafe { PQconnectdb(url.as_ptr()) };
        if conn.is_null() {
            return Err(PgError("PQconnectdb returned null (out of memory)".into()));
        }
        let ok = unsafe { PQstatus(conn) } == CONNECTION_OK;
        if !ok {
            let msg = cstr_lossy(unsafe { PQerrorMessage(conn) });
            unsafe { PQfinish(conn) };
            return Err(PgError(format!("connection failed: {msg}")));
        }
        // SAFETY: valid connection; the callback ignores its arguments.
        unsafe { PQsetNoticeProcessor(conn, Some(ignore_notice), std::ptr::null_mut()) };
        Ok(Pg { conn, url, prepared: Vec::new() })
    }

    pub fn is_ok(&self) -> bool {
        // SAFETY: self.conn is valid for the life of self.
        unsafe { PQstatus(self.conn) == CONNECTION_OK }
    }

    /// Re-establishes a lost connection with the same connection string.
    pub fn reset(&mut self) -> bool {
        // SAFETY: valid connection.
        unsafe { PQreset(self.conn) };
        self.prepared.clear();
        let _ = &self.url;
        self.is_ok()
    }

    fn last_error(&self) -> String {
        cstr_lossy(unsafe { PQerrorMessage(self.conn) })
    }

    fn wrap(&self, res: *mut PGresult, binary: bool) -> Result<PgResult, PgError> {
        if res.is_null() {
            return Err(PgError(format!("no result: {}", self.last_error())));
        }
        let r = PgResult { res, binary };
        match r.status() {
            PGRES_COMMAND_OK | PGRES_TUPLES_OK | PGRES_COPY_IN => Ok(r),
            _ => Err(PgError(r.error_message())),
        }
    }

    /// Simple query (text protocol, no parameters).  Several statements separated by `;` are allowed; only the last result is returned.
    pub fn exec(&mut self, sql: &str) -> Result<PgResult, PgError> {
        let c = CString::new(sql).map_err(|_| PgError("SQL contains NUL".into()))?;
        // SAFETY: valid connection and NUL-terminated statement.
        let res = unsafe { PQexec(self.conn, c.as_ptr()) };
        self.wrap(res, false)
    }

    /// Parameterised query.  `binary_result`: ask for binary-format columns (bigint = 8 bytes big-endian, bytea = raw bytes, boolean = 1 byte, text = the bytes).
    pub fn query(&mut self, sql: &str, params: &[Param], binary_result: bool) -> Result<PgResult, PgError> {
        let c = CString::new(sql).map_err(|_| PgError("SQL contains NUL".into()))?;
        let m = Marshalled::new(params)?;
        // SAFETY: all arrays have `n` elements; every non-null value pointer stays valid (borrowed slices / `m.texts`) until the call returns; libpq copies what it needs.
        let res = unsafe {
            PQexecParams(self.conn, c.as_ptr(), m.n(), m.types.as_ptr(), m.values.as_ptr(), m.lengths.as_ptr(), m.formats.as_ptr(), if binary_result { 1 } else { 0 })
        };
        self.wrap(res, binary_result)
    }

    /// Prepares `sql` under `name` once per connection (the server parses and plans it once; docs/PERF-IDLE2.md: an idle tick is two statements 20 times a second).
    /// `types` are the parameter type oids.  Does nothing when the statement is already prepared on this connection.
    pub fn prepare(&mut self, name: &str, sql: &str, types: &[u32]) -> Result<(), PgError> {
        if self.prepared.iter().any(|n| n == name) {
            return Ok(());
        }
        let (n, c) = (CString::new(name).map_err(|_| PgError("name contains NUL".into()))?, CString::new(sql).map_err(|_| PgError("SQL contains NUL".into()))?);
        // SAFETY: valid connection, NUL-terminated strings, `types` has `types.len()` entries.
        let res = unsafe { PQprepare(self.conn, n.as_ptr(), c.as_ptr(), types.len() as c_int, if types.is_empty() { std::ptr::null() } else { types.as_ptr() }) };
        self.wrap(res, false)?;
        self.prepared.push(name.to_string());
        Ok(())
    }

    /// Runs a statement prepared with `prepare` (same parameter and result conventions as `query`).
    pub fn query_prepared(&mut self, name: &str, params: &[Param], binary_result: bool) -> Result<PgResult, PgError> {
        let c = CString::new(name).map_err(|_| PgError("name contains NUL".into()))?;
        let m = Marshalled::new(params)?;
        // SAFETY: as in `query`; the statement name is NUL-terminated.
        let res = unsafe { PQexecPrepared(self.conn, c.as_ptr(), m.n(), m.values.as_ptr(), m.lengths.as_ptr(), m.formats.as_ptr(), if binary_result { 1 } else { 0 }) };
        self.wrap(res, binary_result)
    }

    /// COPY ... FROM STDIN: `copy_sql` must be a COPY statement; `data` is sent as one stream (in chunks of at most 1 MiB), then the copy is ended.
    pub fn copy_in(&mut self, copy_sql: &str, data: &[u8]) -> Result<(), PgError> {
        let r = self.exec(copy_sql)?;
        if r.status() != PGRES_COPY_IN {
            return Err(PgError("COPY did not enter copy-in mode".into()));
        }
        drop(r);
        for chunk in data.chunks(1 << 20) {
            // SAFETY: valid connection in copy-in mode; the chunk is at most 1 MiB so its length fits c_int.
            let rc = unsafe { PQputCopyData(self.conn, chunk.as_ptr() as *const c_char, chunk.len() as c_int) };
            if rc != 1 {
                let msg = self.last_error();
                self.finish_copy_after_error();
                return Err(PgError(format!("PQputCopyData: {msg}")));
            }
        }
        // SAFETY: valid connection; a null error message means "end normally".
        let rc = unsafe { PQputCopyEnd(self.conn, std::ptr::null()) };
        if rc != 1 {
            let msg = self.last_error();
            self.finish_copy_after_error();
            return Err(PgError(format!("PQputCopyEnd: {msg}")));
        }
        // collect the final result(s)
        let mut err: Option<String> = None;
        loop {
            // SAFETY: valid connection.
            let res = unsafe { PQgetResult(self.conn) };
            if res.is_null() {
                break;
            }
            let r = PgResult { res, binary: false };
            if r.status() != PGRES_COMMAND_OK {
                err = Some(r.error_message());
            }
        }
        match err {
            None => Ok(()),
            Some(e) => Err(PgError(e)),
        }
    }

    fn finish_copy_after_error(&mut self) {
        // SAFETY: valid connection; asks the server to abort the copy and drains the results so the connection is usable again.
        unsafe {
            let msg = b"aborted by the gateway\0";
            PQputCopyEnd(self.conn, msg.as_ptr() as *const c_char);
            loop {
                let res = PQgetResult(self.conn);
                if res.is_null() {
                    break;
                }
                PQclear(res);
            }
        }
    }
}

impl Drop for Pg {
    fn drop(&mut self) {
        // SAFETY: we own the connection and free it exactly once.
        unsafe { PQfinish(self.conn) };
    }
}

pub struct PgResult {
    res: *mut PGresult,
    binary: bool,
}

impl PgResult {
    fn status(&self) -> c_int {
        // SAFETY: self.res is a valid result until Drop.
        unsafe { PQresultStatus(self.res) }
    }
    fn error_message(&self) -> String {
        cstr_lossy(unsafe { PQresultErrorMessage(self.res) })
    }
    pub fn rows(&self) -> usize {
        // SAFETY: valid result.
        unsafe { PQntuples(self.res) }.max(0) as usize
    }
    pub fn cols(&self) -> usize {
        unsafe { PQnfields(self.res) }.max(0) as usize
    }
    pub fn is_null(&self, row: usize, col: usize) -> bool {
        if row >= self.rows() || col >= self.cols() {
            return true;
        }
        unsafe { PQgetisnull(self.res, row as c_int, col as c_int) == 1 }
    }
    /// The raw bytes of a cell (text-format: the text; binary-format: the binary value).  `None` for NULL or out-of-range.
    pub fn bytes(&self, row: usize, col: usize) -> Option<&[u8]> {
        if self.is_null(row, col) {
            return None;
        }
        // SAFETY: row/col are in range (checked above); PQgetvalue returns a pointer to `PQgetlength` readable bytes owned by the result, valid until PQclear (Drop),
        // and the returned slice borrows `self`.
        unsafe {
            let p = PQgetvalue(self.res, row as c_int, col as c_int);
            let n = PQgetlength(self.res, row as c_int, col as c_int).max(0) as usize;
            if p.is_null() {
                return None;
            }
            Some(std::slice::from_raw_parts(p as *const u8, n))
        }
    }
    pub fn text(&self, row: usize, col: usize) -> Option<String> {
        self.bytes(row, col).map(|b| String::from_utf8_lossy(b).into_owned())
    }
    /// An integer cell (smallint, integer or bigint), in either result format.
    pub fn int(&self, row: usize, col: usize) -> Option<i64> {
        let b = self.bytes(row, col)?;
        if self.binary {
            match b.len() {
                2 => Some(i16::from_be_bytes([b[0], b[1]]) as i64),
                4 => Some(i32::from_be_bytes([b[0], b[1], b[2], b[3]]) as i64),
                8 => Some(i64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])),
                _ => None,
            }
        } else {
            std::str::from_utf8(b).ok()?.trim().parse().ok()
        }
    }
    pub fn boolean(&self, row: usize, col: usize) -> Option<bool> {
        let b = self.bytes(row, col)?;
        if self.binary {
            b.first().map(|v| *v != 0)
        } else {
            match b {
                b"t" | b"true" => Some(true),
                b"f" | b"false" => Some(false),
                _ => None,
            }
        }
    }
}

impl Drop for PgResult {
    fn drop(&mut self) {
        // SAFETY: we own the result and free it exactly once.
        unsafe { PQclear(self.res) };
    }
}

// ---- binary array / COPY encoders (pure, tested without a database) --------------------------------------------------------------------------------------

/// PostgreSQL's binary array format for a one-dimensional array without NULLs: ndim, flags, element oid, (size, lower bound), then (length, bytes) per element.
fn array_header(out: &mut Vec<u8>, elem_oid: u32, n: usize) {
    if n == 0 {
        out.extend_from_slice(&0i32.to_be_bytes()); // ndim 0: the empty array
        out.extend_from_slice(&0i32.to_be_bytes());
        out.extend_from_slice(&(elem_oid as i32).to_be_bytes());
        return;
    }
    out.extend_from_slice(&1i32.to_be_bytes());
    out.extend_from_slice(&0i32.to_be_bytes());
    out.extend_from_slice(&(elem_oid as i32).to_be_bytes());
    out.extend_from_slice(&(n as i32).to_be_bytes());
    out.extend_from_slice(&1i32.to_be_bytes());
}

pub fn encode_array_i64(vals: &[i64]) -> Vec<u8> {
    let mut out = Vec::with_capacity(20 + vals.len() * 12);
    array_header(&mut out, OID_INT8, vals.len());
    for v in vals {
        out.extend_from_slice(&8i32.to_be_bytes());
        out.extend_from_slice(&v.to_be_bytes());
    }
    out
}

pub fn encode_array_bytea<T: AsRef<[u8]>>(vals: &[T]) -> Vec<u8> {
    let total: usize = vals.iter().map(|v| v.as_ref().len() + 4).sum();
    let mut out = Vec::with_capacity(20 + total);
    array_header(&mut out, OID_BYTEA, vals.len());
    for v in vals {
        let v = v.as_ref();
        out.extend_from_slice(&(v.len() as i32).to_be_bytes());
        out.extend_from_slice(v);
    }
    out
}

pub fn encode_array_text<T: AsRef<str>>(vals: &[T]) -> Vec<u8> {
    let total: usize = vals.iter().map(|v| v.as_ref().len() + 4).sum();
    let mut out = Vec::with_capacity(20 + total);
    array_header(&mut out, OID_TEXT, vals.len());
    for v in vals {
        let v = v.as_ref().as_bytes();
        out.extend_from_slice(&(v.len() as i32).to_be_bytes());
        out.extend_from_slice(v);
    }
    out
}

/// COPY ... (FORMAT binary) stream for rows of (bigint, bytea): signature, flags, header extension, tuples, trailer.
pub fn encode_copy_i64_bytea<T: AsRef<[u8]>>(rows: &[(i64, T)]) -> Vec<u8> {
    let total: usize = rows.iter().map(|(_, v)| v.as_ref().len() + 2 + 4 + 8 + 4).sum();
    let mut out = Vec::with_capacity(19 + total + 2);
    out.extend_from_slice(b"PGCOPY\n\xff\r\n\0");
    out.extend_from_slice(&0i32.to_be_bytes());
    out.extend_from_slice(&0i32.to_be_bytes());
    for (id, v) in rows {
        let v = v.as_ref();
        out.extend_from_slice(&2i16.to_be_bytes());
        out.extend_from_slice(&8i32.to_be_bytes());
        out.extend_from_slice(&id.to_be_bytes());
        out.extend_from_slice(&(v.len() as i32).to_be_bytes());
        out.extend_from_slice(v);
    }
    out.extend_from_slice(&(-1i16).to_be_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bigint_array_layout() {
        let a = encode_array_i64(&[1, -2]);
        // ndim 1, flags 0, oid 20, size 2, lower bound 1, then (8, value) twice
        assert_eq!(&a[0..4], &1i32.to_be_bytes());
        assert_eq!(&a[8..12], &20i32.to_be_bytes());
        assert_eq!(&a[12..16], &2i32.to_be_bytes());
        assert_eq!(&a[16..20], &1i32.to_be_bytes());
        assert_eq!(&a[20..24], &8i32.to_be_bytes());
        assert_eq!(&a[24..32], &1i64.to_be_bytes());
        assert_eq!(&a[36..44], &(-2i64).to_be_bytes());
        assert_eq!(a.len(), 44);
    }

    #[test]
    fn empty_array_has_zero_dimensions() {
        let a = encode_array_bytea::<Vec<u8>>(&[]);
        assert_eq!(a.len(), 12);
        assert_eq!(&a[0..4], &0i32.to_be_bytes());
    }

    #[test]
    fn bytea_and_text_arrays_carry_lengths() {
        let a = encode_array_bytea(&[vec![1u8, 2, 3], vec![]]);
        assert_eq!(&a[20..24], &3i32.to_be_bytes());
        assert_eq!(&a[24..27], &[1, 2, 3]);
        assert_eq!(&a[27..31], &0i32.to_be_bytes());
        let t = encode_array_text(&["ab", "c"]);
        assert_eq!(&t[8..12], &25i32.to_be_bytes());
        assert_eq!(&t[20..24], &2i32.to_be_bytes());
    }

    #[test]
    fn copy_stream_has_header_tuples_and_trailer() {
        let c = encode_copy_i64_bytea(&[(7i64, vec![9u8, 9]), (8, vec![])]);
        assert_eq!(&c[0..11], b"PGCOPY\n\xff\r\n\0");
        assert_eq!(&c[11..15], &0i32.to_be_bytes());
        assert_eq!(&c[15..19], &0i32.to_be_bytes());
        assert_eq!(&c[19..21], &2i16.to_be_bytes()); // two fields
        assert_eq!(&c[21..25], &8i32.to_be_bytes());
        assert_eq!(&c[25..33], &7i64.to_be_bytes());
        assert_eq!(&c[33..37], &2i32.to_be_bytes());
        assert_eq!(&c[37..39], &[9, 9]);
        assert_eq!(&c[c.len() - 2..], &(-1i16).to_be_bytes());
    }
}
