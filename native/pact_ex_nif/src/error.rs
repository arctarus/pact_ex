//! Error mapping for `pact_ffi` calls.
//!
//! `pact_ffi` keeps its last error message in a `thread_local!`. Always call
//! [`clear_error`] right before a fallible FFI call and read [`last_error`] on
//! the same thread, in the same NIF call, as the failing FFI call.

use std::ffi::{c_char, c_int, CStr, CString};

use rustler::{Encoder, Env, NifMap, Term};

const ERROR_BUFFER_LEN: usize = 16 * 1024;
const BUFFER_TOO_SMALL: c_int = -2;
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
    // `pactffi_get_error_message` takes the message out of the thread-local
    // before it checks the buffer size, so a one-byte buffer drains it too.
    let mut scratch = [0 as c_char; 1];
    read_message(&mut scratch);
}

/// The message used when `pact_ffi` stored none. Callers that want a better
/// message compare against this, instead of guessing from the wording.
pub fn fallback_message(function: &str, code: i64) -> String {
    format!("{function} failed with code {code}")
}

/// Builds an [`FfiError`] from the message stored for `function`, falling back
/// to a generic message when there is none.
pub fn last_error(function: &str, code: i64) -> FfiError {
    last_error_with_capacity(function, code, ERROR_BUFFER_LEN)
}

fn last_error_with_capacity(function: &str, code: i64, capacity: usize) -> FfiError {
    let mut buffer = vec![0 as c_char; capacity];
    let written = read_message(&mut buffer);

    let message = if written > 1 {
        // SAFETY: on success the buffer holds a NUL-terminated string.
        unsafe { CStr::from_ptr(buffer.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    } else if written == BUFFER_TOO_SMALL {
        // The message was taken from the thread-local but did not fit.
        format!("{function} failed with code {code} (error message too long to read)")
    } else {
        // 1 means an empty message: only the trailing NUL was written.
        fallback_message(function, code)
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

#[cfg(test)]
mod tests {
    use super::*;
    use pact_ffi::mock_server::handles::{
        pactffi_free_pact_handle, pactffi_given_with_params, pactffi_new_interaction,
        pactffi_new_pact,
    };

    fn fail_given_with_params() -> i64 {
        let consumer = CString::new("error-test-consumer").unwrap();
        let provider = CString::new("error-test-provider").unwrap();
        let description = CString::new("an interaction").unwrap();
        let state = CString::new("a state").unwrap();
        let params = CString::new("not json").unwrap();

        let pact = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
        let interaction = pactffi_new_interaction(pact, description.as_ptr());
        clear_error();
        let code = pactffi_given_with_params(interaction, state.as_ptr(), params.as_ptr());
        pactffi_free_pact_handle(pact);
        i64::from(code)
    }

    #[test]
    fn last_error_returns_the_ffi_message() {
        let code = fail_given_with_params();
        assert_eq!(code, 2);

        let error = last_error("pactffi_given_with_params", code);
        assert_eq!(error.function, "pactffi_given_with_params");
        assert_eq!(error.code, 2);
        assert!(error.message.contains("expected"), "{}", error.message);
    }

    #[test]
    fn clear_error_drains_a_pending_message() {
        let code = fail_given_with_params();
        assert_eq!(code, 2);

        clear_error();
        let error = last_error("pactffi_given_with_params", code);
        assert_eq!(
            error.message,
            "pactffi_given_with_params failed with code 2"
        );
    }

    #[test]
    fn last_error_falls_back_when_there_is_no_message() {
        clear_error();
        let error = last_error("pactffi_given", 1);
        assert_eq!(error.message, "pactffi_given failed with code 1");
    }

    #[test]
    fn fallback_message_is_what_last_error_returns_without_a_message() {
        clear_error();
        let error = last_error("pactffi_given", 1);
        assert_eq!(error.message, fallback_message("pactffi_given", 1));
    }

    #[test]
    fn last_error_reports_a_message_too_long_to_read() {
        let code = fail_given_with_params();
        let error = last_error_with_capacity("pactffi_given_with_params", code, 4);
        assert_eq!(
            error.message,
            "pactffi_given_with_params failed with code 2 (error message too long to read)"
        );
    }

    #[test]
    fn to_cstring_rejects_interior_nul() {
        let error = to_cstring("pactffi_given", "bad\0state").unwrap_err();
        assert_eq!(error.code, -100);
        assert_eq!(error.function, "pactffi_given");
        assert_eq!(error.message, "argument contains a NUL byte");
        assert!(to_cstring("pactffi_given", "ok").is_ok());
    }
}
