//! NIFs that run, inspect and stop the mock server.

use std::ffi::{c_char, CStr};
use std::sync::{Mutex, MutexGuard};

use pact_ffi::mock_server::{
    pactffi_cleanup_mock_server, pactffi_create_mock_server_for_transport,
    pactffi_mock_server_matched, pactffi_mock_server_mismatches, pactffi_write_pact_file,
};
use rustler::{Encoder, Env, NifResult, ResourceArc, Term};

use crate::args::port_arg;
use crate::error::{clear_error, failure_with, to_cstring, FfiError, Outcome};
use crate::handles::PactResource;
use crate::stack::on_large_stack;

/// Serialises reading a mock server's mismatches and cleaning it up.
///
/// `pactffi_mock_server_mismatches` returns a pointer into memory that the
/// mock server manager owns and frees in `pactffi_cleanup_mock_server`. The
/// manager mutex is released when the FFI call returns, so without this lock a
/// cleanup could free the string while we copy it. Hold it across the call and
/// the copy, and across the cleanup. It is only ever taken before the manager
/// mutex, never inside an FFI call, so it cannot deadlock.
static MOCK_SERVER_LOCK: Mutex<()> = Mutex::new(());

/// Takes [`MOCK_SERVER_LOCK`]. The guarded data is `()`, so a poisoned lock is
/// still safe to use.
fn lock() -> MutexGuard<'static, ()> {
    MOCK_SERVER_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// Describes a failure code of `pactffi_create_mock_server_for_transport`.
fn create_message(code: i64, host: &str, port: u16) -> Option<String> {
    let message = match code {
        -1 => "invalid pact handle".to_owned(),
        -2 => "transport config is not valid JSON".to_owned(),
        -3 => format!("mock server could not be started on {host}:{port}, is the port in use?"),
        -4 => "creating the mock server panicked".to_owned(),
        -5 => format!("address {host:?} is not valid"),
        _ => return None,
    };
    Some(message)
}

/// Describes a failure code of `pactffi_write_pact_file`.
fn write_message(code: i64, port: i32, dir: &str) -> Option<String> {
    let message = match code {
        1 => "writing the pact file panicked".to_owned(),
        2 => format!("could not write the pact file to {dir}"),
        3 => format!("no mock server on port {port}"),
        _ => return None,
    };
    Some(message)
}

/// Copies the mismatches JSON of the mock server on `port`, or `None` when
/// there is no such server.
fn read_mismatches(port: i32) -> Option<String> {
    let _guard = lock();
    let ptr: *mut c_char = pactffi_mock_server_mismatches(port);
    if ptr.is_null() {
        return None;
    }
    // SAFETY: a non-null result is a NUL-terminated string owned by the mock
    // server manager until `pactffi_cleanup_mock_server`. Copy it, don't free
    // it. `MOCK_SERVER_LOCK` keeps a cleanup from freeing it during the copy.
    let json = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    Some(json)
}

/// Stops the mock server on `port`. Returns whether there was one.
fn cleanup(port: i32) -> bool {
    let _guard = lock();
    pactffi_cleanup_mock_server(port)
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
    let host_name = host.clone();
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
            Err(_) => Created::Err(failure_with(NAME, i64::from(code), |code| {
                create_message(code, &host_name, port)
            })),
        }
    }))
}

// DirtyIo: pact_ffi takes the global mock server manager mutex here, and holds
// it across file I/O (`write_pact_file`) and server shutdown (`cleanup`).
// Large stack: for a mock server provided by a plugin, pact_mock_server asks the
// plugin over gRPC with `block_on` while holding that mutex, and `block_on` runs
// the outer frames of the future on the calling thread.
#[rustler::nif(schedule = "DirtyIo")]
fn mock_server_matched(port: i64) -> NifResult<bool> {
    let port = i32::from(port_arg(port)?);
    Ok(on_large_stack(move || pactffi_mock_server_matched(port)))
}

// DirtyIo and large stack for the same reasons as `mock_server_matched`.
#[rustler::nif(schedule = "DirtyIo")]
fn mock_server_mismatches(port: i64) -> NifResult<Option<String>> {
    let port = i32::from(port_arg(port)?);
    Ok(on_large_stack(move || read_mismatches(port)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn write_pact_file(port: i64, dir: String, overwrite: bool) -> NifResult<Outcome> {
    const NAME: &str = "pactffi_write_pact_file";
    let port = i32::from(port_arg(port)?);
    let dir_name = dir.clone();
    let dir = match to_cstring(NAME, &dir) {
        Ok(dir) => dir,
        Err(error) => return Ok(Outcome::Err(error)),
    };

    Ok(on_large_stack(move || {
        clear_error();
        match pactffi_write_pact_file(port, dir.as_ptr(), overwrite) {
            0 => Outcome::Ok,
            code => Outcome::Err(failure_with(NAME, i64::from(code), |code| {
                write_message(code, port, &dir_name)
            })),
        }
    }))
}

#[rustler::nif(schedule = "DirtyIo")]
fn cleanup_mock_server(port: i64) -> NifResult<bool> {
    let port = i32::from(port_arg(port)?);
    Ok(on_large_stack(move || cleanup(port)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use pact_ffi::mock_server::handles::{
        pactffi_free_pact_handle, pactffi_new_interaction, pactffi_new_pact,
        pactffi_response_status, pactffi_with_request,
    };
    use std::ffi::CString;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;

    #[test]
    fn create_message_covers_every_documented_code() {
        for code in -5..=-1 {
            assert!(
                create_message(code, "127.0.0.1", 80).is_some(),
                "code {code}"
            );
        }
        assert!(create_message(-99, "127.0.0.1", 80).is_none());
        assert!(create_message(0, "127.0.0.1", 80).is_none());
    }

    #[test]
    fn create_message_names_the_host_and_port() {
        let message = create_message(-3, "127.0.0.1", 8080).unwrap();
        assert!(message.contains("127.0.0.1:8080"), "{message}");
        let message = create_message(-5, "no such host", 0).unwrap();
        assert!(message.contains("no such host"), "{message}");
        assert!(create_message(-2, "h", 0)
            .unwrap()
            .contains("not valid JSON"));
        assert!(create_message(-1, "h", 0).unwrap().contains("pact handle"));
        assert!(create_message(-4, "h", 0).unwrap().contains("panicked"));
    }

    #[test]
    fn write_message_covers_every_documented_code() {
        for code in 1..=3 {
            assert!(write_message(code, 80, "/tmp").is_some(), "code {code}");
        }
        assert!(write_message(0, 80, "/tmp").is_none());
        assert!(write_message(4, 80, "/tmp").is_none());
    }

    #[test]
    fn write_message_names_the_port_and_directory() {
        assert_eq!(
            write_message(3, 4321, "/x").unwrap(),
            "no mock server on port 4321"
        );
        assert!(write_message(2, 1, "/some/dir")
            .unwrap()
            .contains("/some/dir"));
        assert!(write_message(1, 1, "/x").unwrap().contains("panicked"));
    }

    #[test]
    fn a_failing_create_without_a_stored_message_gets_the_description() {
        // Port 0 and an address pact_ffi cannot parse give code -5 and no message.
        let pact = new_ping_pact();
        let host = CString::new("a".repeat(300)).unwrap();
        let transport = CString::new("http").unwrap();
        clear_error();
        let code = pactffi_create_mock_server_for_transport(
            pact,
            host.as_ptr(),
            0,
            transport.as_ptr(),
            std::ptr::null(),
        );
        assert_eq!(code, -5);
        let error = failure_with(
            "pactffi_create_mock_server_for_transport",
            i64::from(code),
            |c| create_message(c, "aaa", 0),
        );
        assert!(error.message.contains("not valid"), "{}", error.message);
        pactffi_free_pact_handle(pact);
    }

    fn new_ping_pact() -> pact_ffi::mock_server::handles::PactHandle {
        let consumer = CString::new("lock-consumer").unwrap();
        let provider = CString::new("lock-provider").unwrap();
        let description = CString::new("ping").unwrap();
        let method = CString::new("GET").unwrap();
        let path = CString::new("/ping").unwrap();
        let pact = pactffi_new_pact(consumer.as_ptr(), provider.as_ptr());
        let interaction = pactffi_new_interaction(pact, description.as_ptr());
        pactffi_with_request(interaction, method.as_ptr(), path.as_ptr());
        pactffi_response_status(interaction, 200);
        pact
    }

    fn start_server(pact: pact_ffi::mock_server::handles::PactHandle) -> i32 {
        let host = CString::new("127.0.0.1").unwrap();
        let transport = CString::new("http").unwrap();
        pactffi_create_mock_server_for_transport(
            pact,
            host.as_ptr(),
            0,
            transport.as_ptr(),
            std::ptr::null(),
        )
    }

    #[test]
    fn reading_mismatches_while_cleaning_up_the_same_port_is_safe() {
        for _ in 0..10 {
            let pact = new_ping_pact();
            let port = start_server(pact);
            assert!(port > 0, "could not start a mock server: {port}");

            let stop = Arc::new(AtomicBool::new(false));
            let readers: Vec<_> = (0..4)
                .map(|_| {
                    let stop = Arc::clone(&stop);
                    thread::spawn(move || {
                        let mut seen = 0usize;
                        while !stop.load(Ordering::Relaxed) {
                            if let Some(json) = read_mismatches(port) {
                                assert!(json.starts_with('['), "{json}");
                                seen += 1;
                            }
                        }
                        seen
                    })
                })
                .collect();

            // Let the readers run before the server goes away.
            while read_mismatches(port).is_none() {}
            thread::yield_now();
            assert!(cleanup(port));
            stop.store(true, Ordering::Relaxed);
            for reader in readers {
                reader.join().unwrap();
            }
            assert!(read_mismatches(port).is_none());
            pactffi_free_pact_handle(pact);
        }
    }

    #[test]
    fn cleanup_of_an_unknown_port_returns_false() {
        assert!(!cleanup(1));
        assert!(read_mismatches(1).is_none());
    }

    #[test]
    fn cleanup_and_mismatches_wait_for_the_lock() {
        use std::sync::mpsc;
        use std::time::Duration;

        let pact = new_ping_pact();
        let port = start_server(pact);
        assert!(port > 0);

        let guard = lock();
        let (read_tx, read_rx) = mpsc::channel();
        let (clean_tx, clean_rx) = mpsc::channel();
        let reader = thread::spawn(move || read_tx.send(read_mismatches(port)).unwrap());
        let cleaner = thread::spawn(move || clean_tx.send(cleanup(port)).unwrap());

        assert!(read_rx.recv_timeout(Duration::from_millis(200)).is_err());
        assert!(clean_rx.recv_timeout(Duration::from_millis(200)).is_err());
        drop(guard);

        reader.join().unwrap();
        cleaner.join().unwrap();
        // Which of the two ran first is not defined, but the cleanup ran once.
        read_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(clean_rx.recv_timeout(Duration::from_secs(5)).unwrap());
        assert!(read_mismatches(port).is_none());
        pactffi_free_pact_handle(pact);
    }
}
