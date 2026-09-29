import Config

config :logger, level: :info

config :wyram_engine, Wyram.Engine.Native,
  path: "../../native/crates/wyram_nif",
  mode: if(config_env() == :prod, do: :release, else: :debug)
