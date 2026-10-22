//! Runs blocking FFI work on a thread with a large stack.

const LARGE_STACK: usize = 8 * 1024 * 1024;

/// Runs `f` on a fresh thread with an 8 MiB stack and returns its value.
///
/// A panic in `f` is re-raised on the calling thread, where Rustler turns it
/// into an Erlang error. Read `error::last_error` inside `f`, not after it:
/// the message lives in a thread-local of the thread that made the FFI call.
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
