# DATADISPLAY

`DATADISPLAY` is being redesigned as a universal timeseries analysis and visualization platform:

- desktop first: Linux, Windows, macOS
- mobile possible later: Android, iOS
- not tied to gravitational-wave tooling
- format-agnostic for users: the app exposes timeseries concepts, not file-format details
- ROOT-free, `Cm`-free, and `Fr`-free in the new architecture

## Chosen Direction

This repository targets:

- `Flutter` for the multiplatform application shell
- `Rust` for the data, processing, adapter, and rendering core
- backend adapters that hide concrete storage and streaming formats behind a common API

The first concrete backend use cases are:

1. generic `HDF5`
2. `GWF` as the gravitational-wave reference adapter

## Current State

The repository now contains a runnable project foundation:

- architecture and backend design documents
- a Rust workspace with compiling core crates
- a real Flutter shell scaffold for Linux, macOS, Windows, Android, and iOS
- a source registry and backend contract in `dd-backend`
- a first concrete `HDF5` adapter path in `dd-io-hdf5`

Current implementation notes:

- the Flutter shell now binds to `dd-ffi` for `open_source`, `catalog`, `read`, and `close_source`, with a built-in demo backend fallback for tests and empty environments
- Linux desktop builds now package `dd-ffi` automatically into the Flutter bundle, and Windows/macOS build hooks are in place for the same flow
- the `HDF5` crate now opens real `.h5` files through a pure-Rust reader and maps discovered datasets into neutral stream descriptors
- the adapter still supports registered in-memory layouts for focused tests and future custom mappings
- the `GWF` crate now has a real `FrameReader` boundary plus first-pass native local Frame support for `adc`, `proc`, and `sim`; `ser` streams are cataloged but still metadata-only

## Repository Layout

- `docs/architecture.md`: system architecture and stack decision
- `docs/backend-api.md`: backend abstraction and data model contract
- `crates/dd-domain`: core domain types and helpers
- `crates/dd-backend`: source registry, queries, capabilities, and traits
- `crates/dd-processing`: processing primitives and transforms
- `crates/dd-render`: UI-independent plot scene model
- `crates/dd-io-hdf5`: generic HDF5 mapping and real file-backed read adapter
- `crates/dd-io-gwf`: GWF adapter with series-tier parsing, a low-level `FrameReader` boundary, and conditional native local Frame support
- `crates/dd-ffi`: stable JSON/C ABI boundary for the shell to open sources, browse catalog data, and read neutral blocks
- `apps/flutter_app`: Flutter shell scaffold

## Verify

```bash
source ~/.bash_profile
cd /home/sentenac/DATADISPLAY
cargo test

cd /home/sentenac/DATADISPLAY/apps/flutter_app
flutter analyze
flutter test
```

## Reading Frame data

The `dd-io-gwf` crate compiles a native local Frame reader (TOMCAT/Fr) when
the C sources are reachable. The build script (`crates/dd-io-gwf/build.rs`)
finds them in this order:

1. the path in `DD_FRAMEL_ROOT`,
2. `<repo>/../TOMCAT/Fr`, `<repo>/TOMCAT/Fr`,
3. `<repo>/../Fr`, `<repo>/Fr`.

The crate accepts `FrameL.c`, `FrIO.c`, `FrFilter.c`, and the `zlib/` files
shipped with TOMCAT/Fr. On non-MSVC toolchains it compiles with `-std=gnu89`;
on MSVC it defines `_CRT_SECURE_NO_WARNINGS` and `_CRT_NONSTDC_NO_DEPRECATE`
to accept the POSIX-flavoured names FrameL relies on.

### Windows

1. Install Visual Studio with C++ support (MSVC) and the standard Rust target
   `x86_64-pc-windows-msvc`.
2. Place `TOMCAT/Fr` next to the repository (or set `DD_FRAMEL_ROOT`).
3. `flutter build windows` — the project's CMake hook
   (`apps/flutter_app/cmake/build_and_copy_dd_ffi.cmake`) invokes
   `cargo build -p dd-ffi`, which transitively builds Frame support.
4. The resulting `dd_ffi.dll` is copied next to the Flutter `runner.exe`.

If Frame is not found, `gwf://` sources still expose catalog metadata but
the native read path is disabled.

### Windows installer (`DataDisplayWindows_setup.exe`)

The installer is produced on a `windows-latest` GitHub Actions runner via
`.github/workflows/windows-release.yml`. Frame support is mandatory in this
build, so the workflow expects a second repository that ships the
`TOMCAT/Fr` C sources.

One-time setup on GitHub:

1. Push this repository to GitHub.
2. In *Settings → Secrets and variables → Actions*:
   - Set **variable** `TOMCAT_FR_REPO` to the `owner/name` of the repo
     that holds `FrameL.c`, `FrameL.h`, `FrIO.c`, `FrFilter.c`, and the
     `zlib/` directory at its root.
   - If that repo is private, set **secret** `TOMCAT_FR_TOKEN` to a PAT
     (or GitHub App token) with read access.

To produce an installer:

- Tag a release: `git tag v0.1.0 && git push origin v0.1.0`. The workflow
  attaches `DataDisplayWindows_setup.exe` to the resulting release.
- Or run *Actions → Windows installer → Run workflow* manually. The
  installer is available as the `DataDisplayWindows_setup` artifact.

The installer script lives at `windows/installer/datadisplay.iss` and
produces `dist/DataDisplayWindows_setup.exe`. It bundles the Flutter
runner, `dd_ffi.dll`, Frame-enabled GWF, HDF5, and Tomcat adapters, and
creates Start Menu (and optionally desktop) shortcuts.

## Next Steps

1. add richer HDF5 conventions for timestamps, irregular axes, and domain-specific metadata
2. replace the ad-hoc Flutter preview canvases with `dd-render` plot scenes over the same FFI boundary
3. add session persistence and plot deck state
4. implement `GWF` as the first domain-specific adapter on the same contract
5. harden desktop distribution details such as signing, notarization, and release packaging of the native library
