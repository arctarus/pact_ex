//! Error mapping for `pact_ffi` calls.
//!
//! `pact_ffi` keeps its last error message in a `thread_local!`. Always call
//! [`clear_error`] right before a fallible FFI call and read [`last_error`] on
//! the same thread, in the same NIF call, as the failing FFI call.

use std::ffi::{c_char, c_int, CStr, CString};

use rustler::{Encoder, Env, NifMap, Term};

const ERROR_BUFFER_LEN: usize = 1024;
const NUL_BYTE_CODE: i64 = -100;

#[derive(Debug, Clone, NifMap)]
pub struct FfiError {
    pub function: String,
    pub code: i64,
    pub message: String,
}

/// Reads the stored message into `buffer`. Returns the number of bytes written
/// (including the trailing NUL) or a negative status. Reading also clears it.
fn read_message(buffer: &mut [c_char]) -> c_int {
    pact_ffi::error::pactffi_get_error_message(buffer.as_mut_ptr(), buffer.len() as c_int)
}

/// Drains any stale message left in the thread-local by an earlier call.
pub fn clear_error() {
    let mut scratch = [0 as c_char; ERROR_BUFFER_LEN];
    read_message(&mut scratch);
}

/// Builds an [`FfiError`] from the message stored for `function`, falling back
/// to a generic message when there is none.
pub fn last_error(function: &str, code: i64) -> FfiError {
    let mut buffer = [0 as c_char; ERROR_BUFFER_LEN];
    let written = read_message(&mut buffer);

    // A length of 1 is an empty message: only the trailing NUL was written.
    let message = if written > 1 {
        // SAFETY: on success the buffer holds a NUL-terminated string.
        unsafe { CStr::from_ptr(buffer.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    } else {
        format!("{function} failed with code {code}")
    };

    FfiError {
        function: function.to_owned(),
        code,
        message,
    }
}

/// Converts `s` to a C string, rejecting interior NUL bytes without touching the FFI.
pub fn to_cstring(function: &str, s: &str) -> Result<CString, FfiError> {
    CString::new(s).map_err(|_| FfiError {
        function: function.to_owned(),
        code: NUL_BYTE_CODE,
        message: "argument contains a NUL byte".to_owned(),
    })
}

/// Result of a NIF that returns nothing on success. Encodes as `:ok` or
/// `{:error, map}`; Rustler would encode `Ok(())` as `{:ok, {}}`.
pub enum Outcome {
    Ok,
    Err(FfiError),
}

impl From<Result<(), FfiError>> for Outcome {
    fn from(result: Result<(), FfiError>) -> Self {
        match result {
            Ok(()) => Outcome::Ok,
            Err(error) => Outcome::Err(error),
        }
    }
}

impl Encoder for Outcome {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Outcome::Ok => rustler::types::atom::ok().encode(env),
            Outcome::Err(error) => (rustler::types::atom::error(), error.clone()).encode(env),
        }
    }
}
