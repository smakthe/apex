fn main() {
    let project_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let allocator_dir = format!("{}/../allocator", project_dir);
    let kernels_dir = format!("{}/../kernels", project_dir);
    let fpga_dir = format!("{}/../fpga", project_dir);

    println!("cargo:rustc-link-search=native={}", allocator_dir);
    println!("cargo:rustc-link-search=native={}", kernels_dir);
    println!("cargo:rustc-link-search=native={}", fpga_dir);

    // Libraries to link against are specified in #[link] attributes in src/ffi.rs
    // For macOS, we might also need to set rpath so tests can find the dylibs at runtime,
    // but the easiest way is to set DYLD_LIBRARY_PATH when running tests.
}
