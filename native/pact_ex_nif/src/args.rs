//! Helpers for decoding NIF arguments.

use std::ffi::CString;

use rustler::{Decoder, NifResult, Term};

/// Decodes `term` as `T`, mapping any failure to `BadArg` (`ArgumentError`).
///
/// Taking a `NifUnitEnum` as a NIF parameter makes Rustler raise
/// `ErlangError :invalid_variant` for an unknown atom. Taking a raw `Term` and
/// decoding it here raises `ArgumentError` instead, since an unknown atom is a
/// caller bug.
pub fn decode_arg<'a, T: Decoder<'a>>(term: Term<'a>) -> NifResult<T> {
    term.decode().map_err(|_| rustler::Error::BadArg)
}

/// Raised as `ArgumentError`: a NUL byte in these arguments is a caller bug.
pub fn arg_cstring(s: &str) -> NifResult<CString> {
    CString::new(s).map_err(|_| rustler::Error::BadArg)
}

/// Rustler decodes `u16` with a truncating cast, so a port above 65535 would
/// silently wrap. Decode as `i64` and range-check instead; a port outside
/// `0..=65535` is a caller bug and raises `ArgumentError`.
pub fn port_arg(port: i64) -> NifResult<u16> {
    u16::try_from(port).map_err(|_| rustler::Error::BadArg)
}
