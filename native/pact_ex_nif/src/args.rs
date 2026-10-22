//! Helpers for decoding NIF arguments.

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
