$ErrorActionPreference = 'Stop'
mix format --check-formatted
if ($LASTEXITCODE -ne 0) { throw 'Elixir format check failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'Elixir compilation failed' }
mix credo --strict
if ($LASTEXITCODE -ne 0) { throw 'Credo failed' }
mix dialyzer
if ($LASTEXITCODE -ne 0) { throw 'Dialyzer failed' }
cargo fmt --manifest-path native/Cargo.toml --all --check
if ($LASTEXITCODE -ne 0) { throw 'Rust format check failed' }
cargo clippy --manifest-path native/Cargo.toml --workspace --all-targets --locked -- -D warnings
if ($LASTEXITCODE -ne 0) { throw 'Clippy failed' }
