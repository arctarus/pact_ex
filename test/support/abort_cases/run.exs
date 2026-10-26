# Runs one abort case, named by the ABORT_CASE environment variable, in this
# process. See PactEx.AbortCases.
PactEx.AbortCases.run(System.fetch_env!("ABORT_CASE"))
