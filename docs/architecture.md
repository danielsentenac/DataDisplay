# Architecture

## Vision

`DATADISPLAY` is a universal timeseries visualization and analysis application.

The user experience is centered on:

- channels, streams, and time windows
- 1D, 2D, and 3D views
- offline and online data access
- consistent interaction regardless of storage format

The application must not expose implementation-era assumptions such as:

- a specific detector domain
- a specific acquisition middleware
- a specific file format
- a specific plotting toolkit

## Product Goals

- Desktop first on Linux, Windows, and macOS
- Mobile portability without rewriting the core
- Real-time and offline workflows
- High-performance visualization for large timeseries datasets
- Replace ROOT with a portable processing and rendering core
- Support non-GW use cases without special casing the application model

## Decision Summary

### UI Shell

Use `Flutter` as the application shell.

Why:

- one codebase for Linux, Windows, macOS, Android, and iOS
- productive modern UI for catalog, session, settings, and layout work
- acceptable path for desktop-first products that may later target mobile
- clean integration path to Rust through FFI

### Core Engine

Use `Rust` for:

- domain model
- backend abstraction
- file and live adapters
- signal processing
- plot-scene generation
- future GPU rendering path

Why:

- portable across desktop and mobile
- safer than legacy C/C++ glue
- strong ecosystem for systems, numeric, and data infrastructure
- reusable independently from the UI shell

### Plotting Strategy

Do not anchor the product on a framework chart widget.

Instead:

1. define a UI-independent plot scene model in Rust
2. expose that scene to the shell
3. start with shell-side rendering for standard 1D/2D views
4. add a native GPU path for very dense 2D/3D rendering where needed

This avoids locking core visualization semantics to a single frontend toolkit.

### Data and Processing Strategy

Replace ROOT with layered responsibilities:

- in-memory interchange: Arrow-like columnar conventions
- dense numeric work: n-dimensional array model
- metadata and catalog queries: dataframe/query layer
- signal processing: explicit Rust modules
- format adapters: one adapter per storage or live protocol

The internal API is format-neutral. `HDF5`, `GWF`, and future formats are only adapters.

## System Layers

```text
Flutter App Shell
  -> session state, layout, commands, user workflows

Rust FFI Boundary
  -> stable JSON/C command bridge between UI and core

Rust Application Core
  -> source registry
  -> catalog browsing
  -> read queries
  -> processing pipeline
  -> plot-scene generation

Rust Adapters
  -> HDF5
  -> GWF
  -> future live transports

Storage / Streaming Systems
  -> files, object stores, remote services, online feeds
```

## Domain Model

The core vocabulary should be domain-neutral:

- `ChannelDescriptor`
- `TimeRange`
- `TimeAxis`
- `Series1D` for scalar timeseries
- `SampledData` for timeseries with structured samples and a separate time axis
- `Grid2D` for dense 2D analysis/static blocks
- `Volume3D` for dense 3D analysis/static blocks
- `EventSeries`
- `DataBlock`

This is the key design decision that makes the application universal rather than GW-specific.

## Backend Principles

Backends are responsible for:

- opening a source target
- listing channels or streams
- exposing metadata and capabilities
- reading selected data ranges
- subscribing to live updates when supported

Backends are not responsible for:

- plot semantics
- session layout
- frontend widgets
- application-specific interaction logic

## Format Hiding

The user should ask for:

- a source
- a channel
- a time interval
- a reduction strategy
- a view type

The user should not have to care whether the underlying source is:

- `HDF5`
- `GWF`
- a live stream
- a future object-store layout

That boundary belongs in the adapter layer.

## Rendering Model

Rendering should be split into two levels.

### Level 1: Plot Scene

The processing core emits a plot scene:

- axes
- layers
- colors
- ranges
- labels
- decimated points or cells

This is toolkit-independent.

### Level 2: Concrete Renderer

The shell or native renderer consumes the scene:

- Flutter renderer for standard UI integration
- native GPU renderer for dense heatmaps, images, and 3D

This lets the app begin productively without blocking on a full GPU stack, while preserving a path to high-end rendering later.

## Suggested Initial Crates

- `dd-domain`: domain types only
- `dd-backend`: source traits, queries, registry, capabilities
- `dd-processing`: transforms such as decimation, RMS, FFT, spectrogram
- `dd-render`: plot scene model and scene builders
- `dd-io-hdf5`: generic HDF5 adapter
- `dd-io-gwf`: GWF adapter with explicit series-tier parsing, a pluggable `FrameReader`, and conditional native local Frame support
- `dd-ffi`: stable UI/core boundary

## Current FFI Scope

The first implemented UI/core bridge is intentionally narrow.

It currently covers:

- open a source URI
- close a source
- query the source catalog
- read a neutral data block for a time range

This keeps the Flutter integration small while locking down the core concepts that matter first: sources, channels, time windows, aggregations, and neutral result blocks.

## Implementation Phases

### Phase 1

- finalize domain types
- implement backend traits
- implement `HDF5` adapter
- implement simple plot scene generation
- create Flutter shell for catalog and 1D/2D views

### Phase 2

- session persistence
- live source abstraction
- remote sources
- `GWF` adapter
- more advanced processing and annotations

### Phase 3

- dense GPU rendering for heatmaps and 3D
- mobile adaptation
- plugin API for domain-specific adapters

## What This Architecture Avoids

- a ROOT-shaped application model
- format-specific UI concepts
- direct coupling between file readers and widgets
- a backend API designed around one scientific domain only
