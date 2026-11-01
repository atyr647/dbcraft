//! A small JSON parser and serializer, only for Mojang's hasJoined answer: `{"id":"<32 hex>","name":"..","properties":[{"name":"..","value":"..","signature":".."}]}`.
//! Hostile input is expected (the answer comes from the network): the input size and the nesting depth are bounded, nothing recurses beyond MAX_DEPTH, numbers are kept
//! as text (never converted), and every error is a value, never a panic.

pub const MAX_INPUT: usize = 256 * 1024;
pub const MAX_DEPTH: usize = 16;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    /// the number exactly as written
    Num(String),
    Str(String),
    Arr(Vec<Value>),
    Obj(Vec<(String, Value)>),
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Obj(kv) => kv.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }
    pub fn as_arr(&self) -> Option<&[Value]> {
        match self {
            Value::Arr(a) => Some(a),
            _ => None,
        }
    }
}

pub fn parse(input: &[u8]) -> Result<Value, &'static str> {
    if input.len() > MAX_INPUT {
        return Err("input too large");
    }
    let mut p = Parser { b: input, i: 0 };
    p.ws();
    let v = p.value(0)?;
    p.ws();
    if p.i != p.b.len() {
        return Err("trailing characters");
    }
    Ok(v)
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn lit(&mut self, word: &[u8], v: Value) -> Result<Value, &'static str> {
        if self.b[self.i..].starts_with(word) {
            self.i += word.len();
            Ok(v)
        } else {
            Err("bad literal")
        }
    }
    fn value(&mut self, depth: usize) -> Result<Value, &'static str> {
        if depth > MAX_DEPTH {
            return Err("nesting too deep");
        }
        match self.peek().ok_or("unexpected end")? {
            b'{' => {
                self.i += 1;
                let mut kv = Vec::new();
                self.ws();
                if self.peek() == Some(b'}') {
                    self.i += 1;
                    return Ok(Value::Obj(kv));
                }
                loop {
                    self.ws();
                    if self.peek() != Some(b'"') {
                        return Err("expected a string key");
                    }
                    let k = self.string()?;
                    self.ws();
                    if self.peek() != Some(b':') {
                        return Err("expected ':'");
                    }
                    self.i += 1;
                    self.ws();
                    let v = self.value(depth + 1)?;
                    kv.push((k, v));
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.i += 1,
                        Some(b'}') => {
                            self.i += 1;
                            return Ok(Value::Obj(kv));
                        }
                        _ => return Err("expected ',' or '}'"),
                    }
                }
            }
            b'[' => {
                self.i += 1;
                let mut a = Vec::new();
                self.ws();
                if self.peek() == Some(b']') {
                    self.i += 1;
                    return Ok(Value::Arr(a));
                }
                loop {
                    self.ws();
                    a.push(self.value(depth + 1)?);
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.i += 1,
                        Some(b']') => {
                            self.i += 1;
                            return Ok(Value::Arr(a));
                        }
                        _ => return Err("expected ',' or ']'"),
                    }
                }
            }
            b'"' => Ok(Value::Str(self.string()?)),
            b't' => self.lit(b"true", Value::Bool(true)),
            b'f' => self.lit(b"false", Value::Bool(false)),
            b'n' => self.lit(b"null", Value::Null),
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err("unexpected character"),
        }
    }
    fn number(&mut self) -> Result<Value, &'static str> {
        let start = self.i;
        if self.peek() == Some(b'-') {
            self.i += 1;
        }
        let digits = |p: &mut Parser| {
            let s = p.i;
            while matches!(p.peek(), Some(b'0'..=b'9')) {
                p.i += 1;
            }
            p.i > s
        };
        if !digits(self) {
            return Err("bad number");
        }
        if self.peek() == Some(b'.') {
            self.i += 1;
            if !digits(self) {
                return Err("bad number");
            }
        }
        if matches!(self.peek(), Some(b'e') | Some(b'E')) {
            self.i += 1;
            if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                self.i += 1;
            }
            if !digits(self) {
                return Err("bad number");
            }
        }
        Ok(Value::Num(String::from_utf8_lossy(&self.b[start..self.i]).into_owned()))
    }
    fn hex4(&mut self) -> Result<u32, &'static str> {
        if self.i + 4 > self.b.len() {
            return Err("bad \\u escape");
        }
        let mut v = 0u32;
        for k in 0..4 {
            let d = (self.b[self.i + k] as char).to_digit(16).ok_or("bad \\u escape")?;
            v = v * 16 + d;
        }
        self.i += 4;
        Ok(v)
    }
    fn string(&mut self) -> Result<String, &'static str> {
        self.i += 1; // opening quote
        let mut out: Vec<u8> = Vec::new();
        loop {
            let c = self.peek().ok_or("unterminated string")?;
            self.i += 1;
            match c {
                b'"' => break,
                b'\\' => {
                    let e = self.peek().ok_or("unterminated escape")?;
                    self.i += 1;
                    match e {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'b' => out.push(8),
                        b'f' => out.push(12),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                // a high surrogate must be followed by \uDC00..\uDFFF
                                if self.b[self.i..].starts_with(b"\\u") {
                                    self.i += 2;
                                    let lo = self.hex4()?;
                                    if !(0xDC00..0xE000).contains(&lo) {
                                        return Err("bad surrogate pair");
                                    }
                                    0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                                } else {
                                    return Err("lone surrogate");
                                }
                            } else if (0xDC00..0xE000).contains(&hi) {
                                return Err("lone surrogate");
                            } else {
                                hi
                            };
                            let ch = char::from_u32(cp).ok_or("bad code point")?;
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        _ => return Err("bad escape"),
                    }
                }
                0..=0x1f => return Err("control character in string"),
                _ => out.push(c),
            }
        }
        String::from_utf8(out).map_err(|_| "invalid UTF-8")
    }
}

/// Compact JSON text of a value (what the database stores as jsonb).
pub fn to_json(v: &Value) -> String {
    let mut s = String::new();
    write_value(v, &mut s);
    s
}

fn write_value(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Num(n) => out.push_str(n),
        Value::Str(s) => write_str(s, out),
        Value::Arr(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(x, out);
            }
            out.push(']');
        }
        Value::Obj(kv) => {
            out.push('{');
            for (i, (k, x)) in kv.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_str(k, out);
                out.push(':');
                write_value(x, out);
            }
            out.push('}');
        }
    }
}

fn write_str(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_session_answer() {
        let j = br#"{"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","properties":[{"name":"textures","value":"eyJ4IjoxfQ==","signature":"sig"}],"extra":null}"#;
        let v = parse(j).unwrap();
        assert_eq!(v.get("id").unwrap().as_str(), Some("069a79f444e94726a5befca90e38aaf5"));
        assert_eq!(v.get("name").unwrap().as_str(), Some("Notch"));
        let props = v.get("properties").unwrap().as_arr().unwrap();
        assert_eq!(props.len(), 1);
        assert_eq!(props[0].get("signature").unwrap().as_str(), Some("sig"));
    }

    #[test]
    fn round_trips_escapes_and_unicode() {
        let v = parse(br#"["a\"b\\c\n\u00e9\ud83d\ude00", 1.5e3, -0, true, null]"#).unwrap();
        assert_eq!(v.as_arr().unwrap()[0].as_str(), Some("a\"b\\c\n\u{e9}\u{1F600}"));
        let text = to_json(&v);
        assert_eq!(parse(text.as_bytes()).unwrap(), v);
    }

    #[test]
    fn malformed_input_is_an_error_not_a_panic() {
        for bad in [
            &b""[..], b"{", b"[", b"}", b"{\"a\"}", b"{\"a\":}", b"[1,]", b"[1 2]", b"\"abc", b"\"\\x\"", b"\"\\u12\"", b"\"\\ud800\"", b"\"\\udc00\"", b"\"\\ud800\\u0041\"",
            b"tru", b"nul", b"-", b"1.", b"1e", b"{\"a\":1} x", b"\"\x01\"", b"\xff", b"[\"\xc3\x28\"]",
        ] {
            assert!(parse(bad).is_err(), "{:?} must be rejected", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn nesting_and_size_are_bounded() {
        let deep = "[".repeat(MAX_DEPTH + 2) + &"]".repeat(MAX_DEPTH + 2);
        assert!(parse(deep.as_bytes()).is_err());
        let ok = "[".repeat(MAX_DEPTH) + &"]".repeat(MAX_DEPTH);
        assert!(parse(ok.as_bytes()).is_ok());
        let huge = vec![b' '; MAX_INPUT + 1];
        assert!(parse(&huge).is_err());
        // a million open brackets must fail fast, without recursion trouble
        let bomb = "[".repeat(100_000);
        assert!(parse(bomb.as_bytes()).is_err());
    }

    #[test]
    fn random_garbage_never_panics() {
        let mut s = 12345u64;
        for _ in 0..3000 {
            let n = {
                s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                (s >> 40) as usize % 200
            };
            let bytes: Vec<u8> = (0..n)
                .map(|_| {
                    s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    let c = (s >> 33) as u8;
                    // bias towards JSON punctuation so that deeper paths are reached
                    b"{}[]\":,\\ntf0123456789.-eE u"[c as usize % 27]
                })
                .collect();
            let _ = parse(&bytes);
        }
    }

    #[test]
    fn serializer_escapes_control_characters() {
        assert_eq!(to_json(&Value::Str("a\u{1}\"".into())), "\"a\\u0001\\\"\"");
    }
}
