use std::ffi::CStr;

mod error;
mod handles;
mod stack;

#[rustler::nif]
fn version() -> String {
    // SAFETY: `pactffi_version` returns a pointer to a static NUL-terminated string.
    unsafe { CStr::from_ptr(pact_ffi::pactffi_version()) }
        .to_string_lossy()
        .into_owned()
}

rustler::init!("Elixir.PactEx.Native");
