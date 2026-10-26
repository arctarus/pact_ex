//! Erlang resources wrapping `pact_ffi` pact and interaction handles.

use pact_ffi::mock_server::handles::{
    pactffi_free_pact_handle, pactffi_given, pactffi_given_with_params, pactffi_new_interaction,
    pactffi_new_pact, pactffi_with_specification, InteractionHandle, PactHandle,
};
use pact_ffi::plugins::pactffi_cleanup_plugins;
use rustler::{NifResult, NifUnitEnum, Resource, ResourceArc, Term};
use std::sync::atomic::{AtomicBool, Ordering};

use crate::args::{arg_cstring, decode_arg};
use crate::error::{clear_error, last_error, to_cstring, Outcome};

pub struct PactResource {
    pub handle: PactHandle,
    /// Set once the plugins of this pact have been cleaned up.
    plugins_cleaned: AtomicBool,
}

impl PactResource {
    /// Cleans up the plugins of this pact, on the first call only. Returns
    /// whether this call did the cleanup.
    ///
    /// `pactffi_cleanup_plugins` lowers a global per-plugin access count on
    /// every call and does not check whether the pact was already cleaned up.
    /// A second call would shut down a plugin process that another pact still
    /// uses. So the guard lives here, next to the handle.
    pub fn cleanup_plugins_once(&self) -> bool {
        if self
            .plugins_cleaned
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            pactffi_cleanup_plugins(self.handle);
            true
        } else {
            false
        }
    }
}

#[rustler::resource_impl]
impl Resource for PactResource {}

impl Drop for PactResource {
    fn drop(&mut self) {
        // Cleanup reads the plugins recorded in the pact, so the handle must
        // still exist.
        self.cleanup_plugins_once();
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

#[rustler::nif]
fn new_pact(consumer: String, provider: String) -> NifResult<ResourceArc<PactResource>> {
    let consumer = arg_cstring(&consumer)?;
    let provider = arg_cstring(&provider)?;
    let handle = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
    Ok(ResourceArc::new(PactResource {
        handle,
        plugins_cleaned: AtomicBool::new(false),
    }))
}

#[rustler::nif]
fn with_specification(pact: ResourceArc<PactResource>, spec: Term) -> NifResult<Outcome> {
    let spec: Spec = decode_arg(spec)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stack::on_large_stack;
    use pact_ffi::mock_server::handles::{pactffi_new_message_interaction, InteractionPart};
    use pact_ffi::plugins::{pactffi_interaction_contents, pactffi_using_plugin};
    use std::ffi::CString;

    fn v4_pact(consumer: &str, provider: &str) -> PactResource {
        let consumer = CString::new(consumer).unwrap();
        let provider = CString::new(provider).unwrap();
        let handle = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
        assert!(pactffi_with_specification(
            handle,
            pact_models::PactSpecification::V4
        ));
        PactResource {
            handle,
            plugins_cleaned: AtomicBool::new(false),
        }
    }

    /// Pids of running protobuf plugin processes, found with `pgrep`.
    fn plugin_pids() -> Vec<u32> {
        let out = std::process::Command::new("pgrep")
            .args(["-f", "pact-protobuf-plugin"])
            .output()
            .expect("pgrep must be installed to run this test");
        String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .map(|pid| pid.parse().unwrap())
            .collect()
    }

    /// Gives a plugin that is shutting down time to exit.
    fn settle() {
        std::thread::sleep(std::time::Duration::from_millis(500));
    }

    #[test]
    fn cleanup_plugins_once_cleans_up_on_the_first_call_only() {
        let pact = v4_pact("consumer", "provider");
        assert!(pact.cleanup_plugins_once());
        assert!(!pact.cleanup_plugins_once());
        assert!(!pact.cleanup_plugins_once());
    }

    // Needs the protobuf plugin 0.8.1 in ~/.pact/plugins, which CI does not have.
    // Run with `cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn a_second_cleanup_of_one_pact_leaves_the_plugin_to_another_pact() {
        on_large_stack(|| {
            assert!(plugin_pids().is_empty(), "a plugin is already running");
            let a = v4_pact("consumer-a", "provider-a");
            let b = v4_pact("consumer-b", "provider-b");
            let name = CString::new("protobuf").unwrap();
            let version = CString::new("0.8.1").unwrap();
            assert_eq!(
                pactffi_using_plugin(a.handle, name.as_ptr(), version.as_ptr()),
                0
            );
            assert_eq!(
                pactffi_using_plugin(b.handle, name.as_ptr(), version.as_ptr()),
                0
            );
            let running = plugin_pids();
            assert_eq!(running.len(), 1, "one process serves both pacts");

            assert!(a.cleanup_plugins_once());
            assert!(!a.cleanup_plugins_once());
            settle();
            assert_eq!(
                plugin_pids(),
                running,
                "plugin was shut down while B used it"
            );

            let description = CString::new("a feature").unwrap();
            let interaction = pactffi_new_message_interaction(b.handle, description.as_ptr());
            let content_type = CString::new("application/protobuf").unwrap();
            let proto = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/feature.proto");
            let contents = CString::new(
                serde_json::json!({
                    "pact:proto": proto,
                    "pact:message-type": "Feature",
                    "pact:content-type": "application/protobuf",
                    "name": "notEmpty('Big Tree')"
                })
                .to_string(),
            )
            .unwrap();
            let code = pactffi_interaction_contents(
                interaction,
                InteractionPart::Request,
                content_type.as_ptr(),
                contents.as_ptr(),
            );
            assert_eq!(code, 0);
            assert_eq!(plugin_pids(), running, "plugin was restarted for B");

            // Dropping B cleans up its plugins, so no plugin process stays behind.
            drop(b);
            drop(a);
            settle();
            assert!(plugin_pids().is_empty(), "plugin left running after drop");
        });
    }
}
