use std::ffi::CStr;

mod args;
mod error;
mod handles;
mod http;
mod logger;
mod mock_server;
mod stack;

#[rustler::nif]
fn version() -> String {
    // SAFETY: `pactffi_version` returns a pointer to a static NUL-terminated string.
    unsafe { CStr::from_ptr(pact_ffi::pactffi_version()) }
        .to_string_lossy()
        .into_owned()
}

rustler::init!("Elixir.PactEx.Native");
