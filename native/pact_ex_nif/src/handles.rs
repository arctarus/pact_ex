//! Erlang resources wrapping `pact_ffi` pact and interaction handles.

use pact_ffi::mock_server::handles::{
    pactffi_free_pact_handle, pactffi_given, pactffi_given_with_params, pactffi_new_interaction,
    pactffi_new_pact, pactffi_with_specification, InteractionHandle, PactHandle,
};
use pact_ffi::plugins::pactffi_cleanup_plugins;
use rustler::{NifResult, NifUnitEnum, Resource, ResourceArc, Term};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::OnceLock;
use std::thread;

use crate::args::{arg_cstring, decode_arg};
use crate::error::{clear_error, last_error, to_cstring, Outcome};
use crate::stack::LARGE_STACK;

pub struct PactResource {
    pub handle: PactHandle,
    /// Set once the plugins of this pact have been cleaned up.
    plugins_cleaned: AtomicBool,
}

impl PactResource {
    /// Claims the plugin cleanup of this pact. Returns true to the first call
    /// only.
    ///
    /// `pactffi_cleanup_plugins` lowers a global per-plugin access count on
    /// every call and does not check whether the pact was already cleaned up.
    /// A second call would shut down a plugin process that another pact still
    /// uses. So the guard lives here, next to the handle.
    fn claim_plugin_cleanup(&self) -> bool {
        self.plugins_cleaned
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    /// Cleans up the plugins of this pact, on the first call only. Returns
    /// whether this call did the cleanup.
    // Nothing calls this until the `cleanup_plugins` NIF of plan 2. `Drop` goes
    // through `claim_plugin_cleanup` and cleans up on the reaper thread.
    #[allow(dead_code)]
    pub fn cleanup_plugins_once(&self) -> bool {
        let claimed = self.claim_plugin_cleanup();
        if claimed {
            pactffi_cleanup_plugins(self.handle);
        }
        claimed
    }
}

#[rustler::resource_impl]
impl Resource for PactResource {}

impl Drop for PactResource {
    fn drop(&mut self) {
        hand_to_reaper(self.handle, self.claim_plugin_cleanup());
    }
}

/// A pact to clean up and free: its handle, and whether its plugins still need
/// cleaning up.
type Reap = (PactHandle, bool);

static REAPER: OnceLock<Option<Sender<Reap>>> = OnceLock::new();

/// Frees a pact on the reaper thread, so that the thread that dropped it does
/// not wait for pact_ffi's global `PACT_HANDLES` mutex (held across plugin
/// round trips) or for `PLUGIN_REGISTER` (held across plugin start-up). Drop
/// runs on whatever scheduler thread collects the resource, often a normal one.
///
/// If the reaper cannot be started or has stopped, frees the pact here.
fn hand_to_reaper(handle: PactHandle, cleanup_due: bool) {
    let sender = REAPER.get_or_init(|| {
        let (sender, receiver) = mpsc::channel::<Reap>();
        thread::Builder::new()
            .name("pact_ex_reaper".into())
            // The plugin driver runs futures with `block_on` on this thread.
            .stack_size(LARGE_STACK)
            .spawn(move || {
                for (handle, cleanup_due) in receiver {
                    reap(handle, cleanup_due);
                }
            })
            .ok()
            .map(|_| sender)
    });
    match sender
        .as_ref()
        .map(|sender| sender.send((handle, cleanup_due)))
    {
        Some(Ok(())) => {}
        _ => reap(handle, cleanup_due),
    }
}

/// Cleans up the plugins of a pact if that is still due, then frees its handle.
fn reap(handle: PactHandle, cleanup_due: bool) {
    // Cleanup reads the plugins recorded in the pact, so the handle must still
    // exist.
    if cleanup_due {
        pactffi_cleanup_plugins(handle);
    }
    pactffi_free_pact_handle(handle);
    #[cfg(test)]
    tests::record_reaped(handle);
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

// DirtyIo: every builder NIF takes pact_ffi's global `PACT_HANDLES` mutex, which
// pact_ffi holds across plugin round trips that can take seconds. Waiting for
// it must not stall a normal scheduler.
#[rustler::nif(schedule = "DirtyIo")]
fn new_pact(consumer: String, provider: String) -> NifResult<ResourceArc<PactResource>> {
    let consumer = arg_cstring(&consumer)?;
    let provider = arg_cstring(&provider)?;
    let handle = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
    Ok(ResourceArc::new(PactResource {
        handle,
        plugins_cleaned: AtomicBool::new(false),
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn with_specification(pact: ResourceArc<PactResource>, spec: Term) -> NifResult<Outcome> {
    let spec: Spec = decode_arg(spec)?;
    clear_error();
    if pactffi_with_specification(pact.handle, spec.into()) {
        Ok(Outcome::Ok)
    } else {
        Ok(Outcome::Err(last_error("pactffi_with_specification", 1)))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn new_interaction(
    pact: ResourceArc<PactResource>,
    description: String,
) -> NifResult<ResourceArc<InteractionResource>> {
    let description = arg_cstring(&description)?;
    let handle = pactffi_new_interaction(pact.handle, description.as_ptr());
    Ok(ResourceArc::new(InteractionResource { handle, pact }))
}

#[rustler::nif(schedule = "DirtyIo")]
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

#[rustler::nif(schedule = "DirtyIo")]
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
    use std::sync::Mutex;
    use std::thread::ThreadId;
    use std::time::{Duration, Instant};

    /// Where each pact was freed: the key is the handle's debug text, because
    /// pact_ffi does not expose the handle's number.
    static REAPED: Mutex<Vec<(String, ThreadId, Option<String>)>> = Mutex::new(Vec::new());

    pub(super) fn record_reaped(handle: PactHandle) {
        let thread = std::thread::current();
        REAPED.lock().unwrap().push((
            format!("{handle:?}"),
            thread.id(),
            thread.name().map(String::from),
        ));
    }

    /// Waits until `handle` has been freed and returns the thread that did it.
    fn reaped_on(handle: PactHandle) -> (ThreadId, Option<String>) {
        let key = format!("{handle:?}");
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some((_, id, name)) = REAPED.lock().unwrap().iter().find(|(k, ..)| *k == key) {
                return (*id, name.clone());
            }
            assert!(Instant::now() < deadline, "pact {key} was never freed");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

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
    fn dropping_a_pact_frees_it_on_the_reaper_thread() {
        let pact = v4_pact("consumer", "provider");
        let handle = pact.handle;
        let key = format!("{handle:?}");
        REAPED.lock().unwrap().retain(|(k, ..)| *k != key);
        drop(pact);

        let (thread, name) = reaped_on(handle);
        assert_ne!(thread, std::thread::current().id());
        assert_eq!(name.as_deref(), Some("pact_ex_reaper"));
        // Freed: pact_ffi reports 1 for a handle that does not exist.
        assert_eq!(pactffi_free_pact_handle(handle), 1);
    }

    #[test]
    fn reap_frees_the_handle_on_the_calling_thread() {
        // The fallback when the reaper thread is unavailable.
        let pact = v4_pact("consumer", "provider");
        let handle = pact.handle;
        let key = format!("{handle:?}");
        REAPED.lock().unwrap().retain(|(k, ..)| *k != key);
        // Skip Drop, so that only the `reap` call below frees the handle.
        std::mem::forget(pact);
        reap(handle, false);

        assert_eq!(reaped_on(handle).0, std::thread::current().id());
        assert_eq!(pactffi_free_pact_handle(handle), 1);
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

            // Dropping B cleans up its plugins, on the reaper thread, so no
            // plugin process stays behind once the reaper has caught up.
            drop(b);
            drop(a);
            let deadline = Instant::now() + Duration::from_secs(10);
            while !plugin_pids().is_empty() {
                assert!(Instant::now() < deadline, "plugin left running after drop");
                std::thread::sleep(Duration::from_millis(100));
            }
        });
    }
}
