# Backend API

## Purpose

The backend contract makes all data sources look the same to the application core.

The application asks for:

- catalog information
- metadata
- time-ranged reads
- optional live subscriptions

Backends hide:

- file format
- transport protocol
- archive layout
- domain-specific storage quirks

## Core Concepts

### Source Target

A source target identifies where data lives.

Examples:

- `hdf5:///data/run01.h5`
- `gwf:///archive/V1_R_1269363400.gwf?series=raw`
- `demo://local`
- `stream://host/topic`

### Channel Descriptor

A channel descriptor is the canonical frontend object for a stream-like entity.

It includes:

- stable identifier
- display name
- optional unit
- optional sample rate
- human tags
- free metadata

### Read Query

A read query should be independent from storage format.

It should describe:

- channel identifier
- requested time range
- resolution hint
- aggregation strategy
- whether gaps are acceptable

### Data Block

The read result is a domain block:

- `Series1D` for scalar timeseries
- `SampledData` for timeseries where each timestamp carries a structured sample
- `Grid2D` for dense 2D analysis/static blocks
- `Volume3D` for dense 3D analysis/static blocks
- `EventSeries`

## Rust Shape

The current repository models the contract around these traits:

```rust
pub trait DataSource {
    fn source_name(&self) -> &str;
    fn capabilities(&self) -> SourceCapabilities;
    fn catalog(&self, query: &CatalogQuery) -> BackendResult<Vec<StreamDescriptor>>;
    fn read(&self, query: &ReadQuery) -> BackendResult<DataBlock>;
}

pub trait LiveDataSource {
    fn subscribe(&self, request: SubscribeRequest)
        -> BackendResult<Box<dyn LiveSubscription>>;
}

pub trait LiveSubscription {
    fn poll_next(&mut self) -> BackendResult<Option<DataBlock>>;
}

pub trait DataSourceFactory {
    fn scheme(&self) -> &str;
    fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>>;
}
```

## Current Implementation

The repository now includes:

- a working `SourceRegistry`
- query validation and normalized backend errors
- stream descriptors with text and tag filtering
- a real `HDF5` adapter path that discovers datasets from actual `.h5` files
- a stable `dd-ffi` JSON/C ABI that opens sources, lists catalogs, reads neutral blocks, and returns normalized errors
- a fallback registered-layout path for tests and explicit mappings

The current `HDF5` crate is intentionally focused on the mapping contract and read semantics. It now performs real file discovery and lazy reads, but still uses a conservative first-pass convention set rather than trying to model every HDF5 pattern.

## Capability Model

Capabilities are explicit so the shell can adapt the UI without guessing.

Examples:

- supports catalog search
- supports live subscriptions
- supports 3D blocks
- supports metadata writes
- supports multi-read batching

## HDF5 Adapter

The `HDF5` adapter is the first universal adapter because it is:

- widely used outside GW
- flexible enough to represent multiple timeseries layouts
- a good forcing function for generic metadata and path handling

The `HDF5` adapter must define a mapping layer from arbitrary dataset structures to:

- channels
- axes
- units
- metadata

The application core should never depend on raw HDF5 object semantics.

Current first-pass conventions:

- rank-1 numeric datasets map to `Series1D`
- richer payloads that are intrinsically timeseries with structured samples should map to `SampledData`, where `time` lives in the external time axis and `sample_shape` describes the payload at each timestamp
- the current HDF5 adapter still uses `Grid2D` and `Volume3D` for plain rank-2 and rank-3 dense datasets as a narrow first pass
- scalar metadata is harvested from dataset attributes into neutral metadata
- optional attributes such as `dd_channel_id`, `dd_display_name`, `units`, `start_ns`, `sample_period_ns`, `dd_y_label`, `dd_y_unit`, and `dd_tags` refine the neutral mapping

This is intentionally incremental. The core contract now distinguishes scalar timeseries from generic sampled payloads, while older dense-grid conventions remain available for analysis products and simple file-backed discovery.

## GWF Adapter

The `GWF` adapter is a domain-specific use case that proves the architecture.

It should:

- parse source URIs with an explicit series tier such as `trend`, `50hz`, or `raw`
- map frame channels into the universal catalog model
- expose timeseries reads through the same `ReadQuery`
- use `Series1D` for scalar channels where the Frame vector axis is time
- use `SampledData` when the Frame payload has its own dimensions, with `time` kept outside those payload dimensions
- keep Frame provenance such as `adc`, `proc`, `sim`, and `ser` in adapter metadata rather than leaking it into the UI

The current `dd-io-gwf` crate now implements a real low-level `FrameReader` boundary. On systems where `TOMCAT/Fr` is available beside this repo, or `DD_FRAMEL_ROOT` points to that source tree, the crate compiles a native local Frame reader and maps `adc`, `proc`, and `sim` channels into neutral catalog entries and reads. `ser` channels are exposed in catalog metadata but still need a dedicated read path. If a `GWF`-specific feature is needed, it belongs in adapter metadata or a domain plugin, not in the universal base model.

## Live Sources

Live access should use the same channel and data block types as offline access.

The app should not have:

- one catalog model for files
- another catalog model for online streams

Instead, only the transport differs.

## Error Model

The backend layer should normalize errors into a small stable set:

- `Unsupported`
- `NotFound`
- `InvalidQuery`
- `Io`
- `Internal`

Adapter-specific detail can be attached as text metadata for logs and diagnostics.

## FFI Boundary

The current shell boundary is implemented in `dd-ffi`.

It exposes command-oriented requests and responses for:

- `open_source`
- `close_source`
- `catalog`
- `read`

The ABI is JSON over a C string boundary so the Flutter shell can bind to one stable surface while the Rust core continues to evolve internally.

Requests are format-neutral and results return:

- source capabilities
- stream descriptors including per-sample shape when available
- neutral `Series1D`, `SampledData`, `Grid2D`, `Volume3D`, or `EventSeries` payloads
- normalized error kinds for invalid requests, missing sources, I/O failures, and internal failures

## Non-Goals

The backend API is not responsible for:

- plot styling
- UI layout
- application session files
- detector-specific business logic
