# Modules that load a plugin set `@moduletag timeout: 120_000`.
#
# pact-plugin-driver holds its global plugin lock while it starts a plugin and
# waits up to 60 s for the startup line. ExUnit's default test timeout is also
# 60 s, so ExUnit would kill the test first. The native thread would keep the
# lock and the half-started plugin, and every later plugin test would wait 60 s
# and fail too. With 120 s the driver times out first, the load returns an
# error, and the cleanup runs.
#
# Keep the plugin tests off the network.
#
# When a plugin manifest is missing, pact-plugin-driver fetches the plugin index
# from GitHub. That request has no timeout and runs while the driver holds its
# global plugin lock, so on a slow network it blocks every other plugin test.
# The tests only need the offline path: the fetch fails, the driver falls back
# to the local index, and the load fails with "not found". Pointing the proxy
# at a closed port makes the fetch fail at once with "connection refused".
# Library behaviour for users does not change.
for var <- ["HTTPS_PROXY", "https_proxy"], do: System.put_env(var, "http://127.0.0.1:9")
for var <- ["NO_PROXY", "no_proxy"], do: System.put_env(var, "127.0.0.1,localhost,::1")

ExUnit.start(exclude: if(PactEx.Plugin.installed?("protobuf", "0.8.1"), do: [], else: [:plugin]))
