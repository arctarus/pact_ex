//! NIFs that load pact plugins and use them to build interaction contents.

use pact_ffi::mock_server::handles::{InteractionHandle, InteractionPart};
use pact_ffi::plugins::{pactffi_interaction_contents, pactffi_using_plugin};
use rustler::{NifResult, ResourceArc, Term};

use crate::args::decode_arg;
use crate::error::{clear_error, last_error, to_cstring, FfiError, Outcome};
use crate::handles::{InteractionResource, PactResource};
use crate::http::Part;
use crate::stack::on_large_stack;

const USING_PLUGIN: &str = "pactffi_using_plugin";

/// How errors name a plugin: `name version`, or just `name` without a version.
fn plugin_label(name: &str, version: Option<&str>) -> String {
    match version {
        Some(version) => format!("{name} {version}"),
        None => name.to_owned(),
    }
}

/// Puts the plugin label in front of the message. The driver's own message does
/// not always name the plugin.
fn name_plugin(label: &str, mut error: FfiError) -> FfiError {
    error.message = format!("{label}: {}", error.message);
    error
}

/// The error for a pact whose plugins were already cleaned up. The cleanup flag
/// is one-way: a plugin loaded after it would never be cleaned up and would
/// leak its process.
fn already_cleaned_up(label: &str) -> FfiError {
    name_plugin(
        label,
        FfiError {
            function: USING_PLUGIN.to_owned(),
            code: 2,
            message: "the plugins of this pact were already cleaned up".to_owned(),
        },
    )
}

/// Loads a plugin for `pact`.
fn load(pact: &PactResource, name: &str, version: Option<&str>) -> Result<(), FfiError> {
    let label = plugin_label(name, version);
    if pact.plugins_cleaned() {
        return Err(already_cleaned_up(&label));
    }
    let load = || {
        let name = to_cstring(USING_PLUGIN, name)?;
        let version = version.map(|v| to_cstring(USING_PLUGIN, v)).transpose()?;
        let version_ptr = version.as_ref().map_or(std::ptr::null(), |v| v.as_ptr());
        clear_error();
        match pactffi_using_plugin(pact.handle, name.as_ptr(), version_ptr) {
            0 => Ok(()),
            code => Err(last_error(USING_PLUGIN, i64::from(code))),
        }
    };
    load().map_err(|error| name_plugin(&label, error))
}

// DirtyIo and large stack: the plugin driver runs futures with `block_on` and
// starts the plugin process, while pact_ffi holds its global `PACT_HANDLES`
// mutex.
#[rustler::nif(schedule = "DirtyIo")]
fn using_plugin(pact: ResourceArc<PactResource>, name: String, version: Option<String>) -> Outcome {
    // A pact is not used from two processes at once, so checking the cleanup
    // flag does not need to be atomic with the load.
    on_large_stack(move || load(&pact, &name, version.as_deref())).into()
}

/// Builds the contents of one part of an interaction with a plugin.
fn set_contents(
    handle: InteractionHandle,
    part: InteractionPart,
    content_type: &str,
    contents_json: &str,
) -> Result<(), FfiError> {
    const NAME: &str = "pactffi_interaction_contents";
    let content_type = to_cstring(NAME, content_type)?;
    let contents = to_cstring(NAME, contents_json)?;
    clear_error();
    match pactffi_interaction_contents(handle, part, content_type.as_ptr(), contents.as_ptr()) {
        0 => Ok(()),
        code => Err(last_error(NAME, i64::from(code))),
    }
}

// DirtyIo and large stack: the plugin is asked for the contents over gRPC.
#[rustler::nif(schedule = "DirtyIo")]
fn interaction_contents(
    interaction: ResourceArc<InteractionResource>,
    part: Term,
    content_type: String,
    contents_json: String,
) -> NifResult<Outcome> {
    let part: Part = decode_arg(part)?;
    let handle = interaction.handle;
    Ok(on_large_stack(move || {
        set_contents(handle, part.into(), &content_type, &contents_json).into()
    }))
}

// DirtyIo and large stack: the plugin driver may `block_on` and kill a plugin
// process. Safe to call more than once: it returns true only for the call that
// did the cleanup.
#[rustler::nif(schedule = "DirtyIo")]
fn cleanup_plugins(pact: ResourceArc<PactResource>) -> bool {
    on_large_stack(move || pact.cleanup_plugins_once())
}

#[cfg(test)]
mod tests {
    use super::*;
    use pact_ffi::mock_server::handles::{
        pactffi_new_interaction, pactffi_new_pact, pactffi_with_specification,
    };
    use std::ffi::CString;

    #[test]
    fn plugin_label_joins_name_and_version() {
        assert_eq!(plugin_label("protobuf", Some("0.8.1")), "protobuf 0.8.1");
        assert_eq!(plugin_label("protobuf", None), "protobuf");
    }

    #[test]
    fn name_plugin_puts_the_label_before_the_message() {
        let error = FfiError {
            function: USING_PLUGIN.to_owned(),
            code: 2,
            message: "Could not load plugin - nope".to_owned(),
        };
        let error = name_plugin("protobuf 0.8.1", error);
        assert_eq!(
            error.message,
            "protobuf 0.8.1: Could not load plugin - nope"
        );
        assert_eq!(error.code, 2);
    }

    #[test]
    fn already_cleaned_up_names_the_plugin() {
        let error = already_cleaned_up("protobuf");
        assert_eq!(error.function, "pactffi_using_plugin");
        assert_eq!(error.code, 2);
        assert_eq!(
            error.message,
            "protobuf: the plugins of this pact were already cleaned up"
        );
    }

    fn v4_pact() -> PactResource {
        let consumer = CString::new("plugins-unit-consumer").unwrap();
        let provider = CString::new("plugins-unit-provider").unwrap();
        let handle = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
        assert!(pactffi_with_specification(
            handle,
            pact_models::PactSpecification::V4
        ));
        PactResource::new(handle)
    }

    #[test]
    fn load_refuses_a_pact_whose_plugins_were_cleaned_up() {
        let pact = v4_pact();
        assert!(pact.cleanup_plugins_once());

        let error = load(&pact, "protobuf", Some("0.8.1")).unwrap_err();
        assert_eq!(error.function, "pactffi_using_plugin");
        assert_eq!(error.code, 2);
        assert_eq!(
            error.message,
            "protobuf 0.8.1: the plugins of this pact were already cleaned up"
        );
    }

    #[test]
    fn load_names_the_plugin_when_the_nul_check_fails() {
        let pact = v4_pact();
        let error = load(&pact, "bad\0name", None).unwrap_err();
        assert_eq!(error.code, -100);
        assert!(
            error.message.starts_with("bad\0name: "),
            "{}",
            error.message
        );
    }

    #[test]
    fn set_contents_fails_for_an_invalid_content_type() {
        let pact = v4_pact();
        let description = CString::new("an interaction").unwrap();
        let interaction = pactffi_new_interaction(pact.handle, description.as_ptr());

        let error = on_large_stack(move || {
            set_contents(
                interaction,
                InteractionPart::Request,
                "not a content type",
                "{}",
            )
        })
        .unwrap_err();
        assert_eq!(error.function, "pactffi_interaction_contents");
        assert_ne!(error.code, 0);
        assert!(
            error.message.contains("not a content type"),
            "{}",
            error.message
        );
    }

    #[test]
    fn set_contents_rejects_a_nul_byte() {
        let pact = v4_pact();
        let description = CString::new("an interaction").unwrap();
        let interaction = pactffi_new_interaction(pact.handle, description.as_ptr());

        let error = set_contents(interaction, InteractionPart::Request, "a/b", "{\0}").unwrap_err();
        assert_eq!(error.code, -100);
    }
}
