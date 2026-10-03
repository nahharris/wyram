{plugin_formatter, _} = Code.eval_file("apps/wyram_plugin_api/.formatter.exs")

[
  locals_without_parens: plugin_formatter[:export][:locals_without_parens],
  inputs: [
    "{mix,.formatter}.exs",
    "apps/**/*.{ex,exs}",
    "apps/wyram_plugin_api/.formatter.exs",
    "plugins/**/*.{ex,exs}",
    "test/fixtures/plugins/**/*.{ex,exs}",
    "bench/**/*.exs",
    "scripts/**/*.exs"
  ]
]
