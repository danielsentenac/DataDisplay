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

## Next Steps

1. add richer HDF5 conventions for timestamps, irregular axes, and domain-specific metadata
2. replace the ad-hoc Flutter preview canvases with `dd-render` plot scenes over the same FFI boundary
3. add session persistence and plot deck state
4. implement `GWF` as the first domain-specific adapter on the same contract
5. harden desktop distribution details such as signing, notarization, and release packaging of the native library
