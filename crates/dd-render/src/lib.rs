//! Toolkit-independent plot scene types.

use dd_domain::{Grid2D, Series1D, TimeRange, Volume3D};

#[derive(Clone, Debug, PartialEq)]
pub struct AxisSpec {
    pub label: String,
    pub unit: Option<String>,
    pub log_scale: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlotKind {
    Line1D,
    Heatmap2D,
    Volume3D,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LineLayer {
    pub points: Vec<(f64, f64)>,
    pub color_rgba: [f32; 4],
}

#[derive(Clone, Debug, PartialEq)]
pub struct HeatmapLayer {
    pub width: usize,
    pub height: usize,
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
    pub time_range: Option<TimeRange>,
    pub layers: Vec<PlotLayer>,
}

pub fn line_scene(series: &Series1D) -> PlotScene {
    let points = series
        .values
        .iter()
        .enumerate()
        .map(|(index, value)| (index as f64, *value))
        .collect();

    PlotScene {
        title: series.channel.display_name.clone(),
        kind: PlotKind::Line1D,
        x_axis: AxisSpec {
            label: "Sample".to_string(),
            unit: None,
            log_scale: false,
        },
        y_axis: AxisSpec {
            label: "Value".to_string(),
            unit: series.channel.unit.clone(),
            log_scale: false,
        },
        z_axis: None,
        time_range: None,
        layers: vec![PlotLayer::Line(LineLayer {
            points,
            color_rgba: [0.10, 0.45, 0.95, 1.0],
        })],
    }
}

pub fn heatmap_scene(grid: &Grid2D) -> PlotScene {
    PlotScene {
        title: grid.channel.display_name.clone(),
        kind: PlotKind::Heatmap2D,
        x_axis: AxisSpec {
            label: "Time".to_string(),
            unit: Some("ns".to_string()),
            log_scale: false,
        },
        y_axis: AxisSpec {
            label: grid.y_label.clone(),
            unit: grid.y_unit.clone(),
            log_scale: false,
        },
        z_axis: None,
        time_range: Some(grid.x_range.clone()),
        layers: vec![PlotLayer::Heatmap(HeatmapLayer {
            width: grid.width,
            height: grid.height,
            values: grid.values.clone(),
        })],
    }
}

pub fn volume_scene(volume: &Volume3D) -> PlotScene {
    PlotScene {
        title: volume.channel.display_name.clone(),
        kind: PlotKind::Volume3D,
        x_axis: AxisSpec {
            label: "X".to_string(),
            unit: None,
            log_scale: false,
        },
        y_axis: AxisSpec {
            label: "Y".to_string(),
            unit: None,
            log_scale: false,
        },
        z_axis: Some(AxisSpec {
            label: "Z".to_string(),
            unit: None,
            log_scale: false,
        }),
        time_range: None,
        layers: vec![PlotLayer::Volume(VolumeLayer {
            x_len: volume.x_len,
            y_len: volume.y_len,
            z_len: volume.z_len,
            values: volume.values.clone(),
        })],
    }
}
