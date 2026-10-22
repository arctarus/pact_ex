import Config

config :rustler_precompiled, :force_build, pact_ex: config_env() in [:dev, :test]
