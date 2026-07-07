//! Toolkit-independent plot scene model.
//!
//! A [`PlotScene`] carries everything a dumb renderer needs to draw one pane:
//! axes (with log flags and data ranges), positioned layers, legend labels and
//! real-world coordinates. Time-valued x coordinates are seconds relative to
//! `epoch_ns` so f64 precision survives GPS-scale timestamps.

use dd_domain::{Grid2D, Series1D, Spectrum, TimeAxis, TimeRange, Volume3D};

#[derive(Clone, Debug, PartialEq)]
pub struct AxisSpec {
    pub label: String,
    pub unit: Option<String>,
    pub log_scale: bool,
    /// Data range hint (min, max) so renderers can frame without rescanning.
    pub range: Option<(f64, f64)>,
}

impl AxisSpec {
    pub fn new(label: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            unit: None,
            log_scale: false,
            range: None,
        }
    }

    pub fn with_unit(mut self, unit: Option<String>) -> Self {
        self.unit = unit;
        self
    }

    pub fn with_log(mut self, log_scale: bool) -> Self {
        self.log_scale = log_scale;
        self
    }

    pub fn with_range(mut self, range: Option<(f64, f64)>) -> Self {
        self.range = range;
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlotKind {
    Line1D,
    Heatmap2D,
    Volume3D,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LineLayer {
    /// Legend entry.
    pub label: String,
    pub xs: Vec<f64>,
    pub ys: Vec<f64>,
    pub color_rgba: [f32; 4],
}

#[derive(Clone, Debug, PartialEq)]
pub struct HeatmapLayer {
    pub width: usize,
    pub height: usize,
    /// Coordinates of the first cell edge and the cell pitch, in axis units.
    pub x0: f64,
    pub dx: f64,
    pub y0: f64,
    pub dy: f64,
    /// Column-major: all rows of the first column, then the second, ...
    pub values: Vec<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct VolumeLayer {
    pub x_len: usize,
    pub y_len: usize,
    pub z_len: usize,
    pub values: Vec<f32>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PlotLayer {
    Line(LineLayer),
    Heatmap(HeatmapLayer),
    Volume(VolumeLayer),
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlotScene {
    pub title: String,
    pub kind: PlotKind,
    pub x_axis: AxisSpec,
    pub y_axis: AxisSpec,
    pub z_axis: Option<AxisSpec>,
    /// Absolute epoch: time-valued x coordinates are seconds since this.
    pub epoch_ns: Option<i64>,
    pub time_range: Option<TimeRange>,
    pub layers: Vec<PlotLayer>,
}

/// Default trace color cycle (close to the original dataDisplay color set).
pub fn default_color(index: usize) -> [f32; 4] {
    const CYCLE: [[f32; 4]; 8] = [
        [0.10, 0.45, 0.95, 1.0], // blue
        [0.90, 0.10, 0.10, 1.0], // red
        [0.00, 0.60, 0.20, 1.0], // green
        [0.80, 0.20, 0.80, 1.0], // magenta
        [0.00, 0.65, 0.75, 1.0], // cyan
        [0.95, 0.55, 0.05, 1.0], // orange
        [0.45, 0.30, 0.10, 1.0], // brown
        [0.35, 0.35, 0.35, 1.0], // grey
    ];
    CYCLE[index % CYCLE.len()]
}

fn finite_range<'a>(values: impl Iterator<Item = &'a f64>) -> Option<(f64, f64)> {
    let mut range: Option<(f64, f64)> = None;
    for value in values.filter(|value| value.is_finite()) {
        range = Some(match range {
            Some((min, max)) => (min.min(*value), max.max(*value)),
            None => (*value, *value),
        });
    }
    range
}

fn series_times_seconds(series: &Series1D, epoch_ns: i64) -> Vec<f64> {
    match &series.axis {
        TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            len,
        } => {
            let start = (*start_ns - epoch_ns) as f64 * 1e-9;
            let step = *sample_period_ns as f64 * 1e-9;
            (0..*len).map(|index| start + step * index as f64).collect()
        }
        TimeAxis::Irregular { timestamps_ns } => timestamps_ns
            .iter()
            .map(|ts| (*ts - epoch_ns) as f64 * 1e-9)
            .collect(),
    }
}

/// Multi-trace time-series pane. X is seconds relative to the earliest series
/// start, exposed as `epoch_ns`.
pub fn time_series_scene(series: &[&Series1D], title: impl Into<String>) -> PlotScene {
    let epoch_ns = series
        .iter()
        .filter_map(|s| s.axis.first_timestamp_ns())
        .min()
        .unwrap_or(0);
    let mut end_ns = epoch_ns;

    let mut layers = Vec::with_capacity(series.len());
    let mut y_range: Option<(f64, f64)> = None;
    let mut x_range: Option<(f64, f64)> = None;
    for (index, one) in series.iter().enumerate() {
        let xs = series_times_seconds(one, epoch_ns);
        if let Some(last_ns) = one.axis.last_timestamp_ns() {
            end_ns = end_ns.max(last_ns);
        }
        y_range = merge_ranges(y_range, finite_range(one.values.iter()));
        x_range = merge_ranges(x_range, finite_range(xs.iter()));
        layers.push(PlotLayer::Line(LineLayer {
            label: one.channel.display_name.clone(),
            xs,
            ys: one.values.clone(),
            color_rgba: default_color(index),
        }));
    }

    let y_unit = series
        .iter()
        .find_map(|one| one.channel.unit.clone());

    PlotScene {
        title: title.into(),
        kind: PlotKind::Line1D,
        x_axis: AxisSpec::new("Time")
            .with_unit(Some("s".to_string()))
            .with_range(x_range),
        y_axis: AxisSpec::new("Value").with_unit(y_unit).with_range(y_range),
        z_axis: None,
        epoch_ns: Some(epoch_ns),
        time_range: Some(TimeRange::new(epoch_ns, end_ns)),
        layers,
    }
}

/// Multi-trace frequency-domain pane (spectra, coherence, transfer function
/// components). X is frequency in Hz.
pub fn spectrum_scene(
    spectra: &[&Spectrum],
    title: impl Into<String>,
    log_x: bool,
    log_y: bool,
) -> PlotScene {
    let mut layers = Vec::with_capacity(spectra.len());
    let mut y_range: Option<(f64, f64)> = None;
    let mut x_range: Option<(f64, f64)> = None;
    for (index, spectrum) in spectra.iter().enumerate() {
        let xs: Vec<f64> = spectrum.axis.frequencies().collect();
        y_range = merge_ranges(y_range, finite_range(spectrum.values.iter()));
        x_range = merge_ranges(x_range, finite_range(xs.iter()));
        layers.push(PlotLayer::Line(LineLayer {
            label: spectrum.channel.display_name.clone(),
            xs,
            ys: spectrum.values.clone(),
            color_rgba: default_color(index),
        }));
    }

    let y_unit = spectra.iter().find_map(|one| one.channel.unit.clone());
    let time_range = spectra.first().map(|one| one.time_range.clone());

    PlotScene {
        title: title.into(),
        kind: PlotKind::Line1D,
        x_axis: AxisSpec::new("Frequency")
            .with_unit(Some("Hz".to_string()))
            .with_log(log_x)
            .with_range(x_range),
        y_axis: AxisSpec::new("Value")
            .with_unit(y_unit)
            .with_log(log_y)
            .with_range(y_range),
        z_axis: None,
        epoch_ns: None,
        time_range,
        layers,
    }
}

/// Spectrogram pane from a [`Grid2D`]. Row frequencies come from the
/// `dd_y_origin_hz`/`dd_y_step_hz` metadata written by `dd-processing`
/// (falling back to bin indices); x is seconds relative to `epoch_ns`.
pub fn spectrogram_scene(grid: &Grid2D, log_z: bool) -> PlotScene {
    let epoch_ns = grid.x_range.start_ns;
    let duration_s = grid.x_range.duration_ns() as f64 * 1e-9;
    let dx = if grid.width > 0 {
        duration_s / grid.width as f64
    } else {
        0.0
    };
    let y0 = grid
        .metadata
        .get("dd_y_origin_hz")
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(0.0);
    let dy = grid
        .metadata
        .get("dd_y_step_hz")
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(1.0);

    let z_range = {
        let finite = grid.values.iter().filter(|v| v.is_finite());
        let mut range: Option<(f64, f64)> = None;
        for value in finite {
            let value = *value as f64;
            range = Some(match range {
                Some((min, max)) => (min.min(value), max.max(value)),
                None => (value, value),
            });
        }
        range
    };

    PlotScene {
        title: grid.channel.display_name.clone(),
        kind: PlotKind::Heatmap2D,
        x_axis: AxisSpec::new("Time")
            .with_unit(Some("s".to_string()))
            .with_range(Some((0.0, duration_s))),
        y_axis: AxisSpec::new(grid.y_label.clone())
            .with_unit(grid.y_unit.clone())
            .with_range(Some((y0, y0 + dy * grid.height as f64))),
        z_axis: Some(
            AxisSpec::new("Value")
                .with_unit(grid.channel.unit.clone())
                .with_log(log_z)
                .with_range(z_range),
        ),
        epoch_ns: Some(epoch_ns),
        time_range: Some(grid.x_range.clone()),
        layers: vec![PlotLayer::Heatmap(HeatmapLayer {
            width: grid.width,
            height: grid.height,
            x0: 0.0,
            dx,
            y0,
            dy,
            values: grid.values.clone(),
        })],
    }
}

pub fn volume_scene(volume: &Volume3D) -> PlotScene {
    PlotScene {
        title: volume.channel.display_name.clone(),
        kind: PlotKind::Volume3D,
        x_axis: AxisSpec::new("X"),
        y_axis: AxisSpec::new("Y"),
        z_axis: Some(AxisSpec::new("Z")),
        epoch_ns: None,
        time_range: None,
        layers: vec![PlotLayer::Volume(VolumeLayer {
            x_len: volume.x_len,
            y_len: volume.y_len,
            z_len: volume.z_len,
            values: volume.values.clone(),
        })],
    }
}

fn merge_ranges(
    a: Option<(f64, f64)>,
    b: Option<(f64, f64)>,
) -> Option<(f64, f64)> {
    match (a, b) {
        (Some((min_a, max_a)), Some((min_b, max_b))) => {
            Some((min_a.min(min_b), max_a.max(max_b)))
        }
        (Some(range), None) | (None, Some(range)) => Some(range),
        (None, None) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dd_domain::{ChannelDescriptor, FrequencyAxis, Metadata};

    fn series(start_ns: i64, values: Vec<f64>) -> Series1D {
        let len = values.len();
        Series1D {
            channel: ChannelDescriptor::new("ch", "Channel"),
            axis: TimeAxis::Regular {
                start_ns,
                sample_period_ns: 1_000_000,
                len,
            },
            values,
            metadata: Metadata::new(),
        }
    }

    #[test]
    fn time_series_scene_uses_relative_seconds() {
        let a = series(1_000_000_000, vec![1.0, 2.0, 3.0]);
        let b = series(2_000_000_000, vec![4.0, 5.0]);
        let scene = time_series_scene(&[&a, &b], "two traces");

        assert_eq!(scene.epoch_ns, Some(1_000_000_000));
        assert_eq!(scene.layers.len(), 2);
        let PlotLayer::Line(first) = &scene.layers[0] else {
            panic!("expected line layer");
        };
        assert_eq!(first.xs[0], 0.0);
        assert!((first.xs[1] - 0.001).abs() < 1e-12);
        let PlotLayer::Line(second) = &scene.layers[1] else {
            panic!("expected line layer");
        };
        assert!((second.xs[0] - 1.0).abs() < 1e-12);
        assert_eq!(scene.y_axis.range, Some((1.0, 5.0)));
    }

    #[test]
    fn spectrum_scene_carries_frequencies_and_log_flags() {
        let spectrum = Spectrum {
            channel: ChannelDescriptor::new("ch:asd", "Channel ASD"),
            time_range: TimeRange::new(0, 1_000_000_000),
            axis: FrequencyAxis::new(0.0, 2.0, 3),
            values: vec![1.0, 4.0, 9.0],
            metadata: Metadata::new(),
        };
        let scene = spectrum_scene(&[&spectrum], "asd", true, true);

        assert!(scene.x_axis.log_scale);
        assert!(scene.y_axis.log_scale);
        let PlotLayer::Line(layer) = &scene.layers[0] else {
            panic!("expected line layer");
        };
        assert_eq!(layer.xs, vec![0.0, 2.0, 4.0]);
        assert_eq!(scene.y_axis.range, Some((1.0, 9.0)));
    }

    #[test]
    fn spectrogram_scene_reads_frequency_metadata() {
        let mut metadata = Metadata::new();
        metadata.insert("dd_y_origin_hz".to_string(), "0".to_string());
        metadata.insert("dd_y_step_hz".to_string(), "5".to_string());
        let grid = Grid2D {
            channel: ChannelDescriptor::new("ch:spectrogram", "Spectrogram"),
            x_range: TimeRange::new(1_000_000_000, 3_000_000_000),
            y_label: "Frequency".to_string(),
            y_unit: Some("Hz".to_string()),
            width: 2,
            height: 3,
            values: vec![0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
            metadata,
        };
        let scene = spectrogram_scene(&grid, true);

        assert_eq!(scene.epoch_ns, Some(1_000_000_000));
        let PlotLayer::Heatmap(layer) = &scene.layers[0] else {
            panic!("expected heatmap layer");
        };
        assert_eq!(layer.dy, 5.0);
        assert!((layer.dx - 1.0).abs() < 1e-12);
        assert!(scene.z_axis.as_ref().unwrap().log_scale);
        assert_eq!(scene.y_axis.range, Some((0.0, 15.0)));
    }
}
