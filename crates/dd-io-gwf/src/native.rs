use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_double, c_float, c_int, c_long, c_uchar, c_uint, c_ulong, c_ushort};
use std::sync::Mutex;

use dd_backend::{BackendError, BackendResult, CatalogPage, CatalogQuery, ReadQuery, StreamKind};
use dd_domain::{ChannelDescriptor, DataBlock, SampleAxis, SampledData, Series1D, TimeAxis};

use super::{
    FrameReader, GwfChannelEntry, GwfContainerKind, GwfManifest, GwfSeriesClass, GwfTemporalMode,
};

const PREVIEW_WINDOW_MIN_SEC: f64 = 1.0e-6;
const PREVIEW_WINDOW_MAX_SEC: f64 = 2.0;
const DEFAULT_PREVIEW_WINDOW_SEC: f64 = 0.25;
const GROUP_NO_DECIMATION: c_int = 1;
const FULL_FILE_WINDOW_SEC: f64 = 1.0e12;

const FR_VECT_C: c_ushort = 0;
const FR_VECT_2S: c_ushort = 1;
const FR_VECT_8R: c_ushort = 2;
const FR_VECT_4R: c_ushort = 3;
const FR_VECT_4S: c_ushort = 4;
const FR_VECT_8S: c_ushort = 5;
const FR_VECT_8C: c_ushort = 6;
const FR_VECT_16C: c_ushort = 7;
const FR_VECT_STRING: c_ushort = 8;
const FR_VECT_2U: c_ushort = 9;
const FR_VECT_4U: c_ushort = 10;
const FR_VECT_8U: c_ushort = 11;
const FR_VECT_1U: c_ushort = 12;
const FR_VECT_8H: c_ushort = 13;
const FR_VECT_16H: c_ushort = 14;

#[repr(C)]
struct FrSH {
    _private: [u8; 0],
}

#[repr(C)]
struct FrFile {
    _private: [u8; 0],
}

#[repr(C)]
struct FrVect {
    classe: *mut FrSH,
    name: *mut c_char,
    compress: c_ushort,
    type_code: c_ushort,
    n_data: c_ulong,
    n_bytes: c_ulong,
    data: *mut c_char,
    n_dim: c_uint,
    nx: *mut c_ulong,
    dx: *mut c_double,
    start_x: *mut c_double,
    unit_x: *mut *mut c_char,
    unit_y: *mut c_char,
    next: *mut FrVect,
    data_s: *mut i16,
    data_i: *mut c_int,
    data_l: *mut c_long,
    data_f: *mut c_float,
    data_d: *mut c_double,
    data_u: *mut c_uchar,
    data_us: *mut c_ushort,
    data_ui: *mut c_uint,
    data_ul: *mut c_ulong,
    data_q: *mut *mut c_char,
    w_size: c_int,
    space: c_ulong,
    g_time: c_double,
    u_leap_s: c_ushort,
    local_time: c_int,
    data_unzoomed: *mut c_char,
    n_data_unzoomed: c_ulong,
    start_x_unzoomed: c_double,
}

unsafe extern "C" {
    fn FrFileINew(file_name: *const c_char) -> *mut FrFile;
    fn FrFileIEnd(i_file: *mut FrFile);

    fn FrFileIGetAdcNames(i_file: *mut FrFile) -> *mut FrVect;
    fn FrFileIGetProcNames(i_file: *mut FrFile) -> *mut FrVect;
    fn FrFileIGetSimNames(i_file: *mut FrFile) -> *mut FrVect;
    fn FrFileIGetSerNames(i_file: *mut FrFile) -> *mut FrVect;
    fn FrFileIGetFrameInfo(i_file: *mut FrFile, t_start: c_double, length: c_double)
        -> *mut FrVect;

    fn FrFileIGetVAdc(
        i_file: *mut FrFile,
        name: *const c_char,
        t_start: c_double,
        len: c_double,
        group: c_int,
    ) -> *mut FrVect;
    fn FrFileIGetVProc(
        i_file: *mut FrFile,
        name: *const c_char,
        t_start: c_double,
        len: c_double,
        group: c_int,
    ) -> *mut FrVect;
    fn FrFileIGetVSim(
        i_file: *mut FrFile,
        name: *const c_char,
        t_start: c_double,
        len: c_double,
        group: c_int,
    ) -> *mut FrVect;

    fn FrVectFree(vect: *mut FrVect);
}

pub(super) struct NativeFrameReader {
    files: Mutex<BTreeMap<String, CachedFrameFile>>,
}

impl NativeFrameReader {
    pub fn new() -> Self {
        Self {
            files: Mutex::new(BTreeMap::new()),
        }
    }

    fn with_cached_file<T>(
        &self,
        file_path: &str,
        action: impl FnOnce(&CachedFrameFile) -> BackendResult<T>,
    ) -> BackendResult<T> {
        let mut files = self
            .files
            .lock()
            .map_err(|_| BackendError::internal("native GWF file cache lock is poisoned"))?;
        if !files.contains_key(file_path) {
            files.insert(file_path.to_string(), CachedFrameFile::open(file_path)?);
        }
        let cached = files.get(file_path).ok_or_else(|| {
            BackendError::internal(format!(
                "native GWF file cache lost the open handle for `{file_path}`"
            ))
        })?;
        action(cached)
    }
}

struct CachedFrameFile {
    handle: FrameFileHandle,
    preview_window_sec: f64,
    adc_names: Vec<String>,
    proc_names: Vec<String>,
    sim_names: Vec<String>,
    ser_names: Vec<String>,
}

impl CachedFrameFile {
    fn open(file_path: &str) -> BackendResult<Self> {
        let handle = FrameFileHandle::open(file_path)?;
        let preview_window_sec = handle.preview_window_seconds();
        let adc_names = handle.channel_names(GwfContainerKind::Adc)?;
        let proc_names = handle.channel_names(GwfContainerKind::Proc)?;
        let sim_names = handle.channel_names(GwfContainerKind::Sim)?;
        let ser_names = handle.channel_names(GwfContainerKind::Ser)?;
        Ok(Self {
            handle,
            preview_window_sec,
            adc_names,
            proc_names,
            sim_names,
            ser_names,
        })
    }

    fn channel_names(&self, kind: GwfContainerKind) -> &[String] {
        match kind {
            GwfContainerKind::Adc => &self.adc_names,
            GwfContainerKind::Proc => &self.proc_names,
            GwfContainerKind::Sim => &self.sim_names,
            GwfContainerKind::Ser => &self.ser_names,
        }
    }
}

impl FrameReader for NativeFrameReader {
    fn inspect(&self, file_path: &str, series_class: GwfSeriesClass) -> BackendResult<GwfManifest> {
        self.with_cached_file(file_path, |file| {
            let mut manifest = GwfManifest::new();

            for kind in [
                GwfContainerKind::Adc,
                GwfContainerKind::Proc,
                GwfContainerKind::Sim,
            ] {
                for channel_name in file.channel_names(kind) {
                    let entry = match file
                        .handle
                        .read_channel(kind, channel_name, 0.0, file.preview_window_sec)
                        .and_then(|vect| {
                            entry_from_vector(
                                series_class,
                                kind,
                                channel_name,
                                vect.root(),
                                file.preview_window_sec,
                            )
                        }) {
                        Ok(entry) => entry,
                        Err(error) => metadata_only_entry(
                            series_class,
                            kind,
                            channel_name,
                            Some(error.message),
                        ),
                    };
                    manifest.add_entry(entry);
                }
            }

            for channel_name in file.channel_names(GwfContainerKind::Ser) {
                manifest.add_entry(metadata_only_entry(
                    series_class,
                    GwfContainerKind::Ser,
                    channel_name,
                    Some("FrSerData direct reads are not implemented yet".to_string()),
                ));
            }

            Ok(manifest)
        })
    }

    fn catalog_descriptors(
        &self,
        file_path: &str,
        series_class: GwfSeriesClass,
        query: &CatalogQuery,
    ) -> BackendResult<CatalogPage> {
        self.with_cached_file(file_path, |file| {
            let mut descriptors = Vec::new();
            let mut matched_count = 0usize;

            for kind in [
                GwfContainerKind::Adc,
                GwfContainerKind::Proc,
                GwfContainerKind::Sim,
                GwfContainerKind::Ser,
            ] {
                for channel_name in file.channel_names(kind) {
                    let fallback_descriptor =
                        fast_catalog_entry(series_class, kind, channel_name).descriptor(file_path);
                    if !fallback_descriptor.matches(query) {
                        continue;
                    }

                    let within_page = matched_count >= query.offset
                        && query
                            .limit
                            .map(|limit| descriptors.len() < limit)
                            .unwrap_or(true);
                    matched_count += 1;
                    if !within_page {
                        continue;
                    }

                    let descriptor = match kind {
                        GwfContainerKind::Ser => fallback_descriptor,
                        _ => match file
                            .handle
                            .read_channel(kind, channel_name, 0.0, file.preview_window_sec)
                            .and_then(|vect| {
                                entry_from_vector(
                                    series_class,
                                    kind,
                                    channel_name,
                                    vect.root(),
                                    file.preview_window_sec,
                                )
                            }) {
                            Ok(entry) => entry.descriptor(file_path),
                            Err(error) => metadata_only_entry(
                                series_class,
                                kind,
                                channel_name,
                                Some(error.message),
                            )
                            .descriptor(file_path),
                        },
                    };
                    descriptors.push(descriptor);
                }
            }

            Ok(CatalogPage {
                total_count: matched_count,
                streams: descriptors,
            })
        })
    }

    fn read(
        &self,
        file_path: &str,
        _series_class: GwfSeriesClass,
        query: &ReadQuery,
    ) -> BackendResult<DataBlock> {
        let (container_kind, channel_name) = parse_channel_id(&query.channel_id)?;
        if container_kind == GwfContainerKind::Ser {
            return Err(BackendError::unsupported(format!(
                "channel `{}` is a FrSerData stream; the native reader catalogs it but does not read it yet",
                query.channel_id
            )));
        }

        self.with_cached_file(file_path, |file| {
            let start_sec = query.time_range.start_ns as f64 * 1.0e-9;
            let len_sec =
                (query.time_range.duration_ns() as f64 * 1.0e-9).max(PREVIEW_WINDOW_MIN_SEC);
            let vect =
                file.handle
                    .read_channel(container_kind, channel_name, start_sec, len_sec)?;
            let interpretation = interpret_vector(vect.root(), len_sec)?;

            let mut channel = base_channel(container_kind, channel_name);
            channel.unit = interpretation.unit.clone();
            channel.sample_rate_hz = interpretation.sample_rate_hz;
            channel.metadata.insert(
                "gwf.temporal_mode".to_string(),
                interpretation.temporal_mode.as_str().to_string(),
            );
            channel.metadata.insert(
                "gwf.element_type".to_string(),
                interpretation.element_type.clone(),
            );

            Ok(interpretation.into_block(channel))
        })
    }
}

struct FrameFileHandle {
    raw: *mut FrFile,
}

// The native Frame handle itself is not thread-safe, but DATADISPLAY only uses it
// while holding the NativeFrameReader cache mutex, so transferring ownership
// between threads is safe here.
unsafe impl Send for FrameFileHandle {}

impl FrameFileHandle {
    fn open(file_path: &str) -> BackendResult<Self> {
        let file_path_c = CString::new(file_path).map_err(|_| {
            BackendError::invalid_query(format!(
                "GWF path `{file_path}` contains an interior NUL byte"
            ))
        })?;
        let raw = unsafe { FrFileINew(file_path_c.as_ptr()) };
        if raw.is_null() {
            let is_ffl = file_path
                .rsplit('.')
                .next()
                .map(|ext| ext.eq_ignore_ascii_case("ffl"))
                .unwrap_or(false);
            let detail = if is_ffl {
                "failed to open Frame File List `{p}` through the Frame library; \
                 check that the .gwf paths listed inside the FFL are reachable on \
                 this host (FrameL passes them straight to fopen)"
            } else {
                "failed to open Frame source `{p}` through the Frame library"
            };
            return Err(BackendError::io(detail.replace("{p}", file_path)));
        }
        Ok(Self { raw })
    }

    fn preview_window_seconds(&self) -> f64 {
        let raw = unsafe { FrFileIGetFrameInfo(self.raw, 0.0, FULL_FILE_WINDOW_SEC) };
        let Some(info) = FrVectHandle::from_raw(raw) else {
            return DEFAULT_PREVIEW_WINDOW_SEC;
        };
        let root = info.root();
        if root.next.is_null() {
            return DEFAULT_PREVIEW_WINDOW_SEC;
        }
        let next = unsafe { &*root.next };
        let dt = first_scalar_value(next).unwrap_or(DEFAULT_PREVIEW_WINDOW_SEC);
        dt.mul_add(2.5, 0.0)
            .clamp(PREVIEW_WINDOW_MIN_SEC, PREVIEW_WINDOW_MAX_SEC)
    }

    fn channel_names(&self, kind: GwfContainerKind) -> BackendResult<Vec<String>> {
        let raw = unsafe {
            match kind {
                GwfContainerKind::Adc => FrFileIGetAdcNames(self.raw),
                GwfContainerKind::Proc => FrFileIGetProcNames(self.raw),
                GwfContainerKind::Sim => FrFileIGetSimNames(self.raw),
                GwfContainerKind::Ser => FrFileIGetSerNames(self.raw),
            }
        };
        let Some(vect) = FrVectHandle::from_raw(raw) else {
            return Err(BackendError::io(format!(
                "failed to enumerate {} channels from the local GWF source",
                kind.as_str()
            )));
        };
        extract_string_values(vect.root())
    }

    fn read_channel(
        &self,
        kind: GwfContainerKind,
        channel_name: &str,
        start_sec: f64,
        len_sec: f64,
    ) -> BackendResult<FrVectHandle> {
        let name = CString::new(channel_name).map_err(|_| {
            BackendError::invalid_query(format!(
                "channel name `{channel_name}` contains an interior NUL byte"
            ))
        })?;
        let len_sec = len_sec.max(PREVIEW_WINDOW_MIN_SEC);
        let raw = unsafe {
            match kind {
                GwfContainerKind::Adc => FrFileIGetVAdc(
                    self.raw,
                    name.as_ptr(),
                    start_sec,
                    len_sec,
                    GROUP_NO_DECIMATION,
                ),
                GwfContainerKind::Proc => FrFileIGetVProc(
                    self.raw,
                    name.as_ptr(),
                    start_sec,
                    len_sec,
                    GROUP_NO_DECIMATION,
                ),
                GwfContainerKind::Sim => FrFileIGetVSim(
                    self.raw,
                    name.as_ptr(),
                    start_sec,
                    len_sec,
                    GROUP_NO_DECIMATION,
                ),
                GwfContainerKind::Ser => std::ptr::null_mut(),
            }
        };
        FrVectHandle::from_raw(raw).ok_or_else(|| match kind {
            GwfContainerKind::Ser => BackendError::unsupported(format!(
                "FrSerData channel `{channel_name}` requires a dedicated reader path"
            )),
            _ => BackendError::not_found(format!(
                "channel `{channel_name}` is not readable as {} data in the requested time window",
                kind.as_str()
            )),
        })
    }
}

impl Drop for FrameFileHandle {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { FrFileIEnd(self.raw) };
        }
    }
}

struct FrVectHandle {
    raw: *mut FrVect,
}

impl FrVectHandle {
    fn from_raw(raw: *mut FrVect) -> Option<Self> {
        if raw.is_null() {
            None
        } else {
            Some(Self { raw })
        }
    }

    fn root(&self) -> &FrVect {
        unsafe { &*self.raw }
    }
}

impl Drop for FrVectHandle {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { FrVectFree(self.raw) };
        }
    }
}

struct VectorInterpretation {
    temporal_mode: GwfTemporalMode,
    stream_kind: StreamKind,
    sample_shape: Vec<usize>,
    sample_axes: Vec<SampleAxis>,
    element_type: String,
    unit: Option<String>,
    sample_rate_hz: Option<f64>,
    axis: TimeAxis,
    values: Vec<f64>,
}

impl VectorInterpretation {
    fn into_block(self, channel: ChannelDescriptor) -> DataBlock {
        let metadata = BTreeMap::from([
            (
                "gwf.temporal_mode".to_string(),
                self.temporal_mode.as_str().to_string(),
            ),
            ("gwf.element_type".to_string(), self.element_type.clone()),
        ]);

        match self.stream_kind {
            StreamKind::Series1D => DataBlock::Series1D(Series1D {
                channel,
                axis: self.axis,
                values: self.values,
                metadata,
            }),
            _ => DataBlock::Sampled(SampledData {
                channel,
                axis: self.axis,
                sample_shape: self.sample_shape,
                sample_axes: self.sample_axes,
                values: self.values,
                metadata,
            }),
        }
    }
}

fn fast_catalog_entry(
    series_class: GwfSeriesClass,
    kind: GwfContainerKind,
    channel_name: &str,
) -> GwfChannelEntry {
    let reason = if kind == GwfContainerKind::Ser {
        Some("FrSerData direct reads are not implemented yet".to_string())
    } else {
        None
    };
    metadata_only_entry(series_class, kind, channel_name, reason)
}

fn metadata_only_entry(
    series_class: GwfSeriesClass,
    kind: GwfContainerKind,
    channel_name: &str,
    reason: Option<String>,
) -> GwfChannelEntry {
    let mut channel = base_channel(kind, channel_name);
    channel
        .metadata
        .insert("gwf.read_support".to_string(), "metadata_only".to_string());
    let mut entry = GwfChannelEntry::scalar_series(
        channel,
        series_class,
        kind,
        GwfTemporalMode::FrameSequence,
        None,
    )
    .with_tag("metadata-only")
    .with_extra("gwf.channel_name", channel_name)
    .with_extra("gwf.read_support", "metadata_only")
    .with_element_type("unknown");
    if let Some(reason) = reason {
        entry = entry.with_extra("gwf.inspect_error", reason);
    }
    entry
}

fn entry_from_vector(
    series_class: GwfSeriesClass,
    kind: GwfContainerKind,
    channel_name: &str,
    root: &FrVect,
    request_len_sec: f64,
) -> BackendResult<GwfChannelEntry> {
    let interpretation = interpret_vector(root, request_len_sec)?;
    let mut channel = base_channel(kind, channel_name);
    channel.unit = interpretation.unit.clone();
    channel.sample_rate_hz = interpretation.sample_rate_hz;
    channel.metadata.insert(
        "gwf.temporal_mode".to_string(),
        interpretation.temporal_mode.as_str().to_string(),
    );
    channel.metadata.insert(
        "gwf.element_type".to_string(),
        interpretation.element_type.clone(),
    );

    let mut entry = match interpretation.stream_kind {
        StreamKind::Series1D => GwfChannelEntry::scalar_series(
            channel,
            series_class,
            kind,
            interpretation.temporal_mode,
            None,
        ),
        _ => GwfChannelEntry::sampled(
            channel,
            series_class,
            kind,
            interpretation.temporal_mode,
            interpretation.sample_shape.clone(),
            interpretation.sample_axes.clone(),
            None,
        ),
    }
    .with_tag("native")
    .with_tag(interpretation.temporal_mode.as_str())
    .with_extra("gwf.channel_name", channel_name)
    .with_extra("gwf.read_support", "native")
    .with_preview_time_axis(&interpretation.axis)
    .with_element_type(interpretation.element_type.clone());

    if !interpretation.sample_shape.is_empty() {
        entry = entry.with_extra(
            "gwf.sample_rank",
            interpretation.sample_shape.len().to_string(),
        );
    }
    Ok(entry)
}

fn base_channel(kind: GwfContainerKind, channel_name: &str) -> ChannelDescriptor {
    let mut channel = ChannelDescriptor::new(channel_id(kind, channel_name), channel_name);
    channel
        .metadata
        .insert("gwf.channel_name".to_string(), channel_name.to_string());
    channel
        .metadata
        .insert("gwf.container_kind".to_string(), kind.as_str().to_string());
    channel
}

fn channel_id(kind: GwfContainerKind, channel_name: &str) -> String {
    format!("{}/{}", kind.as_str(), channel_name)
}

fn parse_channel_id(channel_id: &str) -> BackendResult<(GwfContainerKind, &str)> {
    let (kind, channel_name) = channel_id.split_once('/').ok_or_else(|| {
        BackendError::invalid_query(format!(
            "channel `{channel_id}` is missing the expected `container/name` prefix"
        ))
    })?;
    let container_kind = match kind {
        "adc" => GwfContainerKind::Adc,
        "proc" => GwfContainerKind::Proc,
        "sim" => GwfContainerKind::Sim,
        "ser" => GwfContainerKind::Ser,
        _ => {
            return Err(BackendError::invalid_query(format!(
                "channel `{channel_id}` uses unsupported GWF container `{kind}`"
            )))
        }
    };
    if channel_name.is_empty() {
        return Err(BackendError::invalid_query(format!(
            "channel `{channel_id}` is missing the concrete GWF channel name"
        )));
    }
    Ok((container_kind, channel_name))
}

fn interpret_vector(root: &FrVect, request_len_sec: f64) -> BackendResult<VectorInterpretation> {
    let mut nodes = collect_main_nodes(root as *const FrVect);
    if nodes.is_empty() {
        return Err(BackendError::unsupported(
            "Frame reader returned only auxiliary vectors; no main payload is available",
        ));
    }

    nodes.sort_by(|left, right| unsafe {
        (&**left)
            .g_time
            .partial_cmp(&(&**right).g_time)
            .unwrap_or(Ordering::Equal)
    });

    let first = unsafe { &*nodes[0] };
    let temporal_mode = infer_temporal_mode(&nodes, request_len_sec)?;
    let element_type = element_type_name(first.type_code)?.to_string();

    match temporal_mode {
        GwfTemporalMode::VectorAxis0 => interpret_vector_axis0(first, &element_type),
        GwfTemporalMode::FrameSequence => interpret_frame_sequence(&nodes, &element_type),
    }
}

fn interpret_vector_axis0(
    node: &FrVect,
    element_type: &str,
) -> BackendResult<VectorInterpretation> {
    if node.n_dim == 0 {
        return Err(BackendError::unsupported(
            "vector-axis GWF payload has zero dimensions",
        ));
    }

    let time_len = dim_len(node, 0);
    let sample_shape = dims(node).into_iter().skip(1).collect::<Vec<_>>();
    let sample_axes = payload_axes(node, 1);
    let values = numeric_values(node)?;
    let expected_len = time_len.saturating_mul(sample_len(&sample_shape));
    if values.len() != expected_len {
        return Err(BackendError::internal(format!(
            "vector-axis payload length mismatch: expected {expected_len} values, got {}",
            values.len()
        )));
    }

    let dt_sec = dim_spacing(node, 0).ok_or_else(|| {
        BackendError::unsupported("vector-axis payload does not expose a valid time spacing")
    })?;
    let axis = TimeAxis::Regular {
        start_ns: seconds_to_ns(node.g_time + dim_origin(node, 0).unwrap_or(0.0)),
        sample_period_ns: seconds_to_step_ns(dt_sec),
        len: time_len,
    };

    Ok(VectorInterpretation {
        temporal_mode: GwfTemporalMode::VectorAxis0,
        stream_kind: if sample_shape.is_empty() {
            StreamKind::Series1D
        } else {
            StreamKind::Sampled
        },
        sample_shape,
        sample_axes,
        element_type: element_type.to_string(),
        unit: string_from_ptr(node.unit_y),
        sample_rate_hz: sample_rate_from_regular_axis(&axis),
        axis,
        values,
    })
}

fn interpret_frame_sequence(
    nodes: &[*const FrVect],
    element_type: &str,
) -> BackendResult<VectorInterpretation> {
    let first = unsafe { &*nodes[0] };
    let sample_shape = payload_shape_for_frame_sequence(first);
    let sample_axes = payload_axes_for_frame_sequence(first, &sample_shape);
    let expected_sample_len = sample_len(&sample_shape);
    let mut timestamps_ns = Vec::with_capacity(nodes.len());
    let mut values = Vec::with_capacity(nodes.len().saturating_mul(expected_sample_len));

    for node_ptr in nodes {
        let node = unsafe { &**node_ptr };
        let node_shape = payload_shape_for_frame_sequence(node);
        if node_shape != sample_shape {
            return Err(BackendError::unsupported(
                "frame-sequence payload shape changes within the requested window",
            ));
        }
        if node.type_code != first.type_code {
            return Err(BackendError::unsupported(
                "frame-sequence payload type changes within the requested window",
            ));
        }
        timestamps_ns.push(seconds_to_ns(node.g_time));
        let node_values = numeric_values(node)?;
        if node_values.len() != expected_sample_len {
            return Err(BackendError::internal(format!(
                "frame-sequence payload length mismatch: expected {expected_sample_len} values, got {}",
                node_values.len()
            )));
        }
        values.extend(node_values);
    }

    let axis = regular_or_irregular_axis(&timestamps_ns);
    Ok(VectorInterpretation {
        temporal_mode: GwfTemporalMode::FrameSequence,
        stream_kind: if sample_shape.is_empty() {
            StreamKind::Series1D
        } else {
            StreamKind::Sampled
        },
        sample_shape,
        sample_axes,
        element_type: element_type.to_string(),
        unit: string_from_ptr(first.unit_y),
        sample_rate_hz: sample_rate_from_regular_axis(&axis),
        axis,
        values,
    })
}

fn collect_main_nodes(mut current: *const FrVect) -> Vec<*const FrVect> {
    let mut nodes = Vec::new();
    while !current.is_null() {
        let node = unsafe { &*current };
        if !is_auxiliary_vector(node) {
            nodes.push(current);
        }
        current = node.next;
    }
    nodes
}

fn infer_temporal_mode(
    nodes: &[*const FrVect],
    request_len_sec: f64,
) -> BackendResult<GwfTemporalMode> {
    if nodes.is_empty() {
        return Err(BackendError::internal(
            "cannot infer temporal mode from an empty node list",
        ));
    }
    if nodes.len() > 1 {
        return Ok(GwfTemporalMode::FrameSequence);
    }

    let node = unsafe { &*nodes[0] };
    if axis0_looks_like_time(node, request_len_sec) {
        Ok(GwfTemporalMode::VectorAxis0)
    } else {
        Ok(GwfTemporalMode::FrameSequence)
    }
}

fn axis0_looks_like_time(node: &FrVect, request_len_sec: f64) -> bool {
    if node.n_dim == 0 {
        return false;
    }

    if let Some(unit) = string_from_ptr_at(node.unit_x, 0) {
        let unit = unit.trim().to_ascii_lowercase();
        if matches!(
            unit.as_str(),
            "s" | "sec" | "secs" | "second" | "seconds" | "ms" | "us" | "ns"
        ) {
            return true;
        }
    }

    let Some(spacing) = dim_spacing(node, 0) else {
        return false;
    };
    if spacing <= 0.0 {
        return false;
    }

    let coverage = spacing * dim_len(node, 0) as f64;
    if request_len_sec <= 0.0 {
        return coverage > 0.0;
    }
    let ratio = coverage / request_len_sec.max(PREVIEW_WINDOW_MIN_SEC);
    (0.05..=20.0).contains(&ratio)
}

fn payload_shape_for_frame_sequence(node: &FrVect) -> Vec<usize> {
    let dims = dims(node);
    if dims.len() == 1 && dims[0] == 1 {
        Vec::new()
    } else {
        dims
    }
}

fn payload_axes_for_frame_sequence(node: &FrVect, sample_shape: &[usize]) -> Vec<SampleAxis> {
    if sample_shape.is_empty() {
        Vec::new()
    } else {
        payload_axes(node, 0)
    }
}

fn payload_axes(node: &FrVect, start_dim: usize) -> Vec<SampleAxis> {
    (start_dim..node.n_dim as usize)
        .map(|dim_index| SampleAxis {
            label: format!("axis{}", dim_index - start_dim),
            unit: string_from_ptr_at(node.unit_x, dim_index),
            len: dim_len(node, dim_index),
            origin: dim_origin(node, dim_index),
            spacing: dim_spacing(node, dim_index),
        })
        .collect()
}

fn dims(node: &FrVect) -> Vec<usize> {
    (0..node.n_dim as usize)
        .map(|index| dim_len(node, index))
        .collect()
}

fn dim_len(node: &FrVect, index: usize) -> usize {
    unsafe { *node.nx.add(index) as usize }
}

fn dim_spacing(node: &FrVect, index: usize) -> Option<f64> {
    let value = unsafe { *node.dx.add(index) };
    if value.is_finite() && value > 0.0 {
        Some(value)
    } else {
        None
    }
}

fn dim_origin(node: &FrVect, index: usize) -> Option<f64> {
    let value = unsafe { *node.start_x.add(index) };
    if value.is_finite() {
        Some(value)
    } else {
        None
    }
}

fn sample_len(sample_shape: &[usize]) -> usize {
    if sample_shape.is_empty() {
        1
    } else {
        sample_shape
            .iter()
            .copied()
            .fold(1usize, usize::saturating_mul)
    }
}

fn numeric_values(node: &FrVect) -> BackendResult<Vec<f64>> {
    let len = node.n_data as usize;
    let values = match node.type_code {
        FR_VECT_C => (0..len)
            .map(|index| unsafe { *node.data.add(index) as f64 })
            .collect(),
        FR_VECT_2S => (0..len)
            .map(|index| unsafe { *node.data_s.add(index) as f64 })
            .collect(),
        FR_VECT_8R => (0..len)
            .map(|index| unsafe { *node.data_d.add(index) })
            .collect(),
        FR_VECT_4R => (0..len)
            .map(|index| unsafe { *node.data_f.add(index) as f64 })
            .collect(),
        FR_VECT_4S => (0..len)
            .map(|index| unsafe { *node.data_i.add(index) as f64 })
            .collect(),
        FR_VECT_8S => (0..len)
            .map(|index| unsafe { *node.data_l.add(index) as f64 })
            .collect(),
        FR_VECT_2U => (0..len)
            .map(|index| unsafe { *node.data_us.add(index) as f64 })
            .collect(),
        FR_VECT_4U => (0..len)
            .map(|index| unsafe { *node.data_ui.add(index) as f64 })
            .collect(),
        FR_VECT_8U => (0..len)
            .map(|index| unsafe { *node.data_ul.add(index) as f64 })
            .collect(),
        FR_VECT_1U => (0..len)
            .map(|index| unsafe { *node.data_u.add(index) as f64 })
            .collect(),
        FR_VECT_STRING | FR_VECT_8C | FR_VECT_16C | FR_VECT_8H | FR_VECT_16H => {
            return Err(BackendError::unsupported(format!(
                "Frame vector type `{}` is not supported for numeric DATADISPLAY reads",
                element_type_name(node.type_code).unwrap_or("unknown")
            )))
        }
        _ => {
            return Err(BackendError::unsupported(format!(
                "Frame vector type code `{}` is unknown to the native reader",
                node.type_code
            )))
        }
    };
    Ok(values)
}

fn extract_string_values(node: &FrVect) -> BackendResult<Vec<String>> {
    if node.type_code != FR_VECT_STRING {
        return Err(BackendError::internal(
            "Frame name vector did not use the FR_VECT_STRING payload type",
        ));
    }
    let len = node.n_data as usize;
    Ok((0..len)
        .filter_map(|index| string_from_ptr(unsafe { *node.data_q.add(index) }))
        .collect())
}

fn first_scalar_value(node: &FrVect) -> Option<f64> {
    numeric_values(node)
        .ok()
        .and_then(|values| values.into_iter().next())
}

fn regular_or_irregular_axis(timestamps_ns: &[i64]) -> TimeAxis {
    if timestamps_ns.len() < 2 {
        return TimeAxis::Irregular {
            timestamps_ns: timestamps_ns.to_vec(),
        };
    }

    let first_step = timestamps_ns[1].saturating_sub(timestamps_ns[0]);
    if first_step <= 0 {
        return TimeAxis::Irregular {
            timestamps_ns: timestamps_ns.to_vec(),
        };
    }

    let is_regular = timestamps_ns
        .windows(2)
        .all(|pair| (pair[1].saturating_sub(pair[0]) - first_step).abs() <= 2);
    if is_regular {
        TimeAxis::Regular {
            start_ns: timestamps_ns[0],
            sample_period_ns: first_step,
            len: timestamps_ns.len(),
        }
    } else {
        TimeAxis::Irregular {
            timestamps_ns: timestamps_ns.to_vec(),
        }
    }
}

fn sample_rate_from_regular_axis(axis: &TimeAxis) -> Option<f64> {
    match axis {
        TimeAxis::Regular {
            sample_period_ns, ..
        } if *sample_period_ns > 0 => Some(1.0e9 / *sample_period_ns as f64),
        _ => None,
    }
}

fn seconds_to_ns(value_sec: f64) -> i64 {
    (value_sec * 1.0e9).round() as i64
}

fn seconds_to_step_ns(value_sec: f64) -> i64 {
    let step_ns = (value_sec * 1.0e9).round() as i64;
    step_ns.max(1)
}

fn element_type_name(type_code: c_ushort) -> BackendResult<&'static str> {
    match type_code {
        FR_VECT_C => Ok("i8"),
        FR_VECT_2S => Ok("i16"),
        FR_VECT_8R => Ok("f64"),
        FR_VECT_4R => Ok("f32"),
        FR_VECT_4S => Ok("i32"),
        FR_VECT_8S => Ok("i64"),
        FR_VECT_2U => Ok("u16"),
        FR_VECT_4U => Ok("u32"),
        FR_VECT_8U => Ok("u64"),
        FR_VECT_1U => Ok("u8"),
        FR_VECT_STRING => Ok("string"),
        FR_VECT_8C => Ok("complex64"),
        FR_VECT_16C => Ok("complex128"),
        FR_VECT_8H => Ok("halfcomplex64"),
        FR_VECT_16H => Ok("halfcomplex128"),
        _ => Err(BackendError::unsupported(format!(
            "unsupported Frame vector type code `{type_code}`"
        ))),
    }
}

fn is_auxiliary_vector(node: &FrVect) -> bool {
    string_from_ptr(node.name)
        .map(|name| name.starts_with("Available_data"))
        .unwrap_or(false)
}

fn string_from_ptr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        Some(
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }
}

fn string_from_ptr_at(ptr: *mut *mut c_char, index: usize) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        string_from_ptr(unsafe { *ptr.add(index) })
    }
}
