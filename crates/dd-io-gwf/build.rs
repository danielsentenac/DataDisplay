use std::env;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=DD_FRAMEL_ROOT");
    println!("cargo:rustc-check-cfg=cfg(has_native_framel)");

    let Some(root) = detect_framel_root() else {
        return;
    };

    compile_framel(&root);
    println!("cargo:rustc-cfg=has_native_framel");
    println!("cargo:rustc-env=DD_FRAMEL_ROOT={}", root.display());
}

fn detect_framel_root() -> Option<PathBuf> {
    if let Ok(explicit) = env::var("DD_FRAMEL_ROOT") {
        let path = PathBuf::from(explicit);
        if is_framel_root(&path) {
            register_rerun_paths(&path);
            return Some(path);
        }
    }

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").ok()?);
    let candidates = [
        manifest_dir.join("../../../TOMCAT/Fr"),
        manifest_dir.join("../../TOMCAT/Fr"),
        manifest_dir.join("../../../Fr"),
        manifest_dir.join("../../Fr"),
    ];

    for candidate in candidates {
        if is_framel_root(&candidate) {
            register_rerun_paths(&candidate);
            return Some(candidate);
        }
    }

    None
}

fn is_framel_root(path: &Path) -> bool {
    path.join("FrameL.c").is_file()
        && path.join("FrameL.h").is_file()
        && path.join("FrIO.c").is_file()
        && path.join("FrFilter.c").is_file()
        && path.join("zlib/Frcompress.c").is_file()
}

fn register_rerun_paths(root: &Path) {
    for relative in [
        "FrameL.c",
        "FrameL.h",
        "FrIO.c",
        "FrIO.h",
        "FrFilter.c",
        "FrFilter.h",
        "FrVect.h",
        "zlib/Fradler32.c",
        "zlib/Frcompress.c",
        "zlib/Frcrc32.c",
        "zlib/Frdeflate.c",
        "zlib/Frinfblock.c",
        "zlib/Frinfcodes.c",
        "zlib/Frinffast.c",
        "zlib/Frinflate.c",
        "zlib/Frinftrees.c",
        "zlib/Frinfutil.c",
        "zlib/Frtrees.c",
        "zlib/Fruncompr.c",
        "zlib/Frzutil.c",
    ] {
        println!("cargo:rerun-if-changed={}", root.join(relative).display());
    }
}

fn compile_framel(root: &Path) {
    let frame_root = format!("\"{}\"", root.display());
    let frame_version = "\"0.0\"";
    let target_os = env::var("CARGO_CFG_TARGET_OS").ok();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").ok();
    let is_windows = target_os.as_deref() == Some("windows");
    let is_msvc = target_env.as_deref() == Some("msvc");

    let mut build = cc::Build::new();
    build
        .include(root)
        .include(root.join("zlib"))
        .define("FR_VERSION", Some(frame_version))
        .define("FR_PATH", Some(frame_root.as_str()))
        .warnings(false)
        .file(root.join("FrFilter.c"))
        .file(root.join("FrIO.c"))
        .file(root.join("FrameL.c"))
        .file(root.join("zlib/Fradler32.c"))
        .file(root.join("zlib/Frcompress.c"))
        .file(root.join("zlib/Frcrc32.c"))
        .file(root.join("zlib/Frdeflate.c"))
        .file(root.join("zlib/Frinfblock.c"))
        .file(root.join("zlib/Frinfcodes.c"))
        .file(root.join("zlib/Frinffast.c"))
        .file(root.join("zlib/Frinflate.c"))
        .file(root.join("zlib/Frinftrees.c"))
        .file(root.join("zlib/Frinfutil.c"))
        .file(root.join("zlib/Frtrees.c"))
        .file(root.join("zlib/Fruncompr.c"))
        .file(root.join("zlib/Frzutil.c"));

    if is_msvc {
        // MSVC: silence "deprecated" CRT warnings and accept the legacy GNU-C
        // shape of FrameL. Without these the C runtime emits errors for POSIX
        // names that Frame uses (read, open, ...).
        // popen/pclose live under _popen/_pclose on MSVC; remap so the
        // FrFileIOpenOSDF code path links cleanly.
        build
            .define("_CRT_SECURE_NO_WARNINGS", None)
            .define("_CRT_NONSTDC_NO_DEPRECATE", None)
            .define("popen", Some("_popen"))
            .define("pclose", Some("_pclose"))
            .flag_if_supported("/W0");
    } else {
        // GCC / Clang: keep the legacy dialect Frame was originally tuned for.
        build
            .define("_GNU_SOURCE", None)
            .flag_if_supported("-std=gnu89")
            .flag_if_supported("-Wno-incompatible-pointer-types")
            .flag_if_supported("-Wno-int-conversion");
    }

    build.compile("ddframel");

    if !is_windows {
        println!("cargo:rustc-link-lib=m");
    }
}
