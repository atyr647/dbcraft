//! libcrypto (OpenSSL 3) through hand-written declarations: the server's RSA key (generate, export as X.509 SubjectPublicKeyInfo DER, decrypt PKCS#1 v1.5)
//! and AES-128-CFB8 streams (the cipher Minecraft's online mode uses in both directions, key = IV = the shared secret).
//! The tested std-only cipher in `dbcraft_gateway_core::aes` is the reference these are checked against.

use std::os::raw::{c_char, c_int, c_uchar, c_void};

#[repr(C)]
struct EvpPkey {
    _p: [u8; 0],
}
#[repr(C)]
struct EvpPkeyCtx {
    _p: [u8; 0],
}
#[repr(C)]
struct EvpCipherCtx {
    _p: [u8; 0],
}
#[repr(C)]
struct EvpCipher {
    _p: [u8; 0],
}

#[link(name = "crypto")]
extern "C" {
    // EVP_RSA_gen(bits) is a C macro for EVP_PKEY_Q_keygen(NULL, NULL, "RSA", (size_t)bits): call the variadic function it expands to
    fn EVP_PKEY_Q_keygen(libctx: *mut c_void, propq: *const c_char, key_type: *const c_char, ...) -> *mut EvpPkey;
    fn EVP_PKEY_free(pkey: *mut EvpPkey);
    fn i2d_PUBKEY(pkey: *const EvpPkey, pp: *mut *mut c_uchar) -> c_int;
    fn EVP_PKEY_CTX_new(pkey: *mut EvpPkey, engine: *mut c_void) -> *mut EvpPkeyCtx;
    fn EVP_PKEY_CTX_free(ctx: *mut EvpPkeyCtx);
    fn EVP_PKEY_decrypt_init(ctx: *mut EvpPkeyCtx) -> c_int;
    fn EVP_PKEY_CTX_set_rsa_padding(ctx: *mut EvpPkeyCtx, pad: c_int) -> c_int;
    fn EVP_PKEY_decrypt(ctx: *mut EvpPkeyCtx, out: *mut c_uchar, outlen: *mut usize, input: *const c_uchar, inlen: usize) -> c_int;
    #[cfg(test)]
    fn EVP_PKEY_encrypt_init(ctx: *mut EvpPkeyCtx) -> c_int;
    #[cfg(test)]
    fn EVP_PKEY_encrypt(ctx: *mut EvpPkeyCtx, out: *mut c_uchar, outlen: *mut usize, input: *const c_uchar, inlen: usize) -> c_int;
    fn EVP_PKEY_get_size(pkey: *const EvpPkey) -> c_int;
    fn ERR_clear_error();

    fn EVP_CIPHER_CTX_new() -> *mut EvpCipherCtx;
    fn EVP_CIPHER_CTX_free(ctx: *mut EvpCipherCtx);
    fn EVP_aes_128_cfb8() -> *const EvpCipher;
    fn EVP_EncryptInit_ex(ctx: *mut EvpCipherCtx, cipher: *const EvpCipher, engine: *mut c_void, key: *const c_uchar, iv: *const c_uchar) -> c_int;
    fn EVP_EncryptUpdate(ctx: *mut EvpCipherCtx, out: *mut c_uchar, outl: *mut c_int, input: *const c_uchar, inl: c_int) -> c_int;
    fn EVP_DecryptInit_ex(ctx: *mut EvpCipherCtx, cipher: *const EvpCipher, engine: *mut c_void, key: *const c_uchar, iv: *const c_uchar) -> c_int;
    fn EVP_DecryptUpdate(ctx: *mut EvpCipherCtx, out: *mut c_uchar, outl: *mut c_int, input: *const c_uchar, inl: c_int) -> c_int;
}

const RSA_PKCS1_PADDING: c_int = 1;

/// The server's RSA key pair.
pub struct RsaKey {
    pkey: *mut EvpPkey,
    size: usize,
}

// Only the loop thread uses the key (decryption happens on the loop thread); the pointer is never shared.
unsafe impl Send for RsaKey {}

impl RsaKey {
    pub fn generate(bits: u32) -> Result<RsaKey, String> {
        // SAFETY: the variadic call passes exactly what the "RSA" key type reads (one size_t: the modulus size in bits); the strings are NUL-terminated and outlive the call;
        // the result is checked.
        let pkey = unsafe { EVP_PKEY_Q_keygen(std::ptr::null_mut(), std::ptr::null(), b"RSA\0".as_ptr() as *const c_char, bits as usize) };
        if pkey.is_null() {
            unsafe { ERR_clear_error() };
            return Err("RSA key generation failed".into());
        }
        let size = unsafe { EVP_PKEY_get_size(pkey) };
        if size <= 0 {
            unsafe { EVP_PKEY_free(pkey) };
            return Err("EVP_PKEY_get_size failed".into());
        }
        Ok(RsaKey { pkey, size: size as usize })
    }

    /// The public key as X.509 SubjectPublicKeyInfo DER (what Minecraft's encryption_request carries).
    pub fn public_der(&self) -> Result<Vec<u8>, String> {
        // SAFETY: the first call with a null output pointer only computes the length; the second writes exactly that many bytes into a buffer of that size.
        unsafe {
            let n = i2d_PUBKEY(self.pkey, std::ptr::null_mut());
            if n <= 0 {
                ERR_clear_error();
                return Err("i2d_PUBKEY (length) failed".into());
            }
            let mut buf = vec![0u8; n as usize];
            let mut p = buf.as_mut_ptr();
            let m = i2d_PUBKEY(self.pkey, &mut p);
            if m != n {
                ERR_clear_error();
                return Err("i2d_PUBKEY failed".into());
            }
            Ok(buf)
        }
    }

    /// RSA PKCS#1 v1.5 decryption.  `None` for failures of the call itself (wrong length, ...): callers must not distinguish the causes.
    /// NOTE: OpenSSL builds with the Marvin mitigation ("implicit rejection", OpenSSL 3.2 and the security backports to 3.0 such as Ubuntu's) answer a ciphertext with
    /// invalid padding with deterministic pseudo-random bytes and SUCCESS, so there is no padding oracle.  Garbage is therefore possible here: callers must check what
    /// they decrypted (a shared secret must be exactly 16 bytes, the verify token must equal the one we sent), which makes garbage pass with probability about 2^-32.
    pub fn decrypt(&self, ciphertext: &[u8]) -> Option<Vec<u8>> {
        if ciphertext.len() != self.size {
            return None; // an RSA ciphertext is exactly as long as the modulus: reject early, nothing to decrypt
        }
        // SAFETY: the context is created, used and freed within this function; `out` has `self.size` bytes, the most RSA decryption can produce, and `outlen` tells OpenSSL so.
        unsafe {
            let ctx = EVP_PKEY_CTX_new(self.pkey, std::ptr::null_mut());
            if ctx.is_null() {
                ERR_clear_error();
                return None;
            }
            let mut result = None;
            if EVP_PKEY_decrypt_init(ctx) > 0 && EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_PADDING) > 0 {
                let mut out = vec![0u8; self.size];
                let mut outlen = out.len();
                if EVP_PKEY_decrypt(ctx, out.as_mut_ptr(), &mut outlen, ciphertext.as_ptr(), ciphertext.len()) > 0 && outlen <= out.len() {
                    out.truncate(outlen);
                    result = Some(out);
                }
            }
            EVP_PKEY_CTX_free(ctx);
            ERR_clear_error();
            result
        }
    }
}

#[cfg(test)]
impl RsaKey {
    /// PKCS#1 v1.5 encryption with the public half (what a client does), for tests only.
    pub fn encrypt_for_tests(&self, plaintext: &[u8]) -> Vec<u8> {
        // SAFETY: same pattern as `decrypt`: a context created and freed here, an output buffer of the modulus size.
        unsafe {
            let ctx = EVP_PKEY_CTX_new(self.pkey, std::ptr::null_mut());
            assert!(!ctx.is_null());
            assert!(EVP_PKEY_encrypt_init(ctx) > 0 && EVP_PKEY_CTX_set_rsa_padding(ctx, RSA_PKCS1_PADDING) > 0);
            let mut out = vec![0u8; self.size];
            let mut outlen = out.len();
            assert!(EVP_PKEY_encrypt(ctx, out.as_mut_ptr(), &mut outlen, plaintext.as_ptr(), plaintext.len()) > 0);
            out.truncate(outlen);
            EVP_PKEY_CTX_free(ctx);
            out
        }
    }
}

impl Drop for RsaKey {
    fn drop(&mut self) {
        // SAFETY: we own the key and free it once.
        unsafe { EVP_PKEY_free(self.pkey) };
    }
}

/// One direction of AES-128-CFB8 (key = IV = the shared secret).  In place.
pub struct Cfb8Stream {
    ctx: *mut EvpCipherCtx,
    encrypt: bool,
}

unsafe impl Send for Cfb8Stream {}

impl Cfb8Stream {
    pub fn new(secret: &[u8; 16], encrypt: bool) -> Result<Cfb8Stream, String> {
        // SAFETY: the context is freed on every failure path and by Drop otherwise; key and iv point to 16 readable bytes each (AES-128's key and block size).
        unsafe {
            let ctx = EVP_CIPHER_CTX_new();
            if ctx.is_null() {
                return Err("EVP_CIPHER_CTX_new failed".into());
            }
            let ok = if encrypt {
                EVP_EncryptInit_ex(ctx, EVP_aes_128_cfb8(), std::ptr::null_mut(), secret.as_ptr(), secret.as_ptr())
            } else {
                EVP_DecryptInit_ex(ctx, EVP_aes_128_cfb8(), std::ptr::null_mut(), secret.as_ptr(), secret.as_ptr())
            };
            if ok != 1 {
                EVP_CIPHER_CTX_free(ctx);
                ERR_clear_error();
                return Err("cipher init failed".into());
            }
            Ok(Cfb8Stream { ctx, encrypt })
        }
    }

    /// Transforms `data` in place (CFB8 keeps the length, so input and output are the same buffer: OpenSSL allows exact overlap).
    pub fn apply(&mut self, data: &mut [u8]) {
        for chunk in data.chunks_mut(1 << 20) {
            let mut outl: c_int = 0;
            // SAFETY: `chunk` is at most 1 MiB so its length fits c_int; input and output are the same buffer (exact overlap is allowed); OpenSSL writes at most `len` bytes for CFB8.
            let ok = unsafe {
                if self.encrypt {
                    EVP_EncryptUpdate(self.ctx, chunk.as_mut_ptr(), &mut outl, chunk.as_ptr(), chunk.len() as c_int)
                } else {
                    EVP_DecryptUpdate(self.ctx, chunk.as_mut_ptr(), &mut outl, chunk.as_ptr(), chunk.len() as c_int)
                }
            };
            // A CFB8 update cannot fail for a valid context; if it ever did, continuing would corrupt the stream silently, so stop the process instead.
            assert!(ok == 1 && outl as usize == chunk.len(), "AES-CFB8 update failed");
        }
    }
}

impl Drop for Cfb8Stream {
    fn drop(&mut self) {
        // SAFETY: we own the context and free it once.
        unsafe { EVP_CIPHER_CTX_free(self.ctx) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dbcraft_gateway_core::aes::Cfb8;

    fn pseudo(seed: &mut u64, n: usize) -> Vec<u8> {
        (0..n)
            .map(|_| {
                *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                (*seed >> 33) as u8
            })
            .collect()
    }

    #[test]
    fn cfb8_matches_the_reference_cipher_over_random_chunk_boundaries() {
        let mut s = 7u64;
        for round in 0..40 {
            let secret: [u8; 16] = pseudo(&mut s, 16).try_into().unwrap();
            let data = pseudo(&mut s, 1 + (round * 97) % 5000);
            let mut evp = Cfb8Stream::new(&secret, true).unwrap();
            let mut reference = Cfb8::new(&secret);
            let mut a = data.clone();
            let mut b = data.clone();
            // the same bytes, cut at different places
            let mut i = 0;
            while i < a.len() {
                let n = 1 + (pseudo(&mut s, 1)[0] as usize % 300);
                let end = (i + n).min(a.len());
                evp.apply(&mut a[i..end]);
                i = end;
            }
            reference.encrypt(&mut b);
            assert_eq!(a, b, "encrypt round {round}");
            // and back
            let mut dec = Cfb8Stream::new(&secret, false).unwrap();
            dec.apply(&mut a);
            assert_eq!(a, data, "decrypt round {round}");
        }
    }

    #[test]
    fn rsa_round_trip_and_rejections() {
        let key = RsaKey::generate(1024).unwrap();
        let der = key.public_der().unwrap();
        assert!(der.len() > 100 && der[0] == 0x30, "an X.509 SubjectPublicKeyInfo starts with a DER SEQUENCE");
        // what a client does: encrypt a 16-byte secret and a 4-byte token with the public key; we get them back exactly
        let secret = [0x5au8; 16];
        let token = [1u8, 2, 3, 4];
        assert_eq!(key.decrypt(&key.encrypt_for_tests(&secret)).unwrap(), secret);
        assert_eq!(key.decrypt(&key.encrypt_for_tests(&token)).unwrap(), token);
        // a ciphertext made for ANOTHER key never yields the plaintext (it fails, or with implicit rejection yields garbage that is not the secret)
        let other = RsaKey::generate(1024).unwrap();
        for _ in 0..20 {
            let r = key.decrypt(&other.encrypt_for_tests(&secret));
            assert_ne!(r.as_deref(), Some(&secret[..]));
        }
        // wrong lengths are refused before any decryption
        let mut s = 99u64;
        assert!(key.decrypt(&pseudo(&mut s, 127)).is_none());
        assert!(key.decrypt(&pseudo(&mut s, 129)).is_none());
        assert!(key.decrypt(&[]).is_none());
        // random ciphertexts of the right length: an error, or garbage that is not a valid 16-byte secret in practice
        let mut fake_secrets = 0;
        for _ in 0..200 {
            if key.decrypt(&pseudo(&mut s, 128)).map_or(false, |p| p.len() == 16) {
                fake_secrets += 1;
            }
        }
        assert!(fake_secrets < 20, "{fake_secrets} of 200 random ciphertexts decrypted to 16 bytes");
    }
}
