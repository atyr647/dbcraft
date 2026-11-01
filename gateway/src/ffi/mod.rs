//! Hand-written bindings to the C libraries that are already installed (libc, libpq, libcrypto, libcurl).  No crates.io code anywhere in this program.
pub mod curl;
pub mod ossl;
pub mod pq;
pub mod sys;
