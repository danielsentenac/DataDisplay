//! Core domain types for the DATADISPLAY platform.

use std::collections::BTreeMap;

pub type Metadata = BTreeMap<String, String>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TimeRange {
    pub start_ns: i64,
    pub end_ns: i64,
}

impl TimeRange {
    pub fn new(start_ns: i64, end_ns: i64) -> Self {
        Self { start_ns, end_ns }
    }

    pub fn is_valid(&self) -> bool {
        self.start_ns <= self.end_ns
    }

    pub fn duration_ns(&self) -> i64 {
        self.end_ns.saturating_sub(self.start_ns)
    }

    pub fn contains(&self, timestamp_ns: i64) -> bool {
        timestamp_ns >= self.start_ns && timestamp_ns < self.end_ns
    }

    pub fn intersects(&self, other: &Self) -> bool {
        self.start_ns < other.end_ns && other.start_ns < self.end_ns
    }

    pub fn intersection(&self, other: &Self) -> Option<Self> {
        if !self.intersects(other) {
            return None;
        }

        Some(Self {
            start_ns: self.start_ns.max(other.start_ns),
            end_ns: self.end_ns.min(other.end_ns),
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum TimeAxis {
    Regular {
        start_ns: i64,
        sample_period_ns: i64,
        len: usize,
    },
    Irregular {
        timestamps_ns: Vec<i64>,
    },
}

impl TimeAxis {
    pub fn len(&self) -> usize {
        match self {
            Self::Regular { len, .. } => *len,
            Self::Irregular { timestamps_ns } => timestamps_ns.len(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn first_timestamp_ns(&self) -> Option<i64> {
        match self {
            Self::Regular { start_ns, len, .. } if *len > 0 => Some(*start_ns),
            Self::Regular { .. } => None,
            Self::Irregular { timestamps_ns } => timestamps_ns.first().copied(),
        }
    }

    pub fn last_timestamp_ns(&self) -> Option<i64> {
        match self {
            Self::Regular {
                start_ns,
                sample_period_ns,
                len,
            } if *len > 0 => {
                Some(start_ns.saturating_add(sample_period_ns.saturating_mul((*len - 1) as i64)))
            }
            Self::Regular { .. } => None,
            Self::Irregular { timestamps_ns } => timestamps_ns.last().copied(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ChannelDescriptor {
    pub id: String,
    pub display_name: String,
    pub unit: Option<String>,
    pub sample_rate_hz: Option<f64>,
    pub metadata: Metadata,
}

impl ChannelDescriptor {
    pub fn new(id: impl Into<String>, display_name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            display_name: display_name.into(),
            unit: None,
            sample_rate_hz: None,
            metadata: Metadata::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Series1D {
    pub channel: ChannelDescriptor,
    pub axis: TimeAxis,
    pub values: Vec<f64>,
    pub metadata: Metadata,
}

impl Series1D {
    pub fn len(&self) -> usize {
        self.values.len()
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    pub fn is_consistent(&self) -> bool {
        self.axis.len() == self.values.len()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SampleAxis {
    pub label: String,
    pub unit: Option<String>,
    pub len: usize,
    pub origin: Option<f64>,
    pub spacing: Option<f64>,
}

impl SampleAxis {
    pub fn new(label: impl Into<String>, len: usize) -> Self {
        Self {
            label: label.into(),
            unit: None,
            len,
            origin: None,
            spacing: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SampledData {
    pub channel: ChannelDescriptor,
    pub axis: TimeAxis,
    pub sample_shape: Vec<usize>,
    pub sample_axes: Vec<SampleAxis>,
    pub values: Vec<f64>,
    pub metadata: Metadata,
}

impl SampledData {
    pub fn len(&self) -> usize {
        self.axis.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn sample_rank(&self) -> usize {
        self.sample_shape.len()
    }

    pub fn is_scalar(&self) -> bool {
        self.sample_shape.is_empty()
    }

    pub fn sample_len(&self) -> usize {
        if self.sample_shape.is_empty() {
            1
        } else {
            self.sample_shape
                .iter()
                .copied()
                .fold(1usize, usize::saturating_mul)
        }
    }

    pub fn expected_len(&self) -> usize {
        self.len().saturating_mul(self.sample_len())
    }

    pub fn is_consistent(&self) -> bool {
        self.expected_len() == self.values.len()
            && (self.sample_axes.is_empty()
                || (self.sample_axes.len() == self.sample_shape.len()
                    && self
                        .sample_axes
                        .iter()
                        .zip(self.sample_shape.iter())
                        .all(|(axis, len)| axis.len == *len)))
    }
}

impl From<Series1D> for SampledData {
    fn from(series: Series1D) -> Self {
        Self {
            channel: series.channel,
            axis: series.axis,
            sample_shape: Vec::new(),
            sample_axes: Vec::new(),
            values: series.values,
            metadata: series.metadata,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Grid2D {
    pub channel: ChannelDescriptor,
    pub x_range: TimeRange,
    pub y_label: String,
    pub y_unit: Option<String>,
    pub width: usize,
    pub height: usize,
    pub values: Vec<f32>,
    pub metadata: Metadata,
}

impl Grid2D {
    pub fn expected_len(&self) -> usize {
        self.width.saturating_mul(self.height)
    }

    pub fn is_consistent(&self) -> bool {
        self.expected_len() == self.values.len()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Volume3D {
    pub channel: ChannelDescriptor,
    pub x_len: usize,
    pub y_len: usize,
    pub z_len: usize,
    pub values: Vec<f32>,
    pub metadata: Metadata,
}

impl Volume3D {
    pub fn expected_len(&self) -> usize {
        self.x_len
            .saturating_mul(self.y_len)
            .saturating_mul(self.z_len)
    }

    pub fn is_consistent(&self) -> bool {
        self.expected_len() == self.values.len()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub timestamp_ns: i64,
    pub label: String,
    pub metadata: Metadata,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EventSeries {
    pub channel: ChannelDescriptor,
    pub time_range: TimeRange,
    pub events: Vec<Event>,
    pub metadata: Metadata,
}

impl EventSeries {
    pub fn len(&self) -> usize {
        self.events.len()
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum DataBlock {
    Series1D(Series1D),
    Sampled(SampledData),
    Grid2D(Grid2D),
    Volume3D(Volume3D),
    EventSeries(EventSeries),
}

impl DataBlock {
    pub fn kind_name(&self) -> &'static str {
        match self {
            Self::Series1D(_) => "series1d",
            Self::Sampled(_) => "sampled",
            Self::Grid2D(_) => "grid2d",
            Self::Volume3D(_) => "volume3d",
            Self::EventSeries(_) => "event_series",
        }
    }

    pub fn channel(&self) -> &ChannelDescriptor {
        match self {
            Self::Series1D(series) => &series.channel,
            Self::Sampled(sampled) => &sampled.channel,
            Self::Grid2D(grid) => &grid.channel,
            Self::Volume3D(volume) => &volume.channel,
            Self::EventSeries(events) => &events.channel,
        }
    }

    pub fn metadata(&self) -> &Metadata {
        match self {
            Self::Series1D(series) => &series.metadata,
            Self::Sampled(sampled) => &sampled.metadata,
            Self::Grid2D(grid) => &grid.metadata,
            Self::Volume3D(volume) => &volume.metadata,
            Self::EventSeries(events) => &events.metadata,
        }
    }
}
