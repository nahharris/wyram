$ErrorActionPreference = 'Stop'
mix format
if ($LASTEXITCODE -ne 0) { throw 'mix format failed' }
cargo fmt --manifest-path native/Cargo.toml --all
if ($LASTEXITCODE -ne 0) { throw 'cargo fmt failed' }
