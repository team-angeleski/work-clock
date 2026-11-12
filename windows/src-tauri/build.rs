fn main() {
    // The board's public key lives in server/anon.key (never committed). Baked in at build time.
    let key = std::fs::read_to_string("../../server/anon.key").unwrap_or_default();
    println!("cargo:rustc-env=WORKCLOCK_ANON_KEY={}", key.trim());
    println!("cargo:rerun-if-changed=../../server/anon.key");
    tauri_build::build()
}
