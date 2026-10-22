//! NIF that configures the `pact_ffi` logger.
//!
//! `pact_ffi` builds the logger in a thread-local, so `pactffi_logger_init`,
//! `pactffi_logger_attach_sink` and `pactffi_logger_apply` must run on the same
//! thread. They run together, on one fresh thread, inside a single NIF call.
//! Neither attach nor apply stores an error message, so the messages here come
//! from [`attach_message`] and [`apply_message`].

use std::ffi::c_int;

use pact_ffi::log::{pactffi_logger_apply, pactffi_logger_attach_sink, pactffi_logger_init};
use rustler::{NifResult, NifUnitEnum, Term};

use crate::args::decode_arg;
use crate::error::{clear_error, last_error, to_cstring, FfiError, Outcome};
use crate::stack::on_large_stack;

const ATTACH: &str = "pactffi_logger_attach_sink";
const APPLY: &str = "pactffi_logger_apply";

#[derive(Clone, Copy, NifUnitEnum)]
enum Level {
    Off,
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl From<Level> for log::LevelFilter {
    fn from(level: Level) -> Self {
        match level {
            Level::Off => log::LevelFilter::Off,
            Level::Error => log::LevelFilter::Error,
            Level::Warn => log::LevelFilter::Warn,
            Level::Info => log::LevelFilter::Info,
            Level::Debug => log::LevelFilter::Debug,
            Level::Trace => log::LevelFilter::Trace,
        }
    }
}

/// Describes a failure code of `pactffi_logger_attach_sink`.
fn attach_message(code: i64, sink: &str) -> Option<String> {
    let message = match code {
        -1 => "could not set the logger".to_owned(),
        -2 => "no logger has been initialised".to_owned(),
        -3 => "log sink is not valid UTF-8".to_owned(),
        -4 => {
            format!("unknown log sink {sink:?}, expected \"stdout\", \"stderr\" or \"file <path>\"")
        }
        -5 => "no file path given for the file log sink".to_owned(),
        -6 => format!(
            "could not open log file {}",
            sink.trim().strip_prefix("file ").unwrap_or(sink)
        ),
        -7 => "could not construct the log sink".to_owned(),
        _ => return None,
    };
    Some(message)
}

/// Describes a failure code of `pactffi_logger_apply`.
fn apply_message(code: i64) -> Option<String> {
    match code {
        -1 => Some("a logger is already applied in this process".to_owned()),
        _ => None,
    }
}

/// Builds the error for a failed call. A message stored by `pact_ffi` wins;
/// otherwise `describe` supplies one for known codes.
fn failure(function: &str, code: c_int, describe: impl FnOnce(i64) -> Option<String>) -> Outcome {
    let code = i64::from(code);
    let mut error: FfiError = last_error(function, code);
    // `last_error` falls back to a message that starts with the function name.
    if error.message.starts_with(function) {
        if let Some(message) = describe(code) {
            error.message = message;
        }
    }
    Outcome::Err(error)
}

#[rustler::nif(schedule = "DirtyIo")]
fn init_logger(sink: String, level: Term) -> NifResult<Outcome> {
    let level: log::LevelFilter = decode_arg::<Level>(level)?.into();
    let spec = match to_cstring(ATTACH, &sink) {
        Ok(spec) => spec,
        Err(error) => return Ok(Outcome::Err(error)),
    };

    Ok(on_large_stack(move || {
        clear_error();
        pactffi_logger_init();
        // SAFETY: `spec` is a valid NUL-terminated string that outlives the call.
        let code = unsafe { pactffi_logger_attach_sink(spec.as_ptr(), level.into()) };
        if code != 0 {
            return failure(ATTACH, code, |code| attach_message(code, &sink));
        }

        clear_error();
        match pactffi_logger_apply() {
            0 => Outcome::Ok,
            code => failure(APPLY, code, apply_message),
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attach_message_names_the_file_path() {
        assert_eq!(
            attach_message(-6, "file /var/log/pact.log").unwrap(),
            "could not open log file /var/log/pact.log"
        );
    }

    #[test]
    fn attach_message_names_the_unknown_sink() {
        let message = attach_message(-4, "syslog").unwrap();
        assert!(message.contains("syslog"), "{message}");
    }

    #[test]
    fn every_documented_attach_code_has_a_message() {
        for code in -7..=-1 {
            assert!(attach_message(code, "stdout").is_some(), "code {code}");
        }
        assert!(attach_message(-99, "stdout").is_none());
    }

    #[test]
    fn apply_message_covers_the_already_applied_code() {
        assert!(apply_message(-1).unwrap().contains("already applied"));
        assert!(apply_message(-2).is_none());
    }

    #[test]
    fn failure_keeps_the_generic_message_for_unknown_codes() {
        clear_error();
        let Outcome::Err(error) = failure(ATTACH, -99, |code| attach_message(code, "stdout"))
        else {
            panic!("expected an error");
        };
        assert_eq!(
            error.message,
            "pactffi_logger_attach_sink failed with code -99"
        );
    }
}
