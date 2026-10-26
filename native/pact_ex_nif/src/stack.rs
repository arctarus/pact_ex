//! Runs blocking FFI work on a thread with a large stack.

pub const LARGE_STACK: usize = 8 * 1024 * 1024;

/// Runs `f` on a fresh thread with an 8 MiB stack and returns its value.
///
/// A panic in `f` is re-raised on the calling thread, where Rustler turns it
/// into an Erlang error.
///
/// `pact_ffi` keeps its last error message in a thread-local, and `f` runs on
/// its own thread. So `error::clear_error`, the FFI call and `error::last_error`
/// must all run inside `f`. Calling `last_error` after `on_large_stack`
/// returns would read the calling thread's (empty or stale) message.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn returns_the_closure_value() {
        assert_eq!(on_large_stack(|| 21 * 2), 42);
    }

    #[test]
    fn runs_on_another_thread_with_a_large_stack() {
        let caller = std::thread::current().id();

        let (worker, sum) = on_large_stack(|| {
            // 4 MiB would overflow the default 2 MiB test-thread stack.
            let buf = [1u8; 4 * 1024 * 1024];
            let buf = std::hint::black_box(&buf);
            (
                std::thread::current().id(),
                buf.iter().map(|&b| b as usize).sum::<usize>(),
            )
        });

        assert_ne!(worker, caller);
        assert_eq!(sum, 4 * 1024 * 1024);
    }

    #[test]
    fn re_raises_a_panic_on_the_caller() {
        let result = std::panic::catch_unwind(|| on_large_stack(|| panic!("boom")));

        let payload = result.expect_err("the panic must propagate");
        let message = payload
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .expect("string panic payload");
        assert!(message.contains("boom"), "{message}");
    }
}
