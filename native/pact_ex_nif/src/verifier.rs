//! The one-shot `verify` NIF: builds a verifier handle, applies every setting,
//! runs the verification, reads the report and shuts the handle down, all on
//! one large-stack thread. No verifier handle ever reaches Elixir.

use std::ffi::{c_char, c_int, c_uchar, c_ushort, CStr, CString};

use pact_ffi::pactffi_string_delete;
use pact_ffi::verifier::handle::VerifierHandle;
use pact_ffi::verifier::{
    pactffi_verifier_add_custom_header, pactffi_verifier_add_directory_source,
    pactffi_verifier_add_file_source, pactffi_verifier_add_provider_transport,
    pactffi_verifier_broker_source_with_selectors, pactffi_verifier_execute, pactffi_verifier_json,
    pactffi_verifier_new_for_application, pactffi_verifier_output,
    pactffi_verifier_set_coloured_output, pactffi_verifier_set_consumer_filters,
    pactffi_verifier_set_filter_info, pactffi_verifier_set_no_pacts_is_error,
    pactffi_verifier_set_provider_info, pactffi_verifier_set_provider_state,
    pactffi_verifier_set_publish_options, pactffi_verifier_set_verification_options,
    pactffi_verifier_shutdown, pactffi_verifier_url_source,
};
use rustler::{NifMap, NifResult};

use crate::args::port_arg;
use crate::error::{clear_error, failure_with, fallback_message, last_error, to_cstring, FfiError};
use crate::stack::on_large_stack;

#[derive(NifMap)]
pub struct TransportConfig {
    protocol: String,
    port: i64,
    path: Option<String>,
    scheme: Option<String>,
}

#[derive(NifMap)]
pub struct PublishConfig {
    provider_version: String,
    build_url: Option<String>,
    provider_tags: Vec<String>,
    provider_branch: Option<String>,
}

#[derive(NifMap)]
pub struct HeaderConfig {
    name: String,
    value: String,
}

#[derive(NifMap)]
pub struct UrlSourceConfig {
    url: String,
    username: Option<String>,
    password: Option<String>,
    token: Option<String>,
}

#[derive(NifMap)]
pub struct BrokerConfig {
    url: String,
    username: Option<String>,
    password: Option<String>,
    token: Option<String>,
    enable_pending: bool,
    include_wip_pacts_since: Option<String>,
    provider_tags: Vec<String>,
    provider_branch: Option<String>,
    consumer_version_selectors: Vec<String>,
    consumer_version_tags: Vec<String>,
}

#[derive(NifMap)]
pub struct VerifyConfig {
    app_version: String,
    provider_name: String,
    provider_scheme: String,
    provider_host: String,
    provider_port: i64,
    provider_path: String,
    transports: Vec<TransportConfig>,
    filter_description: Option<String>,
    filter_state: Option<String>,
    filter_no_state: bool,
    state_change_url: Option<String>,
    state_change_teardown: bool,
    disable_ssl_verification: bool,
    request_timeout_ms: u64,
    publish: Option<PublishConfig>,
    consumer_filters: Vec<String>,
    custom_headers: Vec<HeaderConfig>,
    files: Vec<String>,
    dirs: Vec<String>,
    urls: Vec<UrlSourceConfig>,
    broker: Option<BrokerConfig>,
    no_pacts_is_error: bool,
}

#[derive(NifMap)]
pub struct Report {
    exit_code: i64,
    json: String,
    output: String,
}

/// Shuts the verifier handle down when it goes out of scope, so every way out
/// of `run`, errors included, releases it.
struct Handle(*mut VerifierHandle);

impl Drop for Handle {
    fn drop(&mut self) {
        pactffi_verifier_shutdown(self.0);
    }
}

/// A list of C strings that stays alive with its pointer array, for the
/// `const char *const *` arguments.
struct CStrings {
    _owned: Vec<CString>,
    pointers: Vec<*const c_char>,
}

impl CStrings {
    fn new(function: &str, items: &[String]) -> Result<Self, FfiError> {
        let owned = items
            .iter()
            .map(|item| to_cstring(function, item))
            .collect::<Result<Vec<_>, _>>()?;
        let pointers = owned.iter().map(|item| item.as_ptr()).collect();
        Ok(CStrings {
            _owned: owned,
            pointers,
        })
    }

    fn ptr(&self) -> *const *const c_char {
        if self.pointers.is_empty() {
            std::ptr::null()
        } else {
            self.pointers.as_ptr()
        }
    }

    /// The length as `c_ushort`, the type pact_ffi takes.
    fn len(&self, function: &str) -> Result<c_ushort, FfiError> {
        c_ushort::try_from(self.pointers.len()).map_err(|_| FfiError {
            function: function.to_owned(),
            code: -101,
            message: "too many items, at most 65535 are allowed".to_owned(),
        })
    }
}

fn cstring(function: &str, s: &str) -> Result<CString, FfiError> {
    to_cstring(function, s)
}

fn opt_cstring(function: &str, s: &Option<String>) -> Result<Option<CString>, FfiError> {
    s.as_deref().map(|s| to_cstring(function, s)).transpose()
}

fn opt_ptr(s: &Option<CString>) -> *const c_char {
    s.as_ref().map_or(std::ptr::null(), |s| s.as_ptr())
}

/// Describes a failure code of a verifier function when pact_ffi stored no
/// message.
fn describe(function: &str, code: i64) -> Option<String> {
    match (function, code) {
        ("pactffi_verifier_broker_source_with_selectors", -1) => {
            Some("a consumer version selector is not valid JSON".to_owned())
        }
        ("pactffi_verifier_broker_source_with_selectors", -2) => {
            Some("adding the broker source panicked".to_owned())
        }
        _ => None,
    }
}

fn check(function: &str, code: c_int) -> Result<(), FfiError> {
    if code == 0 {
        Ok(())
    } else {
        Err(failure_with(function, i64::from(code), |code| {
            describe(function, code)
        }))
    }
}

/// Copies and frees a string that pact_ffi returned. `None` for NULL.
fn take_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: a non-null result is a NUL-terminated string from
    // `CString::into_raw` in pact_ffi, and it is freed exactly once here.
    let text = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    pactffi_string_delete(ptr as *mut c_char);
    Some(text)
}

/// The HTTP client of the verifier panics without a default rustls crypto
/// provider.
fn install_crypto_provider() {
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        // An error means another thread installed one first, which is fine.
        let _ = rustls::crypto::ring::default_provider().install_default();
    }
}

fn run(config: VerifyConfig) -> Result<Report, FfiError> {
    install_crypto_provider();
    const NEW: &str = "pactffi_verifier_new_for_application";

    let app = cstring(NEW, "pact_ex")?;
    let version = cstring(NEW, &config.app_version)?;
    clear_error();
    let handle = pactffi_verifier_new_for_application(app.as_ptr(), version.as_ptr());
    if handle.is_null() {
        return Err(failure_with(NEW, -1, |_| {
            Some("could not create the verifier".to_owned())
        }));
    }
    let handle = Handle(handle);
    let h = handle.0;

    // Provider and transports. `set_provider_info` replaces the whole provider,
    // transports included, so it comes first.
    const INFO: &str = "pactffi_verifier_set_provider_info";
    let name = cstring(INFO, &config.provider_name)?;
    let scheme = cstring(INFO, &config.provider_scheme)?;
    let host = cstring(INFO, &config.provider_host)?;
    let path = cstring(INFO, &config.provider_path)?;
    pactffi_verifier_set_provider_info(
        h,
        name.as_ptr(),
        scheme.as_ptr(),
        host.as_ptr(),
        config.provider_port as c_ushort,
        path.as_ptr(),
    );

    const TRANSPORT: &str = "pactffi_verifier_add_provider_transport";
    for transport in &config.transports {
        let protocol = cstring(TRANSPORT, &transport.protocol)?;
        let path = opt_cstring(TRANSPORT, &transport.path)?;
        let scheme = opt_cstring(TRANSPORT, &transport.scheme)?;
        pactffi_verifier_add_provider_transport(
            h,
            protocol.as_ptr(),
            transport.port as c_ushort,
            opt_ptr(&path),
            opt_ptr(&scheme),
        );
    }

    if config.filter_description.is_some()
        || config.filter_state.is_some()
        || config.filter_no_state
    {
        const FILTER: &str = "pactffi_verifier_set_filter_info";
        let description = opt_cstring(FILTER, &config.filter_description)?;
        let state = opt_cstring(FILTER, &config.filter_state)?;
        pactffi_verifier_set_filter_info(
            h,
            opt_ptr(&description),
            opt_ptr(&state),
            c_uchar::from(config.filter_no_state),
        );
    }

    if let Some(url) = &config.state_change_url {
        let url = cstring("pactffi_verifier_set_provider_state", url)?;
        pactffi_verifier_set_provider_state(
            h,
            url.as_ptr(),
            c_uchar::from(config.state_change_teardown),
            1,
        );
    }

    const OPTIONS: &str = "pactffi_verifier_set_verification_options";
    clear_error();
    check(
        OPTIONS,
        pactffi_verifier_set_verification_options(
            h,
            c_uchar::from(config.disable_ssl_verification),
            config.request_timeout_ms as std::ffi::c_ulong,
        ),
    )?;

    // Coloured output is on by default and `strip_ansi` cleans only `output`.
    const COLOUR: &str = "pactffi_verifier_set_coloured_output";
    clear_error();
    check(COLOUR, pactffi_verifier_set_coloured_output(h, 0))?;

    if let Some(publish) = &config.publish {
        const PUBLISH: &str = "pactffi_verifier_set_publish_options";
        let version = cstring(PUBLISH, &publish.provider_version)?;
        let build_url = opt_cstring(PUBLISH, &publish.build_url)?;
        let branch = opt_cstring(PUBLISH, &publish.provider_branch)?;
        let tags = CStrings::new(PUBLISH, &publish.provider_tags)?;
        clear_error();
        check(
            PUBLISH,
            pactffi_verifier_set_publish_options(
                h,
                version.as_ptr(),
                opt_ptr(&build_url),
                tags.ptr(),
                tags.len(PUBLISH)?,
                opt_ptr(&branch),
            ),
        )?;
    }

    const CONSUMERS: &str = "pactffi_verifier_set_consumer_filters";
    let consumers = CStrings::new(CONSUMERS, &config.consumer_filters)?;
    pactffi_verifier_set_consumer_filters(h, consumers.ptr(), consumers.len(CONSUMERS)?);

    const HEADER: &str = "pactffi_verifier_add_custom_header";
    for header in &config.custom_headers {
        let name = cstring(HEADER, &header.name)?;
        let value = cstring(HEADER, &header.value)?;
        pactffi_verifier_add_custom_header(h, name.as_ptr(), value.as_ptr());
    }

    const FILE: &str = "pactffi_verifier_add_file_source";
    for file in &config.files {
        pactffi_verifier_add_file_source(h, cstring(FILE, file)?.as_ptr());
    }

    const DIR: &str = "pactffi_verifier_add_directory_source";
    for dir in &config.dirs {
        pactffi_verifier_add_directory_source(h, cstring(DIR, dir)?.as_ptr());
    }

    const URL: &str = "pactffi_verifier_url_source";
    for source in &config.urls {
        let url = cstring(URL, &source.url)?;
        let username = opt_cstring(URL, &source.username)?;
        let password = opt_cstring(URL, &source.password)?;
        let token = opt_cstring(URL, &source.token)?;
        pactffi_verifier_url_source(
            h,
            url.as_ptr(),
            opt_ptr(&username),
            opt_ptr(&password),
            opt_ptr(&token),
        );
    }

    if let Some(broker) = &config.broker {
        const BROKER: &str = "pactffi_verifier_broker_source_with_selectors";
        let url = cstring(BROKER, &broker.url)?;
        let username = opt_cstring(BROKER, &broker.username)?;
        let password = opt_cstring(BROKER, &broker.password)?;
        let token = opt_cstring(BROKER, &broker.token)?;
        let wip = opt_cstring(BROKER, &broker.include_wip_pacts_since)?;
        let branch = opt_cstring(BROKER, &broker.provider_branch)?;
        let provider_tags = CStrings::new(BROKER, &broker.provider_tags)?;
        let selectors = CStrings::new(BROKER, &broker.consumer_version_selectors)?;
        let consumer_tags = CStrings::new(BROKER, &broker.consumer_version_tags)?;
        clear_error();
        check(
            BROKER,
            pactffi_verifier_broker_source_with_selectors(
                h,
                url.as_ptr(),
                opt_ptr(&username),
                opt_ptr(&password),
                opt_ptr(&token),
                c_uchar::from(broker.enable_pending),
                opt_ptr(&wip),
                provider_tags.ptr(),
                provider_tags.len(BROKER)?,
                opt_ptr(&branch),
                selectors.ptr(),
                selectors.len(BROKER)?,
                consumer_tags.ptr(),
                consumer_tags.len(BROKER)?,
            ),
        )?;
    }

    const NO_PACTS: &str = "pactffi_verifier_set_no_pacts_is_error";
    clear_error();
    check(
        NO_PACTS,
        pactffi_verifier_set_no_pacts_is_error(h, c_uchar::from(config.no_pacts_is_error)),
    )?;

    const EXECUTE: &str = "pactffi_verifier_execute";
    clear_error();
    let exit_code = pactffi_verifier_execute(h);
    if exit_code != 0 {
        // A panic inside `execute` also returns 1, with an empty report that
        // says `result: true`. pact_ffi stores the panic message, which a
        // failed verification does not.
        let error = last_error(EXECUTE, i64::from(exit_code));
        if error.message != fallback_message(EXECUTE, i64::from(exit_code)) {
            return Err(error);
        }
    }

    const JSON: &str = "pactffi_verifier_json";
    let json = take_string(pactffi_verifier_json(h)).ok_or_else(|| FfiError {
        function: JSON.to_owned(),
        code: -1,
        message: "the verifier returned no report".to_owned(),
    })?;
    // A NULL output means the call panicked, for example on a NUL byte in a
    // line. The report is still good.
    let output = take_string(pactffi_verifier_output(h, 1)).unwrap_or_default();

    Ok(Report {
        exit_code: i64::from(exit_code),
        json,
        output,
    })
}

// DirtyIo: `execute` blocks on pact_ffi's runtime for the whole verification.
// Large stack: the verifier drives its futures with `block_on` on this thread.
#[rustler::nif(schedule = "DirtyIo")]
fn verify(config: VerifyConfig) -> NifResult<Result<Report, FfiError>> {
    // Rustler decodes a port as `i64` here, because it would truncate a `u16`.
    port_arg(config.provider_port)?;
    for transport in &config.transports {
        port_arg(transport.port)?;
    }

    Ok(on_large_stack(move || run(config)))
}
