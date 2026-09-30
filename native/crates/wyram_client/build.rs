use std::path::PathBuf;

fn main() {
    let output = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo supplies OUT_DIR"));
    let profile = output
        .ancestors()
        .nth(3)
        .and_then(|p| p.file_name())
        .and_then(|name| name.to_str())
        .expect("Cargo output contains profile directory");
    println!("cargo:rustc-env=WYRAM_NATIVE_PROFILE={profile}");
    println!(
        "cargo:rustc-env=WYRAM_OPT_LEVEL={}",
        std::env::var("OPT_LEVEL").expect("Cargo supplies OPT_LEVEL")
    );
    println!("cargo:rerun-if-changed=build.rs");
}
