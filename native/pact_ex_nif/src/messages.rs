//! NIFs for asynchronous and synchronous message interactions.

use std::ffi::{c_char, CStr};

use pact_ffi::mock_server::handles::{
    pactffi_message_reify, pactffi_new_message_interaction, pactffi_new_sync_message_interaction,
    pactffi_pact_handle_write_file, pactffi_sync_message_generate_contents, pactffi_with_metadata,
    InteractionHandle, InteractionPart, MessageHandle, PactHandle,
};
use pact_ffi::pactffi_string_delete;
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};

use crate::args::{arg_cstring, decode_arg};
use crate::error::{clear_error, last_error, to_cstring, FfiError, Outcome};
use crate::handles::{InteractionResource, PactResource};
use crate::http::Part;
use crate::stack::on_large_stack;

/// Result of a NIF that returns a string on success. Encodes as `{:ok, string}`
/// or `{:error, map}`.
pub enum Text {
    Ok(String),
    Err(FfiError),
}

impl From<Result<String, FfiError>> for Text {
    fn from(result: Result<String, FfiError>) -> Self {
        match result {
            Ok(text) => Text::Ok(text),
            Err(error) => Text::Err(error),
        }
    }
}

impl Encoder for Text {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Text::Ok(text) => (rustler::types::atom::ok(), text.as_str()).encode(env),
            Text::Err(error) => (rustler::types::atom::error(), error.clone()).encode(env),
        }
    }
}

/// Copies a string returned by pact_ffi into a Rust `String` and frees it.
/// An empty string is how pact_ffi reports a failure: it returns `Err` with
/// the last error message of `function`.
///
/// # Safety
///
/// `ptr` must be a pointer returned by `pactffi_message_reify` or
/// `pactffi_sync_message_generate_contents`, and not freed yet.
unsafe fn take_string(function: &str, ptr: *const c_char) -> Result<String, FfiError> {
    if ptr.is_null() {
        return Err(last_error(function, 1));
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string.
    let text = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    // The pointer came from `CString::into_raw` in pact_ffi.
    pactffi_string_delete(ptr as *mut c_char);
    if text.is_empty() {
        Err(last_error(function, 1))
    } else {
        Ok(text)
    }
}

/// Sets a metadata entry. `value` is JSON text.
fn set_metadata(
    handle: InteractionHandle,
    key: &str,
    value: &str,
    part: InteractionPart,
) -> Result<(), FfiError> {
    const NAME: &str = "pactffi_with_metadata";
    let key = to_cstring(NAME, key)?;
    let value = to_cstring(NAME, value)?;
    clear_error();
    if pactffi_with_metadata(handle, key.as_ptr(), value.as_ptr(), part) {
        Ok(())
    } else {
        Err(last_error(NAME, 1))
    }
}

/// Writes the pact of `handle` to `dir`.
fn write_file(handle: PactHandle, dir: &str, overwrite: bool) -> Result<(), FfiError> {
    const NAME: &str = "pactffi_pact_handle_write_file";
    let dir = to_cstring(NAME, dir)?;
    clear_error();
    match pactffi_pact_handle_write_file(handle, dir.as_ptr(), overwrite) {
        0 => Ok(()),
        code => Err(last_error(NAME, i64::from(code))),
    }
}

/// Reifies the message of `handle`.
fn reify(handle: InteractionHandle) -> Result<String, FfiError> {
    const NAME: &str = "pactffi_message_reify";
    // SAFETY: `InteractionHandle` and `MessageHandle` are both
    // `#[repr(transparent)]` over a `u32` with the same packing,
    // `(pact_ref << 16) | index` (`InteractionHandle::new` and
    // `MessageHandle::new_v4` in pact_ffi `mock_server/handles.rs`), so the
    // bit patterns are interchangeable.
    let message = unsafe { std::mem::transmute::<InteractionHandle, MessageHandle>(handle) };
    clear_error();
    let ptr = pactffi_message_reify(message);
    // SAFETY: `ptr` was just returned by `pactffi_message_reify`.
    unsafe { take_string(NAME, ptr) }
}

/// Generates the request and response contents of the sync message of `handle`.
fn generate_contents(handle: InteractionHandle) -> Result<String, FfiError> {
    const NAME: &str = "pactffi_sync_message_generate_contents";
    clear_error();
    let ptr = pactffi_sync_message_generate_contents(handle);
    // SAFETY: `ptr` was just returned by `pactffi_sync_message_generate_contents`.
    unsafe { take_string(NAME, ptr) }
}

// DirtyIo: like every builder NIF, these take pact_ffi's global `PACT_HANDLES`
// mutex. No large stack: they only take the mutex and do not call a plugin.
#[rustler::nif(schedule = "DirtyIo")]
fn new_message_interaction(
    pact: ResourceArc<PactResource>,
    description: String,
) -> NifResult<ResourceArc<InteractionResource>> {
    let description = arg_cstring(&description)?;
    let handle = pactffi_new_message_interaction(pact.handle, description.as_ptr());
    Ok(ResourceArc::new(InteractionResource { handle, pact }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn new_sync_message_interaction(
    pact: ResourceArc<PactResource>,
    description: String,
) -> NifResult<ResourceArc<InteractionResource>> {
    let description = arg_cstring(&description)?;
    let handle = pactffi_new_sync_message_interaction(pact.handle, description.as_ptr());
    Ok(ResourceArc::new(InteractionResource { handle, pact }))
}

/// `value` is JSON text. pact_ffi parses it and falls back to a plain string
/// only when that fails.
#[rustler::nif(schedule = "DirtyIo")]
fn with_metadata(
    interaction: ResourceArc<InteractionResource>,
    key: String,
    value: String,
    part: Term,
) -> NifResult<Outcome> {
    let part: Part = decode_arg(part)?;
    Ok(set_metadata(interaction.handle, &key, &value, part.into()).into())
}

// DirtyIo and large stack: pact_ffi runs the generators with `block_on`, which
// can call a plugin, while it works on this thread.
#[rustler::nif(schedule = "DirtyIo")]
fn message_reify(interaction: ResourceArc<InteractionResource>) -> Text {
    let handle = interaction.handle;
    on_large_stack(move || reify(handle)).into()
}

#[rustler::nif(schedule = "DirtyIo")]
fn sync_message_generate_contents(interaction: ResourceArc<InteractionResource>) -> Text {
    let handle = interaction.handle;
    on_large_stack(move || generate_contents(handle)).into()
}

// DirtyIo: writing the pact takes `PACT_HANDLES` and does file I/O. Large
// stack: it can reach a plugin when the pact has plugin data.
#[rustler::nif(schedule = "DirtyIo")]
fn pact_handle_write_file(
    pact: ResourceArc<PactResource>,
    dir: String,
    overwrite: bool,
) -> Outcome {
    let handle = pact.handle;
    on_large_stack(move || write_file(handle, &dir, overwrite)).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use pact_ffi::mock_server::handles::{
        pactffi_free_pact_handle, pactffi_new_pact, pactffi_with_body, pactffi_with_specification,
    };
    use std::ffi::CString;

    fn v4_pact() -> PactHandle {
        let consumer = CString::new("messages-unit-consumer").unwrap();
        let provider = CString::new("messages-unit-provider").unwrap();
        let pact = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
        assert!(pactffi_with_specification(
            pact,
            pact_models::PactSpecification::V4
        ));
        pact
    }

    fn with_json_body(interaction: InteractionHandle, part: InteractionPart, json: &str) {
        let content_type = CString::new("application/json").unwrap();
        let body = CString::new(json).unwrap();
        assert!(pactffi_with_body(
            interaction,
            part,
            content_type.as_ptr(),
            body.as_ptr()
        ));
    }

    fn parse(text: &str) -> serde_json::Value {
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn reify_reads_an_interaction_handle_as_a_message_handle() {
        let pact = v4_pact();
        let description = CString::new("a message").unwrap();
        // A first interaction makes the second one use a non-zero index.
        let _first = pactffi_new_message_interaction(pact, description.as_ptr());
        let interaction = pactffi_new_message_interaction(pact, description.as_ptr());
        with_json_body(
            interaction,
            InteractionPart::Request,
            r#"{"temp": {"pact:matcher:type": "type", "value": 23.0}}"#,
        );
        let key = CString::new("queue").unwrap();
        let value = CString::new("\"weather\"").unwrap();
        assert!(pactffi_with_metadata(
            interaction,
            key.as_ptr(),
            value.as_ptr(),
            InteractionPart::Request
        ));

        let json = parse(&on_large_stack(move || reify(interaction)).unwrap());
        assert_eq!(json["contents"]["content"]["temp"], 23.0);
        assert_eq!(json["metadata"]["queue"], "weather");
        pactffi_free_pact_handle(pact);
    }

    #[test]
    fn reify_fails_for_an_interaction_that_is_not_an_async_message() {
        let pact = v4_pact();
        let description = CString::new("a sync message").unwrap();
        let interaction = pactffi_new_sync_message_interaction(pact, description.as_ptr());

        let error = on_large_stack(move || reify(interaction)).unwrap_err();
        assert_eq!(error.function, "pactffi_message_reify");
        assert_eq!(error.code, 1);
        pactffi_free_pact_handle(pact);
    }

    #[test]
    fn generate_contents_returns_the_request_and_responses() {
        let pact = v4_pact();
        let description = CString::new("a sync message").unwrap();
        let interaction = pactffi_new_sync_message_interaction(pact, description.as_ptr());
        with_json_body(interaction, InteractionPart::Request, r#"{"id": 1}"#);
        with_json_body(interaction, InteractionPart::Response, r#"{"name": "Ann"}"#);

        let json = parse(&on_large_stack(move || generate_contents(interaction)).unwrap());
        assert_eq!(json["request"]["contents"]["content"]["id"], 1);
        assert_eq!(json["response"][0]["contents"]["content"]["name"], "Ann");
        pactffi_free_pact_handle(pact);
    }

    #[test]
    fn generate_contents_fails_for_an_interaction_that_is_not_a_sync_message() {
        let pact = v4_pact();
        let description = CString::new("an async message").unwrap();
        let interaction = pactffi_new_message_interaction(pact, description.as_ptr());

        let error = on_large_stack(move || generate_contents(interaction)).unwrap_err();
        assert_eq!(error.function, "pactffi_sync_message_generate_contents");
        assert_eq!(error.code, 1);
        pactffi_free_pact_handle(pact);
    }

    #[test]
    fn take_string_rejects_a_null_pointer() {
        let error = unsafe { take_string("f", std::ptr::null()) }.unwrap_err();
        assert_eq!(error.function, "f");
        assert_eq!(error.code, 1);
    }

    #[test]
    fn set_metadata_fails_for_an_http_interaction() {
        use pact_ffi::mock_server::handles::pactffi_new_interaction;

        let pact = v4_pact();
        let description = CString::new("an http interaction").unwrap();
        let interaction = pactffi_new_interaction(pact, description.as_ptr());

        let error = set_metadata(
            interaction,
            "queue",
            "\"weather\"",
            InteractionPart::Request,
        )
        .unwrap_err();
        assert_eq!(error.function, "pactffi_with_metadata");
        assert_eq!(error.code, 1);
        pactffi_free_pact_handle(pact);
    }

    #[test]
    fn set_metadata_rejects_a_nul_byte() {
        let pact = v4_pact();
        let description = CString::new("a message").unwrap();
        let interaction = pactffi_new_message_interaction(pact, description.as_ptr());

        let error = set_metadata(interaction, "a\0b", "1", InteractionPart::Request).unwrap_err();
        assert_eq!(error.code, -100);
        pactffi_free_pact_handle(pact);
    }

    #[test]
    fn write_file_reports_code_3_for_a_pact_that_does_not_exist() {
        let pact = v4_pact();
        pactffi_free_pact_handle(pact);

        let dir = std::env::temp_dir();
        let error =
            on_large_stack(move || write_file(pact, dir.to_str().unwrap(), false)).unwrap_err();
        assert_eq!(error.function, "pactffi_pact_handle_write_file");
        assert_eq!(error.code, 3);
    }

    #[test]
    fn write_file_rejects_a_nul_byte() {
        let pact = v4_pact();
        let error = write_file(pact, "a\0b", false).unwrap_err();
        assert_eq!(error.code, -100);
        pactffi_free_pact_handle(pact);
    }
}
