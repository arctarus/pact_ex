//! NIFs that describe the HTTP request and response of an interaction.

use pact_ffi::mock_server::handles::{
    pactffi_response_status_v2, pactffi_with_binary_body, pactffi_with_body,
    pactffi_with_header_v2, pactffi_with_query_parameter_v2, pactffi_with_request, InteractionPart,
};
use rustler::{Binary, NifResult, NifUnitEnum, ResourceArc, Term};

use crate::args::decode_arg;
use crate::error::{clear_error, last_error, to_cstring, FfiError, Outcome};
use crate::handles::InteractionResource;

#[derive(Clone, Copy, NifUnitEnum)]
pub enum Part {
    Request,
    Response,
}

impl From<Part> for InteractionPart {
    fn from(part: Part) -> Self {
        match part {
            Part::Request => InteractionPart::Request,
            Part::Response => InteractionPart::Response,
        }
    }
}

/// Runs a builder call that returns `false` on failure.
fn check(name: &str, call: impl FnOnce() -> bool) -> Result<(), FfiError> {
    clear_error();
    if call() {
        Ok(())
    } else {
        Err(last_error(name, 1))
    }
}

#[rustler::nif]
fn with_request(
    interaction: ResourceArc<InteractionResource>,
    method: String,
    path: String,
) -> Outcome {
    const NAME: &str = "pactffi_with_request";
    let result = to_cstring(NAME, &method).and_then(|method| {
        let path = to_cstring(NAME, &path)?;
        check(NAME, || {
            pactffi_with_request(interaction.handle, method.as_ptr(), path.as_ptr())
        })
    });
    result.into()
}

#[rustler::nif]
fn with_query_parameter(
    interaction: ResourceArc<InteractionResource>,
    name: String,
    index: usize,
    value: String,
) -> Outcome {
    const NAME: &str = "pactffi_with_query_parameter_v2";
    let result = to_cstring(NAME, &name).and_then(|name| {
        let value = to_cstring(NAME, &value)?;
        check(NAME, || {
            pactffi_with_query_parameter_v2(
                interaction.handle,
                name.as_ptr(),
                index,
                value.as_ptr(),
            )
        })
    });
    result.into()
}

#[rustler::nif]
fn with_header(
    interaction: ResourceArc<InteractionResource>,
    part: Term,
    name: String,
    index: usize,
    value: String,
) -> NifResult<Outcome> {
    const NAME: &str = "pactffi_with_header_v2";
    let part: Part = decode_arg(part)?;
    let result = to_cstring(NAME, &name).and_then(|name| {
        let value = to_cstring(NAME, &value)?;
        check(NAME, || {
            pactffi_with_header_v2(
                interaction.handle,
                part.into(),
                name.as_ptr(),
                index,
                value.as_ptr(),
            )
        })
    });
    Ok(result.into())
}

#[rustler::nif]
fn with_body(
    interaction: ResourceArc<InteractionResource>,
    part: Term,
    content_type: String,
    body: String,
) -> NifResult<Outcome> {
    const NAME: &str = "pactffi_with_body";
    let part: Part = decode_arg(part)?;
    let result = to_cstring(NAME, &content_type).and_then(|content_type| {
        let body = to_cstring(NAME, &body)?;
        check(NAME, || {
            pactffi_with_body(
                interaction.handle,
                part.into(),
                content_type.as_ptr(),
                body.as_ptr(),
            )
        })
    });
    Ok(result.into())
}

#[rustler::nif]
fn with_binary_body(
    interaction: ResourceArc<InteractionResource>,
    part: Term,
    content_type: String,
    body: Binary,
) -> NifResult<Outcome> {
    const NAME: &str = "pactffi_with_binary_body";
    let part: Part = decode_arg(part)?;
    let result = to_cstring(NAME, &content_type).and_then(|content_type| {
        check(NAME, || {
            pactffi_with_binary_body(
                interaction.handle,
                part.into(),
                content_type.as_ptr(),
                body.as_ptr(),
                body.len(),
            )
        })
    });
    Ok(result.into())
}

#[rustler::nif]
fn response_status(interaction: ResourceArc<InteractionResource>, status: String) -> Outcome {
    const NAME: &str = "pactffi_response_status_v2";
    let result = to_cstring(NAME, &status).and_then(|status| {
        check(NAME, || {
            pactffi_response_status_v2(interaction.handle, status.as_ptr())
        })
    });
    result.into()
}
