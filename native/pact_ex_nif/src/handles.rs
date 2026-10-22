//! Erlang resources wrapping `pact_ffi` pact and interaction handles.

use pact_ffi::mock_server::handles::{
    pactffi_free_pact_handle, pactffi_given, pactffi_given_with_params, pactffi_new_interaction,
    pactffi_new_pact, pactffi_with_specification, InteractionHandle, PactHandle,
};
use rustler::{NifResult, NifUnitEnum, Resource, ResourceArc, Term};

use crate::error::{clear_error, last_error, to_cstring, Outcome};

pub struct PactResource {
    pub handle: PactHandle,
}

#[rustler::resource_impl]
impl Resource for PactResource {}

impl Drop for PactResource {
    fn drop(&mut self) {
        pactffi_free_pact_handle(self.handle);
    }
}

pub struct InteractionResource {
    pub handle: InteractionHandle,
    /// Keeps the pact alive for as long as any interaction made from it.
    #[allow(dead_code)]
    pub pact: ResourceArc<PactResource>,
}

#[rustler::resource_impl]
impl Resource for InteractionResource {}

#[derive(Clone, Copy, NifUnitEnum)]
pub enum Spec {
    V2,
    V3,
    V4,
}

impl From<Spec> for pact_models::PactSpecification {
    fn from(spec: Spec) -> Self {
        match spec {
            Spec::V2 => pact_models::PactSpecification::V2,
            Spec::V3 => pact_models::PactSpecification::V3,
            Spec::V4 => pact_models::PactSpecification::V4,
        }
    }
}

/// Raised as `ArgumentError`: a NUL byte in these arguments is a caller bug.
fn arg_cstring(s: &str) -> NifResult<std::ffi::CString> {
    std::ffi::CString::new(s).map_err(|_| rustler::Error::BadArg)
}

#[rustler::nif]
fn new_pact(consumer: String, provider: String) -> NifResult<ResourceArc<PactResource>> {
    let consumer = arg_cstring(&consumer)?;
    let provider = arg_cstring(&provider)?;
    let handle = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
    Ok(ResourceArc::new(PactResource { handle }))
}

#[rustler::nif]
fn with_specification(pact: ResourceArc<PactResource>, spec: Term) -> NifResult<Outcome> {
    // Decoding `Spec` directly would raise `ErlangError :invalid_variant`; an
    // unknown atom is a caller bug and must surface as `ArgumentError`.
    let spec: Spec = spec.decode().map_err(|_| rustler::Error::BadArg)?;
    clear_error();
    if pactffi_with_specification(pact.handle, spec.into()) {
        Ok(Outcome::Ok)
    } else {
        Ok(Outcome::Err(last_error("pactffi_with_specification", 1)))
    }
}

#[rustler::nif]
fn new_interaction(
    pact: ResourceArc<PactResource>,
    description: String,
) -> NifResult<ResourceArc<InteractionResource>> {
    let description = arg_cstring(&description)?;
    let handle = pactffi_new_interaction(pact.handle, description.as_ptr());
    Ok(ResourceArc::new(InteractionResource { handle, pact }))
}

#[rustler::nif]
fn given(interaction: ResourceArc<InteractionResource>, state: String) -> Outcome {
    const NAME: &str = "pactffi_given";
    let result = to_cstring(NAME, &state).and_then(|state| {
        clear_error();
        if pactffi_given(interaction.handle, state.as_ptr()) {
            Ok(())
        } else {
            Err(last_error(NAME, 1))
        }
    });
    result.into()
}

#[rustler::nif]
fn given_with_params(
    interaction: ResourceArc<InteractionResource>,
    state: String,
    params_json: String,
) -> Outcome {
    const NAME: &str = "pactffi_given_with_params";
    let result = to_cstring(NAME, &state).and_then(|state| {
        let params = to_cstring(NAME, &params_json)?;
        clear_error();
        match pactffi_given_with_params(interaction.handle, state.as_ptr(), params.as_ptr()) {
            0 => Ok(()),
            code => Err(last_error(NAME, i64::from(code))),
        }
    });
    result.into()
}
