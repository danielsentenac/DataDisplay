//! Generic HDF5 adapter.
//!
//! This keeps the application contract format-neutral while allowing HDF5
//! datasets to be surfaced as neutral `Series1D`, `Grid2D`, and `Volume3D`
//! blocks. The adapter supports both registered in-memory layouts for tests and
//! real file-backed discovery for actual `.h5` files.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use dd_backend::{
    Aggregation, BackendError, BackendResult, CatalogPage, CatalogQuery, DataSource,
    DataSourceFactory, ReadQuery, ResolutionHint, SourceCapabilities, SourceTarget,
    StreamDescriptor, StreamKind,
};
use dd_domain::{
    ChannelDescriptor, DataBlock, EventSeries, Grid2D, Metadata, Series1D, TimeAxis, TimeRange,
    Volume3D,
};
use dd_processing::{downsample_mean, moving_rms, spectrogram};
use hdf5_reader::group::Group;
use hdf5_reader::{Attribute, Dataset, Datatype, H5Type, Hdf5File};

#[derive(Clone, Debug, Default)]
pub struct Hdf5Layout {
    datasets: Vec<Hdf5Dataset>,
}

impl Hdf5Layout {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn datasets(&self) -> &[Hdf5Dataset] {
        &self.datasets
    }

    pub fn add_dataset(&mut self, dataset: Hdf5Dataset) {
        self.datasets.push(dataset);
    }

    pub fn with_dataset(mut self, dataset: Hdf5Dataset) -> Self {
        self.add_dataset(dataset);
        self
    }

    fn find_dataset(&self, channel_id: &str) -> Option<&Hdf5Dataset> {
        self.datasets
            .iter()
            .find(|dataset| dataset.block.channel().id == channel_id)
    }
}

#[derive(Clone, Debug)]
pub struct Hdf5Dataset {
    pub path: String,
    pub block: DataBlock,
    pub tags: Vec<String>,
    pub extra: BTreeMap<String, String>,
}

impl Hdf5Dataset {
    pub fn series(path: impl Into<String>, series: Series1D, tags: impl Into<Vec<String>>) -> Self {
        Self {
            path: path.into(),
            block: DataBlock::Series1D(series),
            tags: tags.into(),
            extra: BTreeMap::new(),
        }
    }

    pub fn grid2d(path: impl Into<String>, grid: Grid2D, tags: impl Into<Vec<String>>) -> Self {
        Self {
            path: path.into(),
            block: DataBlock::Grid2D(grid),
            tags: tags.into(),
            extra: BTreeMap::new(),
        }
    }

    pub fn volume3d(
        path: impl Into<String>,
        volume: Volume3D,
        tags: impl Into<Vec<String>>,
    ) -> Self {
        Self {
            path: path.into(),
            block: DataBlock::Volume3D(volume),
            tags: tags.into(),
            extra: BTreeMap::new(),
        }
    }

    pub fn event_series(
        path: impl Into<String>,
        events: EventSeries,
        tags: impl Into<Vec<String>>,
    ) -> Self {
        Self {
            path: path.into(),
            block: DataBlock::EventSeries(events),
            tags: tags.into(),
            extra: BTreeMap::new(),
        }
    }

    pub fn with_extra(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.extra.insert(key.into(), value.into());
        self
    }

    fn descriptor(&self) -> StreamDescriptor {
        let mut extra = self.extra.clone();
        extra.insert("storage.kind".to_string(), "hdf5".to_string());
        extra.insert("storage.path".to_string(), self.path.clone());

        StreamDescriptor {
            channel: self.block.channel().clone(),
            kind: stream_kind(&self.block),
            sample_shape: block_sample_shape(&self.block),
            tags: self.tags.clone(),
            extra,
        }
    }
}

#[derive(Clone, Default)]
pub struct Hdf5Factory {
    layouts: Arc<RwLock<BTreeMap<String, Arc<Hdf5Layout>>>>,
}

impl Hdf5Factory {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register_layout(
        &self,
        target_uri: impl Into<String>,
        layout: Hdf5Layout,
    ) -> BackendResult<()> {
        let mut layouts = self
            .layouts
            .write()
            .map_err(|_| BackendError::internal("HDF5 layout registry lock is poisoned"))?;
        layouts.insert(target_uri.into(), Arc::new(layout));
        Ok(())
    }
}

impl DataSourceFactory for Hdf5Factory {
    fn scheme(&self) -> &str {
        "hdf5"
    }

    fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>> {
        if let Some(layout) = self
            .layouts
            .read()
            .map_err(|_| BackendError::internal("HDF5 layout registry lock is poisoned"))?
            .get(&target.uri)
            .cloned()
        {
            return Ok(Box::new(Hdf5Source {
                target: target.clone(),
                mode: Hdf5SourceMode::Registered(layout),
            }));
        }

        let file_path = path_from_target(target)?;
        let catalog = discover_file_catalog(&file_path)?;

        Ok(Box::new(Hdf5Source {
            target: target.clone(),
            mode: Hdf5SourceMode::File(Hdf5FileSource { file_path, catalog }),
        }))
    }
}

pub struct Hdf5Source {
    target: SourceTarget,
    mode: Hdf5SourceMode,
}

enum Hdf5SourceMode {
    Registered(Arc<Hdf5Layout>),
    File(Hdf5FileSource),
}

struct Hdf5FileSource {
    file_path: PathBuf,
    catalog: Vec<Hdf5DiscoveredDataset>,
}

#[derive(Clone, Debug)]
struct Hdf5DiscoveredDataset {
    path: String,
    kind: StreamKind,
    channel: ChannelDescriptor,
    tags: Vec<String>,
    extra: BTreeMap<String, String>,
    interpretation: Hdf5Interpretation,
}

impl Hdf5DiscoveredDataset {
    fn descriptor(&self) -> StreamDescriptor {
        let mut extra = self.extra.clone();
        extra.insert("storage.kind".to_string(), "hdf5".to_string());
        extra.insert("storage.path".to_string(), self.path.clone());

        StreamDescriptor {
            channel: self.channel.clone(),
            kind: self.kind.clone(),
            sample_shape: Vec::new(),
            tags: self.tags.clone(),
            extra,
        }
    }
}

#[derive(Clone, Debug)]
enum Hdf5Interpretation {
    Series1D {
        start_ns: i64,
        sample_period_ns: i64,
    },
    Grid2D {
        x_range: TimeRange,
        y_label: String,
        y_unit: Option<String>,
        width: usize,
        height: usize,
    },
    Volume3D {
        x_len: usize,
        y_len: usize,
        z_len: usize,
    },
}

impl DataSource for Hdf5Source {
    fn source_name(&self) -> &str {
        &self.target.uri
    }

    fn capabilities(&self) -> SourceCapabilities {
        SourceCapabilities {
            catalog_search: true,
            live_subscriptions: false,
            volume3d: true,
            metadata_write: false,
            batch_read: true,
        }
    }

    fn catalog(&self, query: &CatalogQuery) -> BackendResult<CatalogPage> {
        let mut descriptors = match &self.mode {
            Hdf5SourceMode::Registered(layout) => layout
                .datasets()
                .iter()
                .map(Hdf5Dataset::descriptor)
                .filter(|descriptor| descriptor.matches(query))
                .collect::<Vec<_>>(),
            Hdf5SourceMode::File(file_source) => file_source
                .catalog
                .iter()
                .map(Hdf5DiscoveredDataset::descriptor)
                .filter(|descriptor| descriptor.matches(query))
                .collect::<Vec<_>>(),
        };

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

    fn read(&self, query: &ReadQuery) -> BackendResult<DataBlock> {
        query.validate()?;

        match &self.mode {
            Hdf5SourceMode::Registered(layout) => {
                let dataset = layout.find_dataset(&query.channel_id).ok_or_else(|| {
                    BackendError::not_found(format!("channel `{}` not found", query.channel_id))
                })?;

                read_registered_dataset(dataset, query)
            }
            Hdf5SourceMode::File(file_source) => {
                let dataset = file_source
                    .catalog
                    .iter()
                    .find(|dataset| dataset.channel.id == query.channel_id)
                    .ok_or_else(|| {
                        BackendError::not_found(format!("channel `{}` not found", query.channel_id))
                    })?;

                read_file_dataset(&file_source.file_path, dataset, query)
            }
        }
    }
}

fn path_from_target(target: &SourceTarget) -> BackendResult<PathBuf> {
    let location = target
        .location()
        .ok_or_else(|| BackendError::invalid_query("HDF5 source URI is missing a path"))?;

    if location.is_empty() {
        return Err(BackendError::invalid_query(
            "HDF5 source URI is missing a path",
        ));
    }

    Ok(PathBuf::from(location))
}

fn discover_file_catalog(path: &Path) -> BackendResult<Vec<Hdf5DiscoveredDataset>> {
    if !path.exists() {
        return Err(BackendError::not_found(format!(
            "HDF5 file `{}` does not exist",
            path.display()
        )));
    }

    let file = reader_result(Hdf5File::open(path), || {
        format!("failed to open HDF5 file `{}`", path.display())
    })?;
    let root = reader_result(file.root_group(), || {
        format!("failed to open root group for `{}`", path.display())
    })?;

    let mut catalog = Vec::new();
    collect_group_datasets(path, &root, "/", &mut catalog)?;
    Ok(catalog)
}

fn collect_group_datasets(
    file_path: &Path,
    group: &Group<'_>,
    group_path: &str,
    catalog: &mut Vec<Hdf5DiscoveredDataset>,
) -> BackendResult<()> {
    for dataset in reader_result(group.datasets(), || {
        format!("failed to list datasets under `{}`", group.name())
    })? {
        let dataset_path = join_hdf5_path(group_path, dataset.name());
        if let Some(entry) = discover_dataset(file_path, &dataset, dataset_path)? {
            catalog.push(entry);
        }
    }

    for subgroup in reader_result(group.groups(), || {
        format!("failed to list groups under `{}`", group.name())
    })? {
        let subgroup_path = join_hdf5_path(group_path, subgroup.name());
        collect_group_datasets(file_path, &subgroup, &subgroup_path, catalog)?;
    }

    Ok(())
}

fn join_hdf5_path(parent: &str, child: &str) -> String {
    if child.starts_with('/') {
        return child.to_string();
    }

    if parent == "/" {
        format!("/{child}")
    } else {
        format!("{}/{}", parent.trim_end_matches('/'), child)
    }
}

fn discover_dataset(
    file_path: &Path,
    dataset: &Dataset<'_>,
    dataset_path: String,
) -> BackendResult<Option<Hdf5DiscoveredDataset>> {
    let shape = dataset
        .shape()
        .iter()
        .copied()
        .map(|dimension| {
            usize::try_from(dimension).map_err(|_| {
                BackendError::internal(format!(
                    "dataset `{}` uses a dimension larger than usize",
                    dataset.name()
                ))
            })
        })
        .collect::<BackendResult<Vec<_>>>()?;

    if shape.is_empty() || shape.len() > 3 {
        return Ok(None);
    }

    if !is_supported_numeric_type(dataset.dtype()) {
        return Ok(None);
    }

    let sample_rate_hz = first_f64_attr(dataset, &["sample_rate_hz", "sample_rate"]);
    let tags = first_string_attr(dataset, &["dd_tags", "tags"])
        .map(parse_tags)
        .unwrap_or_default();
    let metadata = collect_dataset_metadata(file_path, &dataset_path, dataset);

    let channel_id = first_string_attr(dataset, &["dd_channel_id", "channel_id", "id"])
        .unwrap_or_else(|| dataset_path.clone());
    let display_name =
        first_string_attr(dataset, &["dd_display_name", "display_name", "long_name"])
            .unwrap_or_else(|| default_display_name(&dataset_path));
    let unit = first_string_attr(dataset, &["unit", "units"]);

    let channel = ChannelDescriptor {
        id: channel_id,
        display_name,
        unit: unit.clone(),
        sample_rate_hz,
        metadata,
    };

    let mut extra = BTreeMap::new();
    extra.insert("hdf5.shape".to_string(), format_shape(&shape));
    extra.insert("hdf5.dtype".to_string(), format!("{:?}", dataset.dtype()));

    let (kind, interpretation) = match shape.len() {
        1 => {
            let len = shape[0];
            let start_ns = first_i64_attr(dataset, &["start_ns", "epoch_ns", "t0_ns"]).unwrap_or(0);
            let sample_period_ns = first_i64_attr(dataset, &["sample_period_ns", "time_step_ns"])
                .or_else(|| sample_rate_hz.and_then(sample_period_ns_from_rate_hz))
                .unwrap_or(1);

            extra.insert("hdf5.mapping".to_string(), "series1d".to_string());
            extra.insert("hdf5.len".to_string(), len.to_string());

            (
                StreamKind::Series1D,
                Hdf5Interpretation::Series1D {
                    start_ns,
                    sample_period_ns,
                },
            )
        }
        2 => {
            let width = shape[0];
            let height = shape[1];
            let x_start_ns = first_i64_attr(dataset, &["start_ns", "x_start_ns"]).unwrap_or(0);
            let x_step_ns =
                first_i64_attr(dataset, &["sample_period_ns", "time_step_ns", "x_step_ns"])
                    .or_else(|| sample_rate_hz.and_then(sample_period_ns_from_rate_hz))
                    .or_else(|| {
                        let end_ns = first_i64_attr(dataset, &["end_ns", "x_end_ns"])?;
                        Some(derive_step_from_bounds(x_start_ns, end_ns, width))
                    })
                    .unwrap_or(1);

            extra.insert("hdf5.mapping".to_string(), "grid2d".to_string());
            extra.insert("hdf5.width".to_string(), width.to_string());
            extra.insert("hdf5.height".to_string(), height.to_string());

            (
                StreamKind::Grid2D,
                Hdf5Interpretation::Grid2D {
                    x_range: TimeRange::new(
                        x_start_ns,
                        x_start_ns.saturating_add(x_step_ns.saturating_mul(width as i64)),
                    ),
                    y_label: first_string_attr(dataset, &["dd_y_label", "y_label"])
                        .unwrap_or_else(|| "Y".to_string()),
                    y_unit: first_string_attr(dataset, &["dd_y_unit", "y_unit"]),
                    width,
                    height,
                },
            )
        }
        3 => {
            let x_len = shape[0];
            let y_len = shape[1];
            let z_len = shape[2];

            extra.insert("hdf5.mapping".to_string(), "volume3d".to_string());
            extra.insert("hdf5.x_len".to_string(), x_len.to_string());
            extra.insert("hdf5.y_len".to_string(), y_len.to_string());
            extra.insert("hdf5.z_len".to_string(), z_len.to_string());

            (
                StreamKind::Volume3D,
                Hdf5Interpretation::Volume3D {
                    x_len,
                    y_len,
                    z_len,
                },
            )
        }
        _ => return Ok(None),
    };

    Ok(Some(Hdf5DiscoveredDataset {
        path: dataset_path,
        kind,
        channel,
        tags,
        extra,
        interpretation,
    }))
}

fn collect_dataset_metadata(
    file_path: &Path,
    dataset_path: &str,
    dataset: &Dataset<'_>,
) -> Metadata {
    let mut metadata = Metadata::new();
    metadata.insert("hdf5.path".to_string(), dataset_path.to_string());
    metadata.insert("hdf5.filename".to_string(), file_path.display().to_string());

    for attr in dataset.attributes() {
        if let Some(value) = read_attr_as_string(&attr) {
            metadata.insert(format!("hdf5.attr.{}", attr.name), value);
        }
    }

    metadata
}

fn first_string_attr(dataset: &Dataset<'_>, names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| {
        let attr = dataset.attribute(name).ok()?;
        read_attr_as_string(&attr)
    })
}

fn first_i64_attr(dataset: &Dataset<'_>, names: &[&str]) -> Option<i64> {
    names.iter().find_map(|name| {
        let attr = dataset.attribute(name).ok()?;
        read_attr_as_i64(&attr)
    })
}

fn first_f64_attr(dataset: &Dataset<'_>, names: &[&str]) -> Option<f64> {
    names.iter().find_map(|name| {
        let attr = dataset.attribute(name).ok()?;
        read_attr_as_f64(&attr)
    })
}

fn read_attr_as_string(attr: &Attribute) -> Option<String> {
    attr.read_string()
        .ok()
        .or_else(|| attr.read_strings().ok().map(|values| values.join(",")))
        .or_else(|| read_attr_as_i64(attr).map(|value| value.to_string()))
        .or_else(|| read_attr_as_f64(attr).map(|value| value.to_string()))
}

fn read_attr_as_i64(attr: &Attribute) -> Option<i64> {
    match &attr.datatype {
        Datatype::FixedPoint {
            size, signed: true, ..
        } => match size {
            1 => attr.read_scalar::<i8>().ok().map(i64::from),
            2 => attr.read_scalar::<i16>().ok().map(i64::from),
            4 => attr.read_scalar::<i32>().ok().map(i64::from),
            8 => attr.read_scalar::<i64>().ok(),
            _ => None,
        },
        Datatype::FixedPoint {
            size,
            signed: false,
            ..
        } => match size {
            1 => attr.read_scalar::<u8>().ok().map(i64::from),
            2 => attr.read_scalar::<u16>().ok().map(i64::from),
            4 => attr.read_scalar::<u32>().ok().map(i64::from),
            8 => attr
                .read_scalar::<u64>()
                .ok()
                .and_then(|value| i64::try_from(value).ok()),
            _ => None,
        },
        _ => read_attr_as_string_like_number(attr)?.parse::<i64>().ok(),
    }
}

fn read_attr_as_f64(attr: &Attribute) -> Option<f64> {
    match &attr.datatype {
        Datatype::FloatingPoint { .. } | Datatype::FixedPoint { .. } => attr.read_as_f64().ok(),
        _ => read_attr_as_string_like_number(attr)?.parse::<f64>().ok(),
    }
}

fn read_attr_as_string_like_number(attr: &Attribute) -> Option<String> {
    attr.read_string()
        .ok()
        .or_else(|| attr.read_strings().ok().map(|values| values.join(",")))
}

fn parse_tags(value: String) -> Vec<String> {
    value
        .split([',', ';'])
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .map(str::to_string)
        .collect()
}

fn format_shape(shape: &[usize]) -> String {
    shape
        .iter()
        .map(|dimension| dimension.to_string())
        .collect::<Vec<_>>()
        .join("x")
}

fn default_display_name(path: &str) -> String {
    path.rsplit('/').next().unwrap_or(path).replace('_', " ")
}

fn is_supported_numeric_type(datatype: &Datatype) -> bool {
    matches!(
        datatype,
        Datatype::FixedPoint { .. } | Datatype::FloatingPoint { .. }
    )
}

fn derive_step_from_bounds(start_ns: i64, end_ns: i64, width: usize) -> i64 {
    if width == 0 {
        return 1;
    }

    let span = end_ns.saturating_sub(start_ns);
    if span <= 0 {
        return 1;
    }

    (span / width as i64).max(1)
}

fn sample_period_ns_from_rate_hz(sample_rate_hz: f64) -> Option<i64> {
    if !sample_rate_hz.is_finite() || sample_rate_hz <= 0.0 {
        return None;
    }

    let period_ns = (1_000_000_000.0 / sample_rate_hz).round();
    if !period_ns.is_finite() || period_ns <= 0.0 {
        return None;
    }

    Some(period_ns as i64)
}

fn reader_result<T>(
    result: hdf5_reader::error::Result<T>,
    context: impl FnOnce() -> String,
) -> BackendResult<T> {
    result.map_err(|error| BackendError::io(format!("{}: {error}", context())))
}

fn owned_array_into_vec<T>(array: ndarray::ArrayD<T>, dataset_name: &str) -> BackendResult<Vec<T>> {
    let (values, offset) = array.into_raw_vec_and_offset();
    if offset.unwrap_or(0) == 0 {
        Ok(values)
    } else {
        Err(BackendError::internal(format!(
            "dataset `{dataset_name}` returned a non-zero array offset"
        )))
    }
}

fn read_dataset_array_vec<T: H5Type + Clone>(
    dataset: &Dataset<'_>,
    type_name: &str,
) -> BackendResult<Vec<T>> {
    let array = reader_result(dataset.read_array::<T>(), || {
        format!("failed to read `{}` as {type_name} array", dataset.name())
    })?;
    owned_array_into_vec(array, dataset.name())
}

fn stream_kind(block: &DataBlock) -> StreamKind {
    match block {
        DataBlock::Series1D(_) => StreamKind::Series1D,
        DataBlock::Sampled(_) => StreamKind::Sampled,
        DataBlock::Spectrum(_) => StreamKind::Spectrum,
        DataBlock::Grid2D(_) => StreamKind::Grid2D,
        DataBlock::Volume3D(_) => StreamKind::Volume3D,
        DataBlock::EventSeries(_) => StreamKind::EventSeries,
    }
}

fn block_sample_shape(block: &DataBlock) -> Vec<usize> {
    match block {
        DataBlock::Series1D(_) => Vec::new(),
        DataBlock::Sampled(sampled) => sampled.sample_shape.clone(),
        DataBlock::Spectrum(_) => Vec::new(),
        DataBlock::Grid2D(_) => Vec::new(),
        DataBlock::Volume3D(_) => Vec::new(),
        DataBlock::EventSeries(_) => Vec::new(),
    }
}

fn read_registered_dataset(dataset: &Hdf5Dataset, query: &ReadQuery) -> BackendResult<DataBlock> {
    match &dataset.block {
        DataBlock::Series1D(series) => read_series(series, query),
        DataBlock::Sampled(_) => Err(BackendError::unsupported(
            "generic sampled payloads are not yet supported by the HDF5 adapter",
        )),
        DataBlock::Spectrum(_) => Err(BackendError::unsupported(
            "stored spectrum datasets are not yet supported by the HDF5 adapter",
        )),
        DataBlock::Grid2D(grid) => read_grid(grid, query),
        DataBlock::Volume3D(volume) => read_volume(volume, query),
        DataBlock::EventSeries(events) => read_events(events, query),
    }
}

fn read_file_dataset(
    file_path: &Path,
    dataset: &Hdf5DiscoveredDataset,
    query: &ReadQuery,
) -> BackendResult<DataBlock> {
    let file = reader_result(Hdf5File::open(file_path), || {
        format!("failed to open HDF5 file `{}`", file_path.display())
    })?;
    let hdf5_dataset = reader_result(file.dataset(&dataset.path), || {
        format!(
            "failed to open dataset `{}` in `{}`",
            dataset.path,
            file_path.display()
        )
    })?;

    match &dataset.interpretation {
        Hdf5Interpretation::Series1D {
            start_ns,
            sample_period_ns,
        } => {
            let values = read_dataset_values_as_f64(&hdf5_dataset)?;

            let series = Series1D {
                channel: dataset.channel.clone(),
                axis: TimeAxis::Regular {
                    start_ns: *start_ns,
                    sample_period_ns: *sample_period_ns,
                    len: values.len(),
                },
                values,
                metadata: dataset.channel.metadata.clone(),
            };

            read_series(&series, query)
        }
        Hdf5Interpretation::Grid2D {
            x_range,
            y_label,
            y_unit,
            width,
            height,
        } => {
            let values = read_dataset_values_as_f32(&hdf5_dataset)?;

            let grid = Grid2D {
                channel: dataset.channel.clone(),
                x_range: x_range.clone(),
                y_label: y_label.clone(),
                y_unit: y_unit.clone(),
                width: *width,
                height: *height,
                values,
                metadata: dataset.channel.metadata.clone(),
            };

            read_grid(&grid, query)
        }
        Hdf5Interpretation::Volume3D {
            x_len,
            y_len,
            z_len,
        } => {
            let values = read_dataset_values_as_f32(&hdf5_dataset)?;

            let volume = Volume3D {
                channel: dataset.channel.clone(),
                x_len: *x_len,
                y_len: *y_len,
                z_len: *z_len,
                values,
                metadata: dataset.channel.metadata.clone(),
            };

            read_volume(&volume, query)
        }
    }
}

fn read_dataset_values_as_f64(dataset: &Dataset<'_>) -> BackendResult<Vec<f64>> {
    match dataset.dtype() {
        Datatype::FloatingPoint { size: 4, .. } => {
            Ok(read_dataset_array_vec::<f32>(dataset, "f32")?
                .into_iter()
                .map(f64::from)
                .collect())
        }
        Datatype::FloatingPoint { size: 8, .. } => {
            Ok(read_dataset_array_vec::<f64>(dataset, "f64")?)
        }
        Datatype::FixedPoint {
            size: 1,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i8>(dataset, "i8")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        Datatype::FixedPoint {
            size: 1,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u8>(dataset, "u8")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        Datatype::FixedPoint {
            size: 2,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i16>(dataset, "i16")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        Datatype::FixedPoint {
            size: 2,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u16>(dataset, "u16")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        Datatype::FixedPoint {
            size: 4,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i32>(dataset, "i32")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        Datatype::FixedPoint {
            size: 4,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u32>(dataset, "u32")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        Datatype::FixedPoint {
            size: 8,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i64>(dataset, "i64")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        Datatype::FixedPoint {
            size: 8,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u64>(dataset, "u64")?
            .into_iter()
            .map(|value| value as f64)
            .collect()),
        datatype => Err(BackendError::unsupported(format!(
            "unsupported numeric datatype for `{}`: {datatype:?}",
            dataset.name()
        ))),
    }
}

fn read_dataset_values_as_f32(dataset: &Dataset<'_>) -> BackendResult<Vec<f32>> {
    match dataset.dtype() {
        Datatype::FloatingPoint { size: 4, .. } => {
            Ok(read_dataset_array_vec::<f32>(dataset, "f32")?)
        }
        Datatype::FloatingPoint { size: 8, .. } => {
            Ok(read_dataset_array_vec::<f64>(dataset, "f64")?
                .into_iter()
                .map(|value| value as f32)
                .collect())
        }
        Datatype::FixedPoint {
            size: 1,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i8>(dataset, "i8")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        Datatype::FixedPoint {
            size: 1,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u8>(dataset, "u8")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        Datatype::FixedPoint {
            size: 2,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i16>(dataset, "i16")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        Datatype::FixedPoint {
            size: 2,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u16>(dataset, "u16")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        Datatype::FixedPoint {
            size: 4,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i32>(dataset, "i32")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        Datatype::FixedPoint {
            size: 4,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u32>(dataset, "u32")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        Datatype::FixedPoint {
            size: 8,
            signed: true,
            ..
        } => Ok(read_dataset_array_vec::<i64>(dataset, "i64")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        Datatype::FixedPoint {
            size: 8,
            signed: false,
            ..
        } => Ok(read_dataset_array_vec::<u64>(dataset, "u64")?
            .into_iter()
            .map(|value| value as f32)
            .collect()),
        datatype => Err(BackendError::unsupported(format!(
            "unsupported numeric datatype for `{}`: {datatype:?}",
            dataset.name()
        ))),
    }
}

fn read_series(series: &Series1D, query: &ReadQuery) -> BackendResult<DataBlock> {
    let clipped = clip_series(series, &query.time_range, query.allow_gaps)?;

    let block = match query.aggregation {
        Aggregation::Raw => DataBlock::Series1D(clipped),
        Aggregation::Mean => {
            let bucket_size = bucket_size_for(clipped.len(), query.resolution_hint.as_ref())?;
            DataBlock::Series1D(downsample_mean(&clipped, bucket_size))
        }
        Aggregation::Rms => {
            let bucket_size = bucket_size_for(clipped.len(), query.resolution_hint.as_ref())?;
            let rms = moving_rms(&clipped, bucket_size);
            let reduced = if bucket_size > 1 {
                downsample_mean(&rms, bucket_size)
            } else {
                rms
            };
            DataBlock::Series1D(reduced)
        }
        Aggregation::Spectrogram {
            window_len,
            step_len,
        } => DataBlock::Grid2D(spectrogram(&clipped, window_len, step_len)),
        Aggregation::MinMax => {
            return Err(BackendError::unsupported(
                "min/max aggregation needs a dedicated envelope block and is not implemented yet",
            ));
        }
    };

    Ok(block)
}

fn read_grid(grid: &Grid2D, query: &ReadQuery) -> BackendResult<DataBlock> {
    if !grid.x_range.intersects(&query.time_range) && !query.allow_gaps {
        return Err(BackendError::not_found(
            "requested range does not overlap the 2D block",
        ));
    }

    match query.aggregation {
        Aggregation::Raw => Ok(DataBlock::Grid2D(grid.clone())),
        _ => Err(BackendError::unsupported(
            "2D blocks currently only support raw reads",
        )),
    }
}

fn read_volume(volume: &Volume3D, query: &ReadQuery) -> BackendResult<DataBlock> {
    match query.aggregation {
        Aggregation::Raw => Ok(DataBlock::Volume3D(volume.clone())),
        _ => Err(BackendError::unsupported(
            "3D blocks currently only support raw reads",
        )),
    }
}

fn read_events(events: &EventSeries, query: &ReadQuery) -> BackendResult<DataBlock> {
    let overlap = events.time_range.intersection(&query.time_range);
    if overlap.is_none() && !query.allow_gaps {
        return Err(BackendError::not_found(
            "requested range does not overlap the event series",
        ));
    }

    match query.aggregation {
        Aggregation::Raw => Ok(DataBlock::EventSeries(EventSeries {
            channel: events.channel.clone(),
            time_range: overlap.unwrap_or_else(|| query.time_range.clone()),
            events: events
                .events
                .iter()
                .filter(|event| query.time_range.contains(event.timestamp_ns))
                .cloned()
                .collect(),
            metadata: events.metadata.clone(),
        })),
        _ => Err(BackendError::unsupported(
            "event series currently only support raw reads",
        )),
    }
}

fn bucket_size_for(len: usize, hint: Option<&ResolutionHint>) -> BackendResult<usize> {
    let hint = hint.ok_or_else(|| {
        BackendError::invalid_query("aggregation requires a resolution_hint.max_points value")
    })?;

    if hint.max_points == 0 {
        return Err(BackendError::invalid_query(
            "resolution_hint.max_points must be greater than zero",
        ));
    }

    if len <= hint.max_points {
        return Ok(1);
    }

    Ok(len.div_ceil(hint.max_points))
}

fn div_ceil_non_negative(numerator: i64, denominator: i64) -> i64 {
    debug_assert!(numerator >= 0);
    debug_assert!(denominator > 0);

    if numerator == 0 {
        0
    } else {
        1 + (numerator - 1) / denominator
    }
}

fn clip_series(
    series: &Series1D,
    query_range: &TimeRange,
    allow_gaps: bool,
) -> BackendResult<Series1D> {
    let clipped = match &series.axis {
        TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            len,
        } => {
            if *sample_period_ns <= 0 {
                return Err(BackendError::invalid_query(
                    "regular series must use a positive sample period",
                ));
            }

            let end_ns = start_ns.saturating_add(sample_period_ns.saturating_mul(*len as i64));
            let series_range = TimeRange::new(*start_ns, end_ns);
            let overlap = series_range.intersection(query_range);

            if overlap.is_none() && !allow_gaps {
                return Err(BackendError::not_found(
                    "requested range does not overlap the timeseries",
                ));
            }

            let start_idx = if query_range.start_ns <= *start_ns {
                0
            } else {
                div_ceil_non_negative(
                    query_range.start_ns.saturating_sub(*start_ns),
                    *sample_period_ns,
                ) as usize
            };

            let end_idx = if query_range.end_ns <= *start_ns {
                0
            } else {
                div_ceil_non_negative(
                    query_range.end_ns.saturating_sub(*start_ns),
                    *sample_period_ns,
                ) as usize
            }
            .min(*len);

            let values = if start_idx < end_idx {
                series.values[start_idx..end_idx].to_vec()
            } else {
                Vec::new()
            };

            let clipped_start = if start_idx < *len {
                start_ns.saturating_add(sample_period_ns.saturating_mul(start_idx as i64))
            } else {
                query_range.start_ns
            };

            Series1D {
                channel: series.channel.clone(),
                axis: TimeAxis::Regular {
                    start_ns: clipped_start,
                    sample_period_ns: *sample_period_ns,
                    len: values.len(),
                },
                values,
                metadata: series.metadata.clone(),
            }
        }
        TimeAxis::Irregular { timestamps_ns } => {
            let mut clipped_timestamps = Vec::new();
            let mut clipped_values = Vec::new();

            for (timestamp_ns, value) in timestamps_ns
                .iter()
                .copied()
                .zip(series.values.iter().copied())
            {
                if query_range.contains(timestamp_ns) {
                    clipped_timestamps.push(timestamp_ns);
                    clipped_values.push(value);
                }
            }

            if clipped_values.is_empty() && !allow_gaps {
                return Err(BackendError::not_found(
                    "requested range does not overlap the irregular timeseries",
                ));
            }

            Series1D {
                channel: series.channel.clone(),
                axis: TimeAxis::Irregular {
                    timestamps_ns: clipped_timestamps,
                },
                values: clipped_values,
                metadata: series.metadata.clone(),
            }
        }
    };

    Ok(clipped)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::process::Command;
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    use dd_backend::{DataSourceFactory, SourceRegistry};
    use dd_domain::{ChannelDescriptor, Event};

    use super::*;

    fn demo_series() -> Series1D {
        Series1D {
            channel: ChannelDescriptor {
                id: "LSC.DARM_ERR".to_string(),
                display_name: "DARM error".to_string(),
                unit: Some("strain".to_string()),
                sample_rate_hz: Some(1.0),
                metadata: Metadata::from([("group".to_string(), "control".to_string())]),
            },
            axis: TimeAxis::Regular {
                start_ns: 0,
                sample_period_ns: 1,
                len: 8,
            },
            values: vec![0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0],
            metadata: Metadata::from([("source".to_string(), "simulated".to_string())]),
        }
    }

    fn demo_layout() -> Hdf5Layout {
        let grid = Grid2D {
            channel: ChannelDescriptor {
                id: "SPEC.BAND".to_string(),
                display_name: "Spectrogram band".to_string(),
                unit: Some("power".to_string()),
                sample_rate_hz: None,
                metadata: Metadata::new(),
            },
            x_range: TimeRange::new(0, 8),
            y_label: "Frequency".to_string(),
            y_unit: Some("bin".to_string()),
            width: 2,
            height: 3,
            values: vec![1.0, 0.9, 0.8, 0.7, 0.6, 0.5],
            metadata: Metadata::new(),
        };

        let events = EventSeries {
            channel: ChannelDescriptor::new("TRIGGERS", "Trigger list"),
            time_range: TimeRange::new(0, 100),
            events: vec![
                Event {
                    timestamp_ns: 10,
                    label: "start".to_string(),
                    metadata: Metadata::new(),
                },
                Event {
                    timestamp_ns: 60,
                    label: "peak".to_string(),
                    metadata: Metadata::new(),
                },
            ],
            metadata: Metadata::new(),
        };

        Hdf5Layout::new()
            .with_dataset(
                Hdf5Dataset::series(
                    "/channels/LSC_DARM_ERR",
                    demo_series(),
                    vec!["control".to_string()],
                )
                .with_extra("layout", "1d_regular"),
            )
            .with_dataset(Hdf5Dataset::grid2d(
                "/derived/spectrogram",
                grid,
                vec!["analysis".to_string()],
            ))
            .with_dataset(Hdf5Dataset::event_series(
                "/events/triggers",
                events,
                vec!["events".to_string()],
            ))
    }

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
        let path = temp_hdf5_path("fixture");
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

    #[test]
    fn catalog_filters_streams_without_exposing_hdf5_in_query_shape() {
        let factory = Hdf5Factory::new();
        factory
            .register_layout("hdf5:///demo/run01.h5", demo_layout())
            .expect("layout registration should succeed");

        let source = factory
            .open(&SourceTarget::new("hdf5:///demo/run01.h5"))
            .expect("registered source should open");

        let streams = source
            .catalog(&CatalogQuery {
                text: Some("darm".to_string()),
                tags: vec!["control".to_string()],
                offset: 0,
                limit: Some(10),
            })
            .expect("catalog query should succeed");

        assert_eq!(streams.streams.len(), 1);
        assert_eq!(streams.streams[0].channel.id, "LSC.DARM_ERR");
        assert_eq!(streams.streams[0].kind, StreamKind::Series1D);
        assert_eq!(
            streams.streams[0].extra.get("storage.kind"),
            Some(&"hdf5".to_string())
        );
    }

    #[test]
    fn registry_can_open_hdf5_factory() {
        let factory = Arc::new(Hdf5Factory::new());
        factory
            .register_layout("hdf5:///demo/run01.h5", demo_layout())
            .expect("layout registration should succeed");

        let registry = SourceRegistry::new().with_factory(factory as Arc<dyn DataSourceFactory>);
        let source = registry
            .open_uri("hdf5:///demo/run01.h5")
            .expect("source registry should dispatch to hdf5 factory");

        assert_eq!(source.source_name(), "hdf5:///demo/run01.h5");
    }

    #[test]
    fn series_read_respects_time_window_and_resolution_hint() {
        let factory = Hdf5Factory::new();
        factory
            .register_layout("hdf5:///demo/run01.h5", demo_layout())
            .expect("layout registration should succeed");
        let source = factory
            .open(&SourceTarget::new("hdf5:///demo/run01.h5"))
            .expect("registered source should open");

        let block = source
            .read(&ReadQuery {
                channel_id: "LSC.DARM_ERR".to_string(),
                time_range: TimeRange::new(2, 8),
                resolution_hint: Some(ResolutionHint { max_points: 3 }),
                aggregation: Aggregation::Mean,
                allow_gaps: false,
            })
            .expect("mean query should succeed");

        let DataBlock::Series1D(series) = block else {
            panic!("expected series result");
        };

        assert_eq!(series.values, vec![2.5, 4.5, 6.5]);
        assert!(series.is_consistent());
    }

    #[test]
    fn spectrogram_query_returns_grid() {
        let factory = Hdf5Factory::new();
        factory
            .register_layout("hdf5:///demo/run01.h5", demo_layout())
            .expect("layout registration should succeed");
        let source = factory
            .open(&SourceTarget::new("hdf5:///demo/run01.h5"))
            .expect("registered source should open");

        let block = source
            .read(&ReadQuery {
                channel_id: "LSC.DARM_ERR".to_string(),
                time_range: TimeRange::new(0, 8),
                resolution_hint: None,
                aggregation: Aggregation::Spectrogram {
                    window_len: 4,
                    step_len: 2,
                },
                allow_gaps: false,
            })
            .expect("spectrogram query should succeed");

        let DataBlock::Grid2D(grid) = block else {
            panic!("expected grid result");
        };

        assert_eq!(grid.channel.id, "LSC.DARM_ERR:spectrogram");
        assert!(grid.is_consistent());
    }

    #[test]
    fn event_reads_filter_by_time_range() {
        let factory = Hdf5Factory::new();
        factory
            .register_layout("hdf5:///demo/run01.h5", demo_layout())
            .expect("layout registration should succeed");
        let source = factory
            .open(&SourceTarget::new("hdf5:///demo/run01.h5"))
            .expect("registered source should open");

        let block = source
            .read(&ReadQuery {
                channel_id: "TRIGGERS".to_string(),
                time_range: TimeRange::new(20, 80),
                resolution_hint: None,
                aggregation: Aggregation::Raw,
                allow_gaps: false,
            })
            .expect("event query should succeed");

        let DataBlock::EventSeries(events) = block else {
            panic!("expected event series result");
        };

        assert_eq!(events.events.len(), 1);
        assert_eq!(events.events[0].label, "peak");
    }

    #[test]
    fn real_hdf5_file_catalog_and_reads_work() {
        let path = create_real_hdf5_fixture();
        let uri = format!("hdf5://{}", path.display());
        let factory = Hdf5Factory::new();
        let source = factory
            .open(&SourceTarget::new(uri))
            .expect("real file source should open");

        let streams = source
            .catalog(&CatalogQuery {
                text: Some("darm".to_string()),
                tags: vec!["control".to_string()],
                offset: 0,
                limit: None,
            })
            .expect("catalog should succeed");

        assert_eq!(streams.streams.len(), 1);
        assert_eq!(streams.streams[0].channel.id, "LSC.DARM_ERR");
        assert_eq!(
            streams.streams[0].extra.get("hdf5.mapping"),
            Some(&"series1d".to_string())
        );

        let block = source
            .read(&ReadQuery {
                channel_id: "LSC.DARM_ERR".to_string(),
                time_range: TimeRange::new(14, 26),
                resolution_hint: Some(ResolutionHint { max_points: 3 }),
                aggregation: Aggregation::Mean,
                allow_gaps: false,
            })
            .expect("real series read should succeed");

        let DataBlock::Series1D(series) = block else {
            panic!("expected real series result");
        };

        assert_eq!(series.values, vec![2.5, 4.5, 6.5]);
        assert_eq!(series.channel.unit.as_deref(), Some("strain"));
        assert_eq!(
            series.channel.metadata.get("hdf5.attr.dd_display_name"),
            Some(&"DARM error".to_string())
        );

        let grid_block = source
            .read(&ReadQuery {
                channel_id: "/derived/spectrogram".to_string(),
                time_range: TimeRange::new(100, 120),
                resolution_hint: None,
                aggregation: Aggregation::Raw,
                allow_gaps: false,
            })
            .expect("grid read should succeed");

        let DataBlock::Grid2D(grid) = grid_block else {
            panic!("expected grid result");
        };
        assert_eq!(grid.width, 4);
        assert_eq!(grid.height, 3);
        assert!(grid.is_consistent());

        let volume_block = source
            .read(&ReadQuery {
                channel_id: "/volumes/cube".to_string(),
                time_range: TimeRange::new(0, 1),
                resolution_hint: None,
                aggregation: Aggregation::Raw,
                allow_gaps: true,
            })
            .expect("volume read should succeed");

        let DataBlock::Volume3D(volume) = volume_block else {
            panic!("expected volume result");
        };
        assert_eq!((volume.x_len, volume.y_len, volume.z_len), (2, 3, 4));
        assert!(volume.is_consistent());

        std::fs::remove_file(path).expect("fixture should be removed");
    }
}
