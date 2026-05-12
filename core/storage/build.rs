use std::env;

fn main() {
    let cwd = env::current_dir().unwrap();
    // core/storage -> core -> root
    let root = cwd.parent().unwrap().parent().unwrap();
    let allocator_path = root.join("core/allocator");
    
    // Tell cargo to look for shared libraries in the specified directory
    println!("cargo:rustc-link-search=native={}", allocator_path.display());
    
    // Tell cargo to tell rustc to link the apex_allocator shared library.
    println!("cargo:rustc-link-lib=dylib=apex_allocator");
}
