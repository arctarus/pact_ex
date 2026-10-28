# Modules that load a plugin set `@moduletag timeout: 120_000`.
#
# pact-plugin-driver holds its global plugin lock while it starts a plugin and
# waits up to 60 s for the startup line. ExUnit's default test timeout is also
# 60 s, so ExUnit would kill the test first. The native thread would keep the
# lock and the half-started plugin, and every later plugin test would wait 60 s
# and fail too. With 120 s the driver times out first, the load returns an
# error, and the cleanup runs.

ExUnit.start(exclude: if(PactEx.Plugin.installed?("protobuf", "0.8.1"), do: [], else: [:plugin]))
