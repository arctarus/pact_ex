//! NIFs that run, inspect and stop the mock server.

use std::ffi::{c_char, CStr};

use pact_ffi::mock_server::{
    pactffi_cleanup_mock_server, pactffi_create_mock_server_for_transport,
    pactffi_mock_server_matched, pactffi_mock_server_mismatches, pactffi_write_pact_file,
};
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};

use crate::error::{clear_error, last_error, to_cstring, FfiError, Outcome};
use crate::handles::PactResource;
use crate::stack::on_large_stack;

/// Rustler decodes `u16` with a truncating cast, so a port above 65535 would
/// silently wrap. Decode as `i64` and range-check instead; a port outside
/// `0..=65535` is a caller bug and raises `ArgumentError`.
fn port_arg(port: i64) -> NifResult<u16> {
    u16::try_from(port).map_err(|_| rustler::Error::BadArg)
}

/// Result of `create_mock_server`. Encodes as `{:ok, port}` or `{:error, map}`.
pub enum Created {
    Ok(u16),
    Err(FfiError),
}

impl Encoder for Created {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Created::Ok(port) => (rustler::types::atom::ok(), *port).encode(env),
            Created::Err(error) => (rustler::types::atom::error(), error.clone()).encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn create_mock_server(
    pact: ResourceArc<PactResource>,
    host: String,
    port: i64,
    transport: String,
    config_json: Option<String>,
) -> NifResult<Created> {
    const NAME: &str = "pactffi_create_mock_server_for_transport";
    let port = port_arg(port)?;
    let args = to_cstring(NAME, &host).and_then(|host| {
        let transport = to_cstring(NAME, &transport)?;
        let config = config_json
            .as_deref()
            .map(|config| to_cstring(NAME, config))
            .transpose()?;
        Ok((host, transport, config))
    });
    let (host, transport, config) = match args {
        Ok(args) => args,
        Err(error) => return Ok(Created::Err(error)),
    };

    let handle = pact.handle;
    Ok(on_large_stack(move || {
        clear_error();
        let config_ptr = config.as_ref().map_or(std::ptr::null(), |c| c.as_ptr());
        let code = pactffi_create_mock_server_for_transport(
            handle,
            host.as_ptr(),
            port,
            transport.as_ptr(),
            config_ptr,
        );
        match u16::try_from(code) {
            Ok(port) => Created::Ok(port),
            Err(_) => Created::Err(last_error(NAME, i64::from(code))),
        }
    }))
}

// DirtyIo: pact_ffi takes the global mock server manager mutex here, and holds
// it across file I/O (`write_pact_file`) and server shutdown (`cleanup`).
#[rustler::nif(schedule = "DirtyIo")]
fn mock_server_matched(port: i64) -> NifResult<bool> {
    Ok(pactffi_mock_server_matched(port_arg(port)?.into()))
}

// DirtyIo for the same reason as `mock_server_matched`.
#[rustler::nif(schedule = "DirtyIo")]
fn mock_server_mismatches(port: i64) -> NifResult<Option<String>> {
    let ptr: *mut c_char = pactffi_mock_server_mismatches(port_arg(port)?.into());
    if ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: a non-null result is a NUL-terminated string owned by the mock
    // server manager until `pactffi_cleanup_mock_server`. Copy it, don't free it.
    // Known window: the manager mutex is released when the FFI call returns, so a
    // concurrent cleanup of the same port could free the string before we copy
    // it. Callers must not clean up a port while reading its mismatches.
    let json = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    Ok(Some(json))
}

#[rustler::nif(schedule = "DirtyIo")]
fn write_pact_file(port: i64, dir: String, overwrite: bool) -> NifResult<Outcome> {
    const NAME: &str = "pactffi_write_pact_file";
    let port = i32::from(port_arg(port)?);
    let dir = match to_cstring(NAME, &dir) {
        Ok(dir) => dir,
        Err(error) => return Ok(Outcome::Err(error)),
    };

    Ok(on_large_stack(move || {
        clear_error();
        match pactffi_write_pact_file(port, dir.as_ptr(), overwrite) {
            0 => Outcome::Ok,
            code => Outcome::Err(last_error(NAME, i64::from(code))),
        }
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn cleanup_mock_server(port: i64) -> NifResult<bool> {
    let port = i32::from(port_arg(port)?);
    Ok(on_large_stack(move || pactffi_cleanup_mock_server(port)))
}
