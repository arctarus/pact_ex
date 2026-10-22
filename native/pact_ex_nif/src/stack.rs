//! Runs blocking FFI work on a thread with a large stack.

const LARGE_STACK: usize = 8 * 1024 * 1024;

/// Runs `f` on a fresh thread with an 8 MiB stack and returns its value.
///
/// A panic in `f` is re-raised on the calling thread, where Rustler turns it
/// into an Erlang error.
///
/// `pact_ffi` keeps its last error message in a thread-local, and `f` runs on
/// its own thread. So `error::clear_error`, the FFI call and `error::last_error`
/// must all run inside `f`. Calling `last_error` after `on_large_stack`
/// returns would read the calling thread's (empty or stale) message.
#[allow(dead_code)] // Used by the blocking NIFs added in later tasks.
pub fn on_large_stack<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    let handle = std::thread::Builder::new()
        .stack_size(LARGE_STACK)
        .spawn(f)
        .expect("failed to spawn large-stack thread");

    match handle.join() {
        Ok(value) => value,
        Err(payload) => std::panic::resume_unwind(payload),
    }
}
