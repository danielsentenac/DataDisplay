//! Stable ABI boundary between the Flutter shell and the Rust core.

use std::collections::BTreeMap;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use dd_backend::{
    Aggregation, BackendError, BackendErrorKind, CatalogQuery, DataSource, DataSourceFactory,
    ReadQuery, ResolutionHint, SourceCapabilities, SourceRegistry, StreamDescriptor, StreamKind,
};
use dd_domain::{
    ChannelDescriptor, DataBlock, Event, EventSeries, Grid2D, Metadata, SampleAxis, SampledData,
    Series1D, TimeAxis, TimeRange, Volume3D,
};
use dd_io_gwf::GwfFactory;
use dd_io_hdf5::Hdf5Factory;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

pub const ABI_VERSION: u32 = 1;

pub type EngineResult<T> = Result<T, EngineError>;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EngineErrorKind {
    Unsupported,
    NotFound,
    InvalidQuery,
    Io,
    Internal,
    InvalidRequest,
    NullPointer,
    Panic,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineError {
    pub kind: EngineErrorKind,
    pub message: String,
}

impl EngineError {
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::Unsupported,
            message: message.into(),
        }
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::NotFound,
            message: message.into(),
        }
    }

    pub fn invalid_query(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::InvalidQuery,
            message: message.into(),
        }
    }

    pub fn io(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::Io,
            message: message.into(),
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::Internal,
            message: message.into(),
        }
    }

    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::InvalidRequest,
            message: message.into(),
        }
    }

    pub fn null_pointer(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::NullPointer,
            message: message.into(),
        }
    }

    pub fn panic(message: impl Into<String>) -> Self {
        Self {
            kind: EngineErrorKind::Panic,
            message: message.into(),
        }
    }
}

impl From<BackendError> for EngineError {
    fn from(error: BackendError) -> Self {
        let kind = match error.kind {
            BackendErrorKind::Unsupported => EngineErrorKind::Unsupported,
            BackendErrorKind::NotFound => EngineErrorKind::NotFound,
            BackendErrorKind::InvalidQuery => EngineErrorKind::InvalidQuery,
            BackendErrorKind::Io => EngineErrorKind::Io,
            BackendErrorKind::Internal => EngineErrorKind::Internal,
        };

        Self {
            kind,
            message: error.message,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenSourceRequest {
    pub uri: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenSourceResponse {
    pub source_id: u64,
    pub uri: String,
    pub source_name: String,
    pub capabilities: FfiSourceCapabilities,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CloseSourceRequest {
    pub source_id: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CloseSourceResponse {
    pub source_id: u64,
    pub closed: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CatalogRequest {
    pub source_id: u64,
    pub text: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub offset: usize,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CatalogResponse {
    pub source_id: u64,
    pub total_count: usize,
    pub streams: Vec<FfiStreamDescriptor>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReadRequest {
    pub source_id: u64,
    pub channel_id: String,
    pub time_range: FfiTimeRange,
    pub resolution_hint_max_points: Option<usize>,
    #[serde(default)]
    pub aggregation: EngineAggregation,
    #[serde(default)]
    pub allow_gaps: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ReadResponse {
    pub source_id: u64,
    pub block: FfiDataBlock,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EngineAggregation {
    #[default]
    Raw,
    Mean,
    MinMax,
    Rms,
    Spectrogram {
        window_len: usize,
        step_len: usize,
    },
}

impl EngineAggregation {
    fn into_backend(self) -> Aggregation {
        match self {
            Self::Raw => Aggregation::Raw,
            Self::Mean => Aggregation::Mean,
            Self::MinMax => Aggregation::MinMax,
            Self::Rms => Aggregation::Rms,
            Self::Spectrogram {
                window_len,
                step_len,
            } => Aggregation::Spectrogram {
                window_len,
                step_len,
            },
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct FfiSourceCapabilities {
    pub catalog_search: bool,
    pub live_subscriptions: bool,
    pub volume3d: bool,
    pub metadata_write: bool,
    pub batch_read: bool,
}

impl From<SourceCapabilities> for FfiSourceCapabilities {
    fn from(capabilities: SourceCapabilities) -> Self {
        Self {
            catalog_search: capabilities.catalog_search,
            live_subscriptions: capabilities.live_subscriptions,
            volume3d: capabilities.volume3d,
            metadata_write: capabilities.metadata_write,
            batch_read: capabilities.batch_read,
        }
    }
}

impl From<&SourceCapabilities> for FfiSourceCapabilities {
    fn from(capabilities: &SourceCapabilities) -> Self {
        capabilities.clone().into()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FfiChannelDescriptor {
    pub id: String,
    pub display_name: String,
    pub unit: Option<String>,
    pub sample_rate_hz: Option<f64>,
    pub metadata: Metadata,
}

impl From<ChannelDescriptor> for FfiChannelDescriptor {
    fn from(channel: ChannelDescriptor) -> Self {
        Self {
            id: channel.id,
            display_name: channel.display_name,
            unit: channel.unit,
            sample_rate_hz: channel.sample_rate_hz,
            metadata: channel.metadata,
        }
    }
}

impl From<&ChannelDescriptor> for FfiChannelDescriptor {
    fn from(channel: &ChannelDescriptor) -> Self {
        channel.clone().into()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FfiStreamKind {
    Series1d,
    Sampled,
    Grid2d,
    Volume3d,
    EventSeries,
}

impl From<StreamKind> for FfiStreamKind {
    fn from(kind: StreamKind) -> Self {
        match kind {
            StreamKind::Series1D => Self::Series1d,
            StreamKind::Sampled => Self::Sampled,
            StreamKind::Grid2D => Self::Grid2d,
            StreamKind::Volume3D => Self::Volume3d,
            StreamKind::EventSeries => Self::EventSeries,
        }
    }
}

impl From<&StreamKind> for FfiStreamKind {
    fn from(kind: &StreamKind) -> Self {
        kind.clone().into()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FfiStreamDescriptor {
    pub channel: FfiChannelDescriptor,
    pub kind: FfiStreamKind,
    pub sample_shape: Vec<usize>,
    pub tags: Vec<String>,
    pub extra: BTreeMap<String, String>,
}

impl From<StreamDescriptor> for FfiStreamDescriptor {
    fn from(descriptor: StreamDescriptor) -> Self {
        Self {
            channel: descriptor.channel.into(),
            kind: descriptor.kind.into(),
            sample_shape: descriptor.sample_shape,
            tags: descriptor.tags,
            extra: descriptor.extra,
        }
    }
}

impl From<&StreamDescriptor> for FfiStreamDescriptor {
    fn from(descriptor: &StreamDescriptor) -> Self {
        Self {
            channel: (&descriptor.channel).into(),
            kind: (&descriptor.kind).into(),
            sample_shape: descriptor.sample_shape.clone(),
            tags: descriptor.tags.clone(),
            extra: descriptor.extra.clone(),
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct FfiTimeRange {
    pub start_ns: i64,
    pub end_ns: i64,
}

impl FfiTimeRange {
    fn into_domain(self) -> EngineResult<TimeRange> {
        let range = TimeRange::new(self.start_ns, self.end_ns);
        if range.is_valid() {
            Ok(range)
        } else {
            Err(EngineError::invalid_query(
                "read query uses an invalid time range",
            ))
        }
    }
}

impl From<TimeRange> for FfiTimeRange {
    fn from(range: TimeRange) -> Self {
        Self {
            start_ns: range.start_ns,
            end_ns: range.end_ns,
        }
    }
}

impl From<&TimeRange> for FfiTimeRange {
    fn from(range: &TimeRange) -> Self {
        (*range).clone().into()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FfiTimeAxis {
    Regular {
        start_ns: i64,
        sample_period_ns: i64,
        len: usize,
    },
    Irregular {
        timestamps_ns: Vec<i64>,
    },
}

impl From<TimeAxis> for FfiTimeAxis {
    fn from(axis: TimeAxis) -> Self {
        match axis {
            TimeAxis::Regular {
                start_ns,
                sample_period_ns,
                len,
            } => Self::Regular {
                start_ns,
                sample_period_ns,
                len,
            },
            TimeAxis::Irregular { timestamps_ns } => Self::Irregular { timestamps_ns },
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FfiSampleAxis {
    pub label: String,
    pub unit: Option<String>,
    pub len: usize,
    pub origin: Option<f64>,
    pub spacing: Option<f64>,
}

impl From<SampleAxis> for FfiSampleAxis {
    fn from(axis: SampleAxis) -> Self {
        Self {
            label: axis.label,
            unit: axis.unit,
            len: axis.len,
            origin: axis.origin,
            spacing: axis.spacing,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FfiEvent {
    pub timestamp_ns: i64,
    pub label: String,
    pub metadata: Metadata,
}

impl From<Event> for FfiEvent {
    fn from(event: Event) -> Self {
        Self {
            timestamp_ns: event.timestamp_ns,
            label: event.label,
            metadata: event.metadata,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FfiDataBlock {
    Series1d {
        channel: FfiChannelDescriptor,
        axis: FfiTimeAxis,
        values: Vec<f64>,
        metadata: Metadata,
    },
    Sampled {
        channel: FfiChannelDescriptor,
        axis: FfiTimeAxis,
        sample_shape: Vec<usize>,
        sample_axes: Vec<FfiSampleAxis>,
        values: Vec<f64>,
        metadata: Metadata,
    },
    Grid2d {
        channel: FfiChannelDescriptor,
        x_range: FfiTimeRange,
        y_label: String,
        y_unit: Option<String>,
        width: usize,
        height: usize,
        values: Vec<f32>,
        metadata: Metadata,
    },
    Volume3d {
        channel: FfiChannelDescriptor,
        x_len: usize,
        y_len: usize,
        z_len: usize,
        values: Vec<f32>,
        metadata: Metadata,
    },
    EventSeries {
        channel: FfiChannelDescriptor,
        time_range: FfiTimeRange,
        events: Vec<FfiEvent>,
        metadata: Metadata,
    },
}

impl From<DataBlock> for FfiDataBlock {
    fn from(block: DataBlock) -> Self {
        match block {
            DataBlock::Series1D(Series1D {
                channel,
                axis,
                values,
                metadata,
            }) => Self::Series1d {
                channel: channel.into(),
                axis: axis.into(),
                values,
                metadata,
            },
            DataBlock::Sampled(SampledData {
                channel,
                axis,
                sample_shape,
                sample_axes,
                values,
                metadata,
            }) => Self::Sampled {
                channel: channel.into(),
                axis: axis.into(),
                sample_shape,
                sample_axes: sample_axes.into_iter().map(FfiSampleAxis::from).collect(),
                values,
                metadata,
            },
            DataBlock::Grid2D(Grid2D {
                channel,
                x_range,
                y_label,
                y_unit,
                width,
                height,
                values,
                metadata,
            }) => Self::Grid2d {
                channel: channel.into(),
                x_range: x_range.into(),
                y_label,
                y_unit,
                width,
                height,
                values,
                metadata,
            },
            DataBlock::Volume3D(Volume3D {
                channel,
                x_len,
                y_len,
                z_len,
                values,
                metadata,
            }) => Self::Volume3d {
                channel: channel.into(),
                x_len,
                y_len,
                z_len,
                values,
                metadata,
            },
            DataBlock::EventSeries(EventSeries {
                channel,
                time_range,
                events,
                metadata,
            }) => Self::EventSeries {
                channel: channel.into(),
                time_range: time_range.into(),
                events: events.into_iter().map(FfiEvent::from).collect(),
                metadata,
            },
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum JsonEnvelope<T> {
    Ok { data: T },
    Error { error: EngineError },
}

pub struct DatadisplayEngine {
    registry: SourceRegistry,
    open_sources: BTreeMap<u64, OpenSourceHandle>,
    next_source_id: u64,
}

struct OpenSourceHandle {
    source: Box<dyn DataSource>,
}

impl DatadisplayEngine {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_registry(registry: SourceRegistry) -> Self {
        Self {
            registry,
            open_sources: BTreeMap::new(),
            next_source_id: 1,
        }
    }

    pub fn register_factory(&mut self, factory: Arc<dyn DataSourceFactory>) {
        self.registry.register(factory);
    }

    pub fn registered_schemes(&self) -> Vec<String> {
        self.registry.registered_schemes()
    }

    pub fn open_source(&mut self, request: OpenSourceRequest) -> EngineResult<OpenSourceResponse> {
        let uri = request.uri.trim().to_string();
        if uri.is_empty() {
            return Err(EngineError::invalid_query("source URI must not be empty"));
        }

        let source = self
            .registry
            .open_uri(uri.clone())
            .map_err(EngineError::from)?;
        let source_name = source.source_name().to_string();
        let capabilities = source.capabilities();
        let source_id = self.allocate_source_id()?;

        self.open_sources
            .insert(source_id, OpenSourceHandle { source });

        Ok(OpenSourceResponse {
            source_id,
            uri,
            source_name,
            capabilities: capabilities.into(),
        })
    }

    pub fn close_source(
        &mut self,
        request: CloseSourceRequest,
    ) -> EngineResult<CloseSourceResponse> {
        self.open_sources
            .remove(&request.source_id)
            .ok_or_else(|| {
                EngineError::not_found(format!("source `{}` is not open", request.source_id))
            })?;

        Ok(CloseSourceResponse {
            source_id: request.source_id,
            closed: true,
        })
    }

    pub fn catalog(&self, request: CatalogRequest) -> EngineResult<CatalogResponse> {
        let source = self.source_handle(request.source_id)?;
        let text = request
            .text
            .map(|text| text.trim().to_string())
            .filter(|text| !text.is_empty());
        let tags = request
            .tags
            .into_iter()
            .map(|tag| tag.trim().to_string())
            .filter(|tag| !tag.is_empty())
            .collect::<Vec<_>>();

        let catalog = source
            .source
            .catalog(&CatalogQuery {
                text,
                tags,
                offset: request.offset,
                limit: request.limit,
            })
            .map_err(EngineError::from)?;

        Ok(CatalogResponse {
            source_id: request.source_id,
            total_count: catalog.total_count,
            streams: catalog
                .streams
                .into_iter()
                .map(FfiStreamDescriptor::from)
                .collect(),
        })
    }

    pub fn read(&self, request: ReadRequest) -> EngineResult<ReadResponse> {
        if request.channel_id.trim().is_empty() {
            return Err(EngineError::invalid_query(
                "read query must include a channel_id",
            ));
        }

        let source = self.source_handle(request.source_id)?;
        let query = ReadQuery {
            channel_id: request.channel_id,
            time_range: request.time_range.into_domain()?,
            resolution_hint: request
                .resolution_hint_max_points
                .map(|max_points| ResolutionHint { max_points }),
            aggregation: request.aggregation.into_backend(),
            allow_gaps: request.allow_gaps,
        };

        let block = source.source.read(&query).map_err(EngineError::from)?;

        Ok(ReadResponse {
            source_id: request.source_id,
            block: block.into(),
        })
    }

    fn allocate_source_id(&mut self) -> EngineResult<u64> {
        let source_id = self.next_source_id;
        self.next_source_id = self
            .next_source_id
            .checked_add(1)
            .ok_or_else(|| EngineError::internal("source id counter overflowed"))?;
        Ok(source_id)
    }

    fn source_handle(&self, source_id: u64) -> EngineResult<&OpenSourceHandle> {
        self.open_sources
            .get(&source_id)
            .ok_or_else(|| EngineError::not_found(format!("source `{source_id}` is not open")))
    }
}

impl Default for DatadisplayEngine {
    fn default() -> Self {
        let mut registry = SourceRegistry::new();
        registry.register(Arc::new(Hdf5Factory::new()));
        registry.register(Arc::new(GwfFactory::new()));

        Self {
            registry,
            open_sources: BTreeMap::new(),
            next_source_id: 1,
        }
    }
}

pub struct EngineHandle {
    engine: Mutex<DatadisplayEngine>,
}

#[no_mangle]
pub extern "C" fn dd_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn dd_engine_new() -> *mut EngineHandle {
    Box::into_raw(Box::new(EngineHandle {
        engine: Mutex::new(DatadisplayEngine::default()),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn dd_engine_free(handle: *mut EngineHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub unsafe extern "C" fn dd_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    unsafe {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub unsafe extern "C" fn dd_engine_open_source_json(
    handle: *mut EngineHandle,
    request_json: *const c_char,
) -> *mut c_char {
    engine_json_call(handle, request_json, DatadisplayEngine::open_source)
}

#[no_mangle]
pub unsafe extern "C" fn dd_engine_close_source_json(
    handle: *mut EngineHandle,
    request_json: *const c_char,
) -> *mut c_char {
    engine_json_call(handle, request_json, DatadisplayEngine::close_source)
}

#[no_mangle]
pub unsafe extern "C" fn dd_engine_catalog_json(
    handle: *mut EngineHandle,
    request_json: *const c_char,
) -> *mut c_char {
    engine_json_call(handle, request_json, |engine, request| {
        engine.catalog(request)
    })
}

#[no_mangle]
pub unsafe extern "C" fn dd_engine_read_json(
    handle: *mut EngineHandle,
    request_json: *const c_char,
) -> *mut c_char {
    engine_json_call(handle, request_json, |engine, request| engine.read(request))
}

fn engine_json_call<TRequest, TResponse>(
    handle: *mut EngineHandle,
    request_json: *const c_char,
    operation: impl FnOnce(&mut DatadisplayEngine, TRequest) -> EngineResult<TResponse>,
) -> *mut c_char
where
    TRequest: DeserializeOwned,
    TResponse: Serialize,
{
    let result = catch_unwind(AssertUnwindSafe(|| {
        let request = parse_json_request::<TRequest>(request_json)?;
        let engine = if handle.is_null() {
            return Err(EngineError::null_pointer("engine handle is null"));
        } else {
            unsafe {
                handle
                    .as_ref()
                    .ok_or_else(|| EngineError::null_pointer("engine handle is null"))?
            }
        };
        let mut engine = engine
            .engine
            .lock()
            .map_err(|_| EngineError::internal("engine mutex is poisoned"))?;
        operation(&mut engine, request)
    }));

    match result {
        Ok(response) => envelope_to_c_string(response),
        Err(_) => envelope_to_c_string::<TResponse>(Err(EngineError::panic(
            "panic crossed the FFI command boundary",
        ))),
    }
}

fn parse_json_request<T: DeserializeOwned>(request_json: *const c_char) -> EngineResult<T> {
    if request_json.is_null() {
        return Err(EngineError::null_pointer("request_json pointer is null"));
    }

    let request_text = unsafe {
        CStr::from_ptr(request_json).to_str().map_err(|error| {
            EngineError::invalid_request(format!("request JSON is not valid UTF-8: {error}"))
        })?
    };

    serde_json::from_str(request_text).map_err(|error| {
        EngineError::invalid_request(format!("request JSON could not be parsed: {error}"))
    })
}

fn envelope_to_c_string<T: Serialize>(result: EngineResult<T>) -> *mut c_char {
    let envelope = match result {
        Ok(data) => JsonEnvelope::Ok { data },
        Err(error) => JsonEnvelope::Error { error },
    };

    let json = serde_json::to_string(&envelope).unwrap_or_else(|error| {
        format!(
            "{{\"status\":\"error\",\"error\":{{\"kind\":\"internal\",\"message\":{message}}}}}",
            message = serde_json::to_string(&format!("failed to serialize response: {error}"))
                .unwrap_or_else(|_| "\"failed to serialize response\"".to_string())
        )
    });

    CString::new(json)
        .expect("serialized JSON response should not contain interior NUL bytes")
        .into_raw()
}

#[cfg(test)]
mod tests {
    use std::ffi::{CStr, CString};
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    fn temp_hdf5_path(stem: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "datadisplay_{stem}_{}_{}.h5",
            std::process::id(),
            unique
        ))
    }

    fn create_real_hdf5_fixture() -> PathBuf {
        let path = temp_hdf5_path("ffi_fixture");
        let script = r#"
import sys
import numpy as np
import h5py

path = sys.argv[1]
with h5py.File(path, "w") as f:
    series = f.create_dataset("channels/darm", data=np.arange(8, dtype=np.float64))
    series.attrs["dd_channel_id"] = "LSC.DARM_ERR"
    series.attrs["dd_display_name"] = "DARM error"
    series.attrs["units"] = "strain"
    series.attrs["dd_tags"] = "control,analysis"
    series.attrs["start_ns"] = np.int64(10)
    series.attrs["sample_period_ns"] = np.int64(2)

    grid = f.create_dataset("derived/spectrogram", data=np.arange(12, dtype=np.float32).reshape(4, 3))
    grid.attrs["dd_display_name"] = "Spectrogram"
    grid.attrs["dd_y_label"] = "Frequency"
    grid.attrs["dd_y_unit"] = "Hz"
    grid.attrs["start_ns"] = np.int64(100)
    grid.attrs["sample_period_ns"] = np.int64(5)

    volume = f.create_dataset("volumes/cube", data=np.arange(24, dtype=np.uint16).reshape(2, 3, 4))
    volume.attrs["dd_display_name"] = "Volume cube"
"#;

        let status = Command::new("python3")
            .args([
                "-c",
                script,
                path.to_str().expect("temp path should be valid utf-8"),
            ])
            .status()
            .expect("python3 should be available for test fixture generation");

        assert!(status.success(), "python fixture generation should succeed");
        path
    }

    fn fixture_uri(path: &PathBuf) -> String {
        format!("hdf5://{}", path.display())
    }

    unsafe fn take_json_string(value: *mut c_char) -> String {
        assert!(!value.is_null(), "FFI call should return a JSON pointer");
        let json = unsafe {
            CStr::from_ptr(value)
                .to_str()
                .expect("JSON response should be valid UTF-8")
                .to_string()
        };
        unsafe {
            dd_string_free(value);
        }
        json
    }

    unsafe fn call_json<TRequest: Serialize, TResponse: DeserializeOwned>(
        handle: *mut EngineHandle,
        request: &TRequest,
        function: unsafe extern "C" fn(*mut EngineHandle, *const c_char) -> *mut c_char,
    ) -> JsonEnvelope<TResponse> {
        let request_json = serde_json::to_string(request).expect("request should serialize");
        let request_cstring =
            CString::new(request_json).expect("JSON should not contain interior NUL");
        let response_ptr = unsafe { function(handle, request_cstring.as_ptr()) };
        let response_json = unsafe { take_json_string(response_ptr) };
        serde_json::from_str(&response_json).expect("response envelope should deserialize")
    }

    #[test]
    fn engine_registers_hdf5_by_default() {
        let engine = DatadisplayEngine::default();
        assert_eq!(
            engine.registered_schemes(),
            vec!["hdf5".to_string(), "gwf".to_string()]
        );
    }

    #[test]
    fn engine_opens_catalogs_and_reads_real_hdf5_sources() {
        let path = create_real_hdf5_fixture();
        let result = (|| {
            let mut engine = DatadisplayEngine::default();
            let open = engine.open_source(OpenSourceRequest {
                uri: fixture_uri(&path),
            })?;

            assert!(open.capabilities.catalog_search);
            assert!(open.capabilities.batch_read);

            let catalog = engine.catalog(CatalogRequest {
                source_id: open.source_id,
                text: Some("darm".to_string()),
                tags: vec!["control".to_string()],
                offset: 0,
                limit: Some(5),
            })?;

            assert_eq!(catalog.total_count, 1);
            assert_eq!(catalog.streams.len(), 1);
            assert_eq!(catalog.streams[0].channel.id, "LSC.DARM_ERR");
            assert_eq!(catalog.streams[0].kind, FfiStreamKind::Series1d);

            let read = engine.read(ReadRequest {
                source_id: open.source_id,
                channel_id: "LSC.DARM_ERR".to_string(),
                time_range: FfiTimeRange {
                    start_ns: 14,
                    end_ns: 26,
                },
                resolution_hint_max_points: Some(3),
                aggregation: EngineAggregation::Mean,
                allow_gaps: false,
            })?;

            match read.block {
                FfiDataBlock::Series1d {
                    channel,
                    axis,
                    values,
                    metadata,
                } => {
                    assert_eq!(channel.id, "LSC.DARM_ERR");
                    assert_eq!(channel.unit.as_deref(), Some("strain"));
                    assert_eq!(values, vec![2.5, 4.5, 6.5]);
                    assert_eq!(
                        metadata.get("hdf5.attr.dd_display_name"),
                        Some(&"DARM error".to_string())
                    );

                    let FfiTimeAxis::Regular {
                        start_ns,
                        sample_period_ns,
                        len,
                    } = axis
                    else {
                        panic!("expected regular time axis");
                    };

                    assert_eq!((start_ns, sample_period_ns, len), (14, 4, 3));
                }
                other => panic!("expected series block, got {other:?}"),
            }

            engine.close_source(CloseSourceRequest {
                source_id: open.source_id,
            })?;

            Ok::<(), EngineError>(())
        })();

        let _ = std::fs::remove_file(&path);
        result.expect("engine flow should succeed");
    }

    #[test]
    fn ffi_json_commands_round_trip_real_hdf5_reads() {
        let path = create_real_hdf5_fixture();
        let result = (|| -> Result<(), String> {
            unsafe {
                let handle = dd_engine_new();
                assert!(!handle.is_null(), "engine handle should be allocated");

                let open = match call_json::<_, OpenSourceResponse>(
                    handle,
                    &OpenSourceRequest {
                        uri: fixture_uri(&path),
                    },
                    dd_engine_open_source_json,
                ) {
                    JsonEnvelope::Ok { data } => data,
                    JsonEnvelope::Error { error } => panic!("open failed: {error:?}"),
                };

                let catalog = match call_json::<_, CatalogResponse>(
                    handle,
                    &CatalogRequest {
                        source_id: open.source_id,
                        text: Some("spectrogram".to_string()),
                        tags: Vec::new(),
                        offset: 0,
                        limit: None,
                    },
                    dd_engine_catalog_json,
                ) {
                    JsonEnvelope::Ok { data } => data,
                    JsonEnvelope::Error { error } => panic!("catalog failed: {error:?}"),
                };

                assert_eq!(catalog.total_count, 1);
                assert_eq!(catalog.streams.len(), 1);
                assert_eq!(catalog.streams[0].kind, FfiStreamKind::Grid2d);
                assert_eq!(catalog.streams[0].channel.id, "/derived/spectrogram");

                let read = match call_json::<_, ReadResponse>(
                    handle,
                    &ReadRequest {
                        source_id: open.source_id,
                        channel_id: "/derived/spectrogram".to_string(),
                        time_range: FfiTimeRange {
                            start_ns: 100,
                            end_ns: 120,
                        },
                        resolution_hint_max_points: None,
                        aggregation: EngineAggregation::Raw,
                        allow_gaps: false,
                    },
                    dd_engine_read_json,
                ) {
                    JsonEnvelope::Ok { data } => data,
                    JsonEnvelope::Error { error } => panic!("read failed: {error:?}"),
                };

                match read.block {
                    FfiDataBlock::Grid2d {
                        width,
                        height,
                        y_label,
                        y_unit,
                        ..
                    } => {
                        assert_eq!((width, height), (4, 3));
                        assert_eq!(y_label, "Frequency");
                        assert_eq!(y_unit.as_deref(), Some("Hz"));
                    }
                    other => panic!("expected grid block, got {other:?}"),
                }

                let close = match call_json::<_, CloseSourceResponse>(
                    handle,
                    &CloseSourceRequest {
                        source_id: open.source_id,
                    },
                    dd_engine_close_source_json,
                ) {
                    JsonEnvelope::Ok { data } => data,
                    JsonEnvelope::Error { error } => panic!("close failed: {error:?}"),
                };

                assert!(close.closed);

                dd_engine_free(handle);
            }

            Ok(())
        })();

        let _ = std::fs::remove_file(&path);
        result.expect("FFI round trip should succeed");
    }
}
