# Modules that load a plugin set `@moduletag timeout: 120_000`.
#
# pact-plugin-driver holds its global plugin lock while it starts a plugin and
# waits up to 60 s for the startup line. ExUnit's default test timeout is also
# 60 s, so ExUnit would kill the test first. The native thread would keep the
# lock and the half-started plugin, and every later plugin test would wait 60 s
# and fail too. With 120 s the driver times out first, the load returns an
# error, and the cleanup runs.

# Set PACT_EX_TRACE_LOG to a file path to write the native trace log there. CI
# does this on macOS: the driver logs when it waits for and gets its plugin lock,
# so a hung run shows who held it. The native logger can be applied once per OS
# process, so the one log test that applies it is excluded in that case.
trace_log = System.get_env("PACT_EX_TRACE_LOG", "")

if trace_log != "" do
  :ok = PactEx.Log.init(level: :trace, sink: {:file, trace_log})
end

excluded =
  if(PactEx.Plugin.installed?("protobuf", "0.8.1"), do: [], else: [:plugin]) ++
    if(trace_log != "", do: [:applies_logger], else: [])

ExUnit.start(exclude: excluded)
