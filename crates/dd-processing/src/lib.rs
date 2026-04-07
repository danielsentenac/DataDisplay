//! Processing primitives for DATADISPLAY.

use dd_domain::{ChannelDescriptor, Grid2D, Metadata, Series1D, TimeAxis, TimeRange};

pub fn downsample_mean(series: &Series1D, bucket_size: usize) -> Series1D {
    if bucket_size <= 1 || series.values.is_empty() {
        return series.clone();
    }

    let values = series
        .values
        .chunks(bucket_size)
        .map(|chunk| chunk.iter().sum::<f64>() / chunk.len() as f64)
        .collect::<Vec<_>>();

    let axis = match &series.axis {
        TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            ..
        } => TimeAxis::Regular {
            start_ns: *start_ns,
            sample_period_ns: sample_period_ns.saturating_mul(bucket_size as i64),
            len: values.len(),
        },
        TimeAxis::Irregular { timestamps_ns } => TimeAxis::Irregular {
            timestamps_ns: timestamps_ns
                .iter()
                .copied()
                .step_by(bucket_size)
                .take(values.len())
                .collect(),
        },
    };

    Series1D {
        channel: series.channel.clone(),
        axis,
        values,
        metadata: series.metadata.clone(),
    }
}

pub fn moving_rms(series: &Series1D, window_size: usize) -> Series1D {
    if window_size <= 1 || series.values.is_empty() {
        return series.clone();
    }

    let mut values = Vec::with_capacity(series.values.len());
    for index in 0..series.values.len() {
        let start = index.saturating_sub(window_size - 1);
        let window = &series.values[start..=index];
        let rms =
            (window.iter().map(|value| value * value).sum::<f64>() / window.len() as f64).sqrt();
        values.push(rms);
    }

    Series1D {
        channel: series.channel.clone(),
        axis: series.axis.clone(),
        values,
        metadata: series.metadata.clone(),
    }
}

pub fn spectrogram(series: &Series1D, window_size: usize, step_size: usize) -> Grid2D {
    let safe_window = window_size.max(1);
    let safe_step = step_size.max(1);
    let windows = if series.values.len() < safe_window {
        1
    } else {
        1 + (series.values.len() - safe_window) / safe_step
    };

    let bins = (safe_window / 2).max(8);
    let mut values = Vec::with_capacity(windows * bins);

    for window_index in 0..windows {
        let start = window_index * safe_step;
        let end = (start + safe_window).min(series.values.len());
        let slice = &series.values[start..end];
        let energy = if slice.is_empty() {
            0.0
        } else {
            slice.iter().map(|value| value * value).sum::<f64>() / slice.len() as f64
        };

        for bin in 0..bins {
            let taper = 1.0 - (bin as f32 / bins as f32) * 0.7;
            values.push((energy as f32) * taper);
        }
    }

    let time_range = match &series.axis {
        TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            len,
        } => TimeRange::new(
            *start_ns,
            start_ns.saturating_add(sample_period_ns.saturating_mul(*len as i64)),
        ),
        TimeAxis::Irregular { timestamps_ns } => {
            let start_ns = *timestamps_ns.first().unwrap_or(&0);
            let end_ns = *timestamps_ns.last().unwrap_or(&start_ns);
            TimeRange::new(start_ns, end_ns)
        }
    };

    Grid2D {
        channel: ChannelDescriptor {
            id: format!("{}:spectrogram", series.channel.id),
            display_name: format!("{} Spectrogram", series.channel.display_name),
            unit: Some("power".to_string()),
            sample_rate_hz: None,
            metadata: Metadata::new(),
        },
        x_range: time_range,
        y_label: "Frequency".to_string(),
        y_unit: Some("bin".to_string()),
        width: windows,
        height: bins,
        values,
        metadata: Metadata::new(),
    }
}
