//! GWF adapter scaffolding and native reader boundary.
//!
//! This crate models the neutral contract needed for a real GWF backend:
//! - series-tier selection (`trend`, `50hz`, `raw`)
//! - Frame container provenance (`adc`, `proc`, `sim`, `ser`)
//! - explicit separation between the time axis and the per-sample payload shape
//! - a low-level `FrameReader` abstraction for local/native readers
//! - registered manifests for tests and future service-backed adapters

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, RwLock};

use dd_backend::{
    BackendError, BackendResult, CatalogPage, CatalogQuery, DataSource, DataSourceFactory,
    ReadQuery, SourceCapabilities, SourceTarget, StreamDescriptor, StreamKind,
};
use dd_domain::{ChannelDescriptor, DataBlock, SampleAxis, TimeAxis, TimeRange};

#[cfg(has_native_framel)]
mod native;
#[cfg(has_native_framel)]
use native::NativeFrameReader;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum GwfSeriesClass {
    Trend,
    Hz50,
    #[default]
    Raw,
}

impl GwfSeriesClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trend => "trend",
            Self::Hz50 => "50hz",
            Self::Raw => "raw",
        }
    }

    fn from_query_value(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "trend" | "1hz" => Some(Self::Trend),
            "50hz" | "hz50" => Some(Self::Hz50),
            "raw" => Some(Self::Raw),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GwfContainerKind {
    Adc,
    Proc,
    Sim,
    Ser,
}

impl GwfContainerKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Adc => "adc",
            Self::Proc => "proc",
            Self::Sim => "sim",
            Self::Ser => "ser",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GwfTemporalMode {
    VectorAxis0,
    FrameSequence,
}

impl GwfTemporalMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::VectorAxis0 => "vector_axis0",
            Self::FrameSequence => "frame_sequence",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GwfChannelEntry {
    pub channel: ChannelDescriptor,
    pub series_class: GwfSeriesClass,
    pub container_kind: GwfContainerKind,
    pub temporal_mode: GwfTemporalMode,
    pub stream_kind: StreamKind,
    pub sample_shape: Vec<usize>,
    pub sample_axes: Vec<SampleAxis>,
    pub element_type: String,
    pub tags: Vec<String>,
    pub extra: BTreeMap<String, String>,
    pub block: Option<DataBlock>,
}

impl GwfChannelEntry {
    pub fn scalar_series(
        channel: ChannelDescriptor,
        series_class: GwfSeriesClass,
        container_kind: GwfContainerKind,
        temporal_mode: GwfTemporalMode,
        block: Option<DataBlock>,
    ) -> Self {
        Self {
            channel,
            series_class,
            container_kind,
            temporal_mode,
            stream_kind: StreamKind::Series1D,
            sample_shape: Vec::new(),
            sample_axes: Vec::new(),
            element_type: "f64".to_string(),
            tags: Vec::new(),
            extra: BTreeMap::new(),
            block,
        }
    }

    pub fn sampled(
        channel: ChannelDescriptor,
        series_class: GwfSeriesClass,
        container_kind: GwfContainerKind,
        temporal_mode: GwfTemporalMode,
        sample_shape: Vec<usize>,
        sample_axes: Vec<SampleAxis>,
        block: Option<DataBlock>,
    ) -> Self {
        Self {
            channel,
            series_class,
            container_kind,
            temporal_mode,
            stream_kind: StreamKind::Sampled,
            sample_shape,
            sample_axes,
            element_type: "f64".to_string(),
            tags: Vec::new(),
            extra: BTreeMap::new(),
            block,
        }
    }

    pub fn with_tag(mut self, tag: impl Into<String>) -> Self {
        self.tags.push(tag.into());
        self
    }

    pub fn with_element_type(mut self, element_type: impl Into<String>) -> Self {
        self.element_type = element_type.into();
        self
    }

    pub fn with_extra(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.extra.insert(key.into(), value.into());
        self
    }

    pub fn with_preview_time_axis(mut self, axis: &TimeAxis) -> Self {
        match axis {
            TimeAxis::Regular {
                start_ns,
                sample_period_ns,
                len,
            } => {
                self.extra
                    .insert("preview.start_ns".to_string(), start_ns.to_string());
                self.extra
                    .insert("preview.len".to_string(), len.to_string());
                if *sample_period_ns > 0 {
                    self.extra.insert(
                        "preview.sample_period_ns".to_string(),
                        sample_period_ns.to_string(),
                    );
                    self.extra.insert(
                        "preview.end_ns".to_string(),
                        start_ns
                            .saturating_add(sample_period_ns.saturating_mul(*len as i64))
                            .to_string(),
                    );
                }
            }
            TimeAxis::Irregular { timestamps_ns } => {
                self.extra
                    .insert("preview.len".to_string(), timestamps_ns.len().to_string());
                if let Some(start_ns) = timestamps_ns.first() {
                    self.extra
                        .insert("preview.start_ns".to_string(), start_ns.to_string());
                }
                if let Some(end_ns) = timestamps_ns.last() {
                    self.extra
                        .insert("preview.end_ns".to_string(), end_ns.to_string());
                }
            }
        }
        self
    }

    pub fn with_preview_time_range(mut self, range: &TimeRange) -> Self {
        self.extra
            .insert("preview.start_ns".to_string(), range.start_ns.to_string());
        self.extra
            .insert("preview.end_ns".to_string(), range.end_ns.to_string());
        self
    }

    fn descriptor(&self, file_path: &str) -> StreamDescriptor {
        let mut extra = self.extra.clone();
        extra.insert("storage.kind".to_string(), "gwf".to_string());
        extra.insert("storage.path".to_string(), file_path.to_string());
        extra.insert(
            "gwf.series_class".to_string(),
            self.series_class.as_str().to_string(),
        );
        extra.insert(
            "gwf.container_kind".to_string(),
            self.container_kind.as_str().to_string(),
        );
        extra.insert(
            "gwf.temporal_mode".to_string(),
            self.temporal_mode.as_str().to_string(),
        );
        extra.insert("gwf.element_type".to_string(), self.element_type.clone());
        for (index, axis) in self.sample_axes.iter().enumerate() {
            extra.insert(format!("gwf.sample_axis.{index}.label"), axis.label.clone());
            extra.insert(format!("gwf.sample_axis.{index}.len"), axis.len.to_string());
            if let Some(unit) = &axis.unit {
                extra.insert(format!("gwf.sample_axis.{index}.unit"), unit.clone());
            }
            if let Some(origin) = axis.origin {
                extra.insert(
                    format!("gwf.sample_axis.{index}.origin"),
                    origin.to_string(),
                );
            }
            if let Some(spacing) = axis.spacing {
                extra.insert(
                    format!("gwf.sample_axis.{index}.spacing"),
                    spacing.to_string(),
                );
            }
        }

        let mut tags = self.tags.clone();
        tags.push(format!("series:{}", self.series_class.as_str()));
        tags.push(format!("container:{}", self.container_kind.as_str()));
        if self.stream_kind == StreamKind::Sampled {
            tags.push("sampled".to_string());
        }

        StreamDescriptor {
            channel: self.channel.clone(),
            kind: self.stream_kind.clone(),
            sample_shape: self.sample_shape.clone(),
            tags,
            extra,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct GwfManifest {
    entries: Vec<GwfChannelEntry>,
}

impl GwfManifest {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_entry(mut self, entry: GwfChannelEntry) -> Self {
        self.add_entry(entry);
        self
    }

    pub fn add_entry(&mut self, entry: GwfChannelEntry) {
        self.entries.push(entry);
    }

    pub fn entries(&self) -> &[GwfChannelEntry] {
        &self.entries
    }

    fn find_channel(
        &self,
        series_class: GwfSeriesClass,
        channel_id: &str,
    ) -> Option<&GwfChannelEntry> {
        self.entries
            .iter()
            .find(|entry| entry.series_class == series_class && entry.channel.id == channel_id)
    }
}

pub trait FrameReader: Send + Sync {
    fn inspect(&self, file_path: &str, series_class: GwfSeriesClass) -> BackendResult<GwfManifest>;
    fn catalog_descriptors(
        &self,
        file_path: &str,
        series_class: GwfSeriesClass,
        query: &CatalogQuery,
    ) -> BackendResult<CatalogPage> {
        let manifest = self.inspect(file_path, series_class)?;
        let mut descriptors = manifest
            .entries()
            .iter()
            .filter(|entry| entry.series_class == series_class)
            .map(|entry| entry.descriptor(file_path))
            .filter(|descriptor| descriptor.matches(query))
            .collect::<Vec<_>>();
        let total_count = descriptors.len();
        if query.offset > 0 {
            descriptors = descriptors.into_iter().skip(query.offset).collect();
        }
        if let Some(limit) = query.limit {
            descriptors.truncate(limit);
        }
        Ok(CatalogPage {
            total_count,
            streams: descriptors,
        })
    }
    fn read(
        &self,
        file_path: &str,
        series_class: GwfSeriesClass,
        query: &ReadQuery,
    ) -> BackendResult<DataBlock>;
}

#[derive(Clone, Debug, Default)]
pub struct UnavailableFrameReader;

impl FrameReader for UnavailableFrameReader {
    fn inspect(&self, file_path: &str, series_class: GwfSeriesClass) -> BackendResult<GwfManifest> {
        Err(BackendError::unsupported(unavailable_frame_reader_message(
            file_path,
            series_class,
        )))
    }

    fn read(
        &self,
        file_path: &str,
        series_class: GwfSeriesClass,
        _query: &ReadQuery,
    ) -> BackendResult<DataBlock> {
        Err(BackendError::unsupported(unavailable_frame_reader_message(
            file_path,
            series_class,
        )))
    }
}

fn unavailable_frame_reader_message(file_path: &str, series_class: GwfSeriesClass) -> String {
    if cfg!(target_os = "windows") {
        format!(
            "local Frame access for `{file_path}` with series `{}` is not implemented on Windows yet",
            series_class.as_str()
        )
    } else {
        format!(
            "local Frame access for `{file_path}` with series `{}` requires a native Frame reader; set DD_FRAMEL_ROOT or place TOMCAT/Fr next to DATADISPLAY",
            series_class.as_str()
        )
    }
}

fn default_frame_reader() -> Arc<dyn FrameReader> {
    #[cfg(has_native_framel)]
    {
        Arc::new(NativeFrameReader::new())
    }

    #[cfg(not(has_native_framel))]
    {
        Arc::new(UnavailableFrameReader)
    }
}

#[derive(Clone)]
pub struct GwfFactory {
    manifests: Arc<RwLock<BTreeMap<String, Arc<GwfManifest>>>>,
    frame_reader: Arc<dyn FrameReader>,
}

impl Default for GwfFactory {
    fn default() -> Self {
        Self {
            manifests: Arc::new(RwLock::new(BTreeMap::new())),
            frame_reader: default_frame_reader(),
        }
    }
}

impl fmt::Debug for GwfFactory {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let manifest_count = self
            .manifests
            .read()
            .map(|manifests| manifests.len())
            .unwrap_or(0);
        f.debug_struct("GwfFactory")
            .field("manifest_count", &manifest_count)
            .finish_non_exhaustive()
    }
}

impl GwfFactory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_frame_reader(mut self, frame_reader: Arc<dyn FrameReader>) -> Self {
        self.frame_reader = frame_reader;
        self
    }

    pub fn register_manifest(
        &self,
        target_uri: impl Into<String>,
        manifest: GwfManifest,
    ) -> BackendResult<()> {
        let mut manifests = self
            .manifests
            .write()
            .map_err(|_| BackendError::internal("GWF manifest registry lock is poisoned"))?;
        manifests.insert(target_uri.into(), Arc::new(manifest));
        Ok(())
    }
}

/// Re-export of `GwfFactory` bound to the `ffl://` scheme. Frame's
/// `FrFileINew` already accepts `.ffl` (Frame File List) paths transparently,
/// so this is purely a discoverability shim: users typing
/// `ffl:///path/to/list.ffl` route through the same Frame reader and series
/// parser as `gwf://`.
#[derive(Default, Clone, Debug)]
pub struct FflFactory {
    inner: GwfFactory,
}

impl FflFactory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_frame_reader(mut self, frame_reader: Arc<dyn FrameReader>) -> Self {
        self.inner = self.inner.with_frame_reader(frame_reader);
        self
    }
}

impl DataSourceFactory for FflFactory {
    fn scheme(&self) -> &str {
        "ffl"
    }

    fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>> {
        // Translate `ffl://` to `gwf://` for the shared parser, then delegate.
        let rewritten = target
            .uri
            .strip_prefix("ffl://")
            .map(|tail| format!("gwf://{tail}"))
            .unwrap_or_else(|| target.uri.clone());
        self.inner.open(&SourceTarget::new(rewritten))
    }
}

impl DataSourceFactory for GwfFactory {
    fn scheme(&self) -> &str {
        "gwf"
    }

    fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>> {
        let parsed_target = GwfTarget::parse(target)?;
        if let Some(manifest) = self
            .manifests
            .read()
            .map_err(|_| BackendError::internal("GWF manifest registry lock is poisoned"))?
            .get(&target.uri)
            .cloned()
        {
            return Ok(Box::new(GwfSource {
                target: target.clone(),
                mode: GwfSourceMode::Registered {
                    parsed_target,
                    manifest,
                },
            }));
        }

        Ok(Box::new(GwfSource {
            target: target.clone(),
            mode: GwfSourceMode::DirectFile {
                parsed_target,
                frame_reader: Arc::clone(&self.frame_reader),
            },
        }))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct GwfTarget {
    file_path: String,
    series_class: GwfSeriesClass,
}

impl GwfTarget {
    fn parse(target: &SourceTarget) -> BackendResult<Self> {
        let location = target
            .location()
            .ok_or_else(|| BackendError::invalid_query("GWF source URI is missing a path"))?;
        if location.is_empty() {
            return Err(BackendError::invalid_query(
                "GWF source URI is missing a path",
            ));
        }

        let (file_path, query) = match location.split_once('?') {
            Some((file_path, query)) => (file_path, query),
            None => (location, ""),
        };
        if file_path.trim().is_empty() {
            return Err(BackendError::invalid_query(
                "GWF source URI is missing a path",
            ));
        }

        let mut series_class = GwfSeriesClass::Raw;
        for pair in query.split('&').filter(|pair| !pair.is_empty()) {
            let (key, value) = match pair.split_once('=') {
                Some(parts) => parts,
                None => (pair, ""),
            };
            if key.eq_ignore_ascii_case("series") {
                series_class = GwfSeriesClass::from_query_value(value).ok_or_else(|| {
                    BackendError::invalid_query(format!(
                        "unsupported GWF series class `{value}`; expected trend, 50hz, or raw"
                    ))
                })?;
            }
        }

        Ok(Self {
            file_path: file_path.to_string(),
            series_class,
        })
    }
}

pub struct GwfSource {
    target: SourceTarget,
    mode: GwfSourceMode,
}

enum GwfSourceMode {
    Registered {
        parsed_target: GwfTarget,
        manifest: Arc<GwfManifest>,
    },
    DirectFile {
        parsed_target: GwfTarget,
        frame_reader: Arc<dyn FrameReader>,
    },
}

impl DataSource for GwfSource {
    fn source_name(&self) -> &str {
        &self.target.uri
    }

    fn capabilities(&self) -> SourceCapabilities {
        SourceCapabilities {
            catalog_search: true,
            live_subscriptions: false,
            volume3d: false,
            metadata_write: false,
            batch_read: true,
        }
    }

    fn catalog(&self, query: &CatalogQuery) -> BackendResult<CatalogPage> {
        match &self.mode {
            GwfSourceMode::Registered {
                parsed_target,
                manifest,
            } => {
                let mut descriptors = manifest
                    .entries()
                    .iter()
                    .filter(|entry| entry.series_class == parsed_target.series_class)
                    .map(|entry| entry.descriptor(&parsed_target.file_path))
                    .filter(|descriptor| descriptor.matches(query))
                    .collect::<Vec<_>>();
                if query.offset > 0 {
                    descriptors = descriptors.into_iter().skip(query.offset).collect();
                }
                let total_count = descriptors.len();
                if let Some(limit) = query.limit {
                    descriptors.truncate(limit);
                }
                Ok(CatalogPage {
                    total_count,
                    streams: descriptors,
                })
            }
            GwfSourceMode::DirectFile {
                parsed_target,
                frame_reader,
            } => frame_reader.catalog_descriptors(
                &parsed_target.file_path,
                parsed_target.series_class,
                query,
            ),
        }
    }

    fn read(&self, query: &ReadQuery) -> BackendResult<DataBlock> {
        query.validate()?;

        match &self.mode {
            GwfSourceMode::Registered {
                parsed_target,
                manifest,
            } => {
                let entry = manifest
                    .find_channel(parsed_target.series_class, &query.channel_id)
                    .ok_or_else(|| {
                        BackendError::not_found(format!(
                            "channel `{}` not found in GWF manifest for series `{}`",
                            query.channel_id,
                            parsed_target.series_class.as_str()
                        ))
                    })?;

                entry.block.clone().ok_or_else(|| {
                    BackendError::unsupported(format!(
                        "registered GWF channel `{}` has catalog metadata only; no read block is attached yet",
                        query.channel_id
                    ))
                })
            }
            GwfSourceMode::DirectFile {
                parsed_target,
                frame_reader,
            } => frame_reader.read(&parsed_target.file_path, parsed_target.series_class, query),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dd_domain::{DataBlock, SampledData, Series1D, TimeAxis};
    use std::path::PathBuf;

    fn scalar_channel(id: &str, display_name: &str) -> ChannelDescriptor {
        let mut channel = ChannelDescriptor::new(id, display_name);
        channel.sample_rate_hz = Some(16_384.0);
        channel.unit = Some("strain".to_string());
        channel
    }

    fn image_channel(id: &str, display_name: &str) -> ChannelDescriptor {
        let mut channel = ChannelDescriptor::new(id, display_name);
        channel.sample_rate_hz = Some(10.0);
        channel.unit = Some("adu".to_string());
        channel
    }

    fn raw_series_block(channel: &ChannelDescriptor) -> DataBlock {
        DataBlock::Series1D(Series1D {
            channel: channel.clone(),
            axis: TimeAxis::Regular {
                start_ns: 1_000_000_000,
                sample_period_ns: 61_035,
                len: 4,
            },
            values: vec![0.1, 0.2, 0.15, 0.05],
            metadata: BTreeMap::from([(
                "gwf.temporal_mode".to_string(),
                "vector_axis0".to_string(),
            )]),
        })
    }

    fn image_sampled_block(channel: &ChannelDescriptor) -> DataBlock {
        DataBlock::Sampled(SampledData {
            channel: channel.clone(),
            axis: TimeAxis::Regular {
                start_ns: 5_000_000_000,
                sample_period_ns: 100_000_000,
                len: 2,
            },
            sample_shape: vec![2, 3],
            sample_axes: vec![
                SampleAxis {
                    label: "x".to_string(),
                    unit: Some("px".to_string()),
                    len: 2,
                    origin: Some(0.0),
                    spacing: Some(1.0),
                },
                SampleAxis {
                    label: "y".to_string(),
                    unit: Some("px".to_string()),
                    len: 3,
                    origin: Some(0.0),
                    spacing: Some(1.0),
                },
            ],
            values: vec![
                1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0,
            ],
            metadata: BTreeMap::from([(
                "gwf.temporal_mode".to_string(),
                "frame_sequence".to_string(),
            )]),
        })
    }

    #[derive(Clone)]
    struct TestFrameReader {
        manifest: GwfManifest,
        block: DataBlock,
    }

    impl FrameReader for TestFrameReader {
        fn inspect(
            &self,
            _file_path: &str,
            _series_class: GwfSeriesClass,
        ) -> BackendResult<GwfManifest> {
            Ok(self.manifest.clone())
        }

        fn read(
            &self,
            _file_path: &str,
            _series_class: GwfSeriesClass,
            _query: &ReadQuery,
        ) -> BackendResult<DataBlock> {
            Ok(self.block.clone())
        }
    }

    #[test]
    fn parse_target_defaults_to_raw_when_series_is_omitted() {
        let target = SourceTarget::new("gwf:///archive/V1_R_1269363400.gwf");
        let parsed = GwfTarget::parse(&target).expect("target should parse");

        assert_eq!(parsed.file_path, "/archive/V1_R_1269363400.gwf");
        assert_eq!(parsed.series_class, GwfSeriesClass::Raw);
    }

    #[test]
    fn catalog_exposes_sample_shape_for_registered_sampled_channels() {
        let factory = GwfFactory::new();
        let image = image_channel("V1:CAMERA_MAIN", "Main camera");
        let manifest = GwfManifest::new().with_entry(
            GwfChannelEntry::sampled(
                image.clone(),
                GwfSeriesClass::Raw,
                GwfContainerKind::Adc,
                GwfTemporalMode::FrameSequence,
                vec![2, 3],
                vec![SampleAxis::new("x", 2), SampleAxis::new("y", 3)],
                Some(image_sampled_block(&image)),
            )
            .with_element_type("u16")
            .with_tag("camera")
            .with_extra("gwf.channel_path", "adc/V1:CAMERA_MAIN"),
        );
        let uri = "gwf:///archive/V1_R_1269363400.gwf?series=raw";
        factory
            .register_manifest(uri, manifest)
            .expect("manifest should register");

        let source = factory
            .open(&SourceTarget::new(uri))
            .expect("source should open");
        let streams = source
            .catalog(&CatalogQuery::default())
            .expect("catalog should succeed");

        assert_eq!(streams.streams.len(), 1);
        assert_eq!(streams.streams[0].kind, StreamKind::Sampled);
        assert_eq!(streams.streams[0].sample_shape, vec![2, 3]);
        assert_eq!(
            streams.streams[0].extra.get("gwf.temporal_mode"),
            Some(&"frame_sequence".to_string())
        );
        assert_eq!(
            streams.streams[0].extra.get("gwf.element_type"),
            Some(&"u16".to_string())
        );
    }

    #[test]
    fn registered_read_returns_sampled_block_without_collapsing_payload_rank() {
        let factory = GwfFactory::new();
        let image = image_channel("V1:CAMERA_MAIN", "Main camera");
        let uri = "gwf:///archive/V1_R_1269363400.gwf?series=raw";
        factory
            .register_manifest(
                uri,
                GwfManifest::new().with_entry(GwfChannelEntry::sampled(
                    image.clone(),
                    GwfSeriesClass::Raw,
                    GwfContainerKind::Adc,
                    GwfTemporalMode::FrameSequence,
                    vec![2, 3],
                    vec![SampleAxis::new("x", 2), SampleAxis::new("y", 3)],
                    Some(image_sampled_block(&image)),
                )),
            )
            .expect("manifest should register");

        let source = factory
            .open(&SourceTarget::new(uri))
            .expect("source should open");
        let block = source
            .read(&ReadQuery {
                channel_id: image.id.clone(),
                time_range: dd_domain::TimeRange::new(5_000_000_000, 5_200_000_000),
                resolution_hint: None,
                aggregation: dd_backend::Aggregation::Raw,
                allow_gaps: false,
            })
            .expect("read should succeed");

        match block {
            DataBlock::Sampled(sampled) => {
                assert_eq!(sampled.sample_shape, vec![2, 3]);
                assert_eq!(sampled.sample_axes.len(), 2);
                assert_eq!(sampled.axis.len(), 2);
            }
            other => panic!("expected sampled block, got {other:?}"),
        }
    }

    #[test]
    fn registered_catalog_keeps_scalar_raw_channels_as_series1d() {
        let factory = GwfFactory::new();
        let strain = scalar_channel("V1:Hrec_16384Hz", "Strain");
        let uri = "gwf:///archive/V1_R_1269363400.gwf?series=raw";
        factory
            .register_manifest(
                uri,
                GwfManifest::new().with_entry(
                    GwfChannelEntry::scalar_series(
                        strain.clone(),
                        GwfSeriesClass::Raw,
                        GwfContainerKind::Adc,
                        GwfTemporalMode::VectorAxis0,
                        Some(raw_series_block(&strain)),
                    )
                    .with_tag("strain"),
                ),
            )
            .expect("manifest should register");

        let source = factory
            .open(&SourceTarget::new(uri))
            .expect("source should open");
        let streams = source
            .catalog(&CatalogQuery::default())
            .expect("catalog should succeed");

        assert_eq!(streams.streams.len(), 1);
        assert_eq!(streams.streams[0].kind, StreamKind::Series1D);
        assert!(streams.streams[0].sample_shape.is_empty());
    }

    #[test]
    fn direct_file_mode_uses_frame_reader_boundary() {
        let strain = scalar_channel("adc/V1:Hrec_16384Hz", "V1:Hrec_16384Hz");
        let block = raw_series_block(&strain);
        let manifest = GwfManifest::new().with_entry(
            GwfChannelEntry::scalar_series(
                strain.clone(),
                GwfSeriesClass::Raw,
                GwfContainerKind::Adc,
                GwfTemporalMode::VectorAxis0,
                None,
            )
            .with_extra("gwf.channel_name", "V1:Hrec_16384Hz"),
        );
        let factory = GwfFactory::new().with_frame_reader(Arc::new(TestFrameReader {
            manifest,
            block: block.clone(),
        }));

        let source = factory
            .open(&SourceTarget::new("gwf:///tmp/test.gwf?series=raw"))
            .expect("source should open");
        let streams = source
            .catalog(&CatalogQuery::default())
            .expect("catalog should come from frame reader");
        assert_eq!(streams.streams.len(), 1);
        assert_eq!(streams.streams[0].channel.id, "adc/V1:Hrec_16384Hz");

        let read_back = source
            .read(&ReadQuery {
                channel_id: "adc/V1:Hrec_16384Hz".to_string(),
                time_range: dd_domain::TimeRange::new(1_000_000_000, 1_000_250_000),
                resolution_hint: None,
                aggregation: dd_backend::Aggregation::Raw,
                allow_gaps: false,
            })
            .expect("read should come from frame reader");
        assert_eq!(read_back, block);
    }

    #[test]
    fn descriptor_exports_preview_metadata_for_regular_axes() {
        let strain = scalar_channel("V1:Hrec_16384Hz", "Strain");
        let descriptor = GwfChannelEntry::scalar_series(
            strain,
            GwfSeriesClass::Raw,
            GwfContainerKind::Adc,
            GwfTemporalMode::VectorAxis0,
            None,
        )
        .with_preview_time_axis(&TimeAxis::Regular {
            start_ns: 1_000_000_000,
            sample_period_ns: 61_035,
            len: 4,
        })
        .descriptor("/tmp/test.gwf");

        assert_eq!(
            descriptor.extra.get("preview.start_ns"),
            Some(&"1000000000".to_string())
        );
        assert_eq!(
            descriptor.extra.get("preview.sample_period_ns"),
            Some(&"61035".to_string())
        );
        assert_eq!(descriptor.extra.get("preview.len"), Some(&"4".to_string()));
        assert_eq!(
            descriptor.extra.get("preview.end_ns"),
            Some(&(1_000_000_000_i64 + 61_035_i64 * 4).to_string())
        );
    }

    #[test]
    fn real_gwf_fixture_catalogs_and_reads_when_available() {
        let fixture =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../data/V-raw-1446446000-100.gwf");
        if !fixture.is_file() {
            return;
        }

        let fixture = fixture
            .canonicalize()
            .expect("fixture path should canonicalize");
        let uri = format!("gwf://{}?series=raw", fixture.display());
        let factory = GwfFactory::new();
        let source = factory
            .open(&SourceTarget::new(uri))
            .expect("real GWF source should open");

        let streams = source
            .catalog(&CatalogQuery::default())
            .expect("real GWF catalog should succeed");
        assert!(
            !streams.streams.is_empty(),
            "real GWF catalog should not be empty"
        );

        let target = streams
            .streams
            .iter()
            .find(|stream| stream.channel.id == "proc/V1:Hrec_hoft_16384Hz")
            .expect("expected strain-like proc channel in the real GWF fixture");
        assert_eq!(target.kind, StreamKind::Series1D);
        assert_eq!(
            target.extra.get("gwf.read_support"),
            Some(&"native".to_string())
        );
        assert!(
            target.extra.contains_key("preview.start_ns"),
            "real GWF catalog should expose preview start metadata"
        );
        assert!(
            target.extra.contains_key("preview.sample_period_ns"),
            "real GWF catalog should expose preview sample spacing"
        );

        let block = source
            .read(&ReadQuery {
                channel_id: target.channel.id.clone(),
                time_range: dd_domain::TimeRange::new(
                    1_446_446_000_000_000_000,
                    1_446_446_001_000_000_000,
                ),
                resolution_hint: Some(dd_backend::ResolutionHint { max_points: 2048 }),
                aggregation: dd_backend::Aggregation::Raw,
                allow_gaps: false,
            })
            .expect("real GWF read should succeed");

        match block {
            DataBlock::Series1D(series) => {
                assert_eq!(series.channel.id, "proc/V1:Hrec_hoft_16384Hz");
                assert_eq!(series.axis.len(), series.values.len());
                assert!(series.values.len() >= 16_000);
                assert_eq!(
                    series.metadata.get("gwf.temporal_mode"),
                    Some(&"vector_axis0".to_string())
                );
            }
            other => panic!("expected series block from real GWF fixture, got {other:?}"),
        }
    }
}
