//! Time-frequency maps (the original's FFTTIME plot).

use dd_domain::{ChannelDescriptor, Grid2D, Metadata, Series1D, TimeAxis, TimeRange};

use crate::error::{series_sample_rate_hz, ProcessingError};
use crate::segment::{segment_starts, SegmentFft};
use crate::spectrum::{meta, SpectrumScaling};
use crate::window::Window;

#[derive(Clone, Debug, PartialEq)]
pub struct SpectrogramParams {
    pub segment_len: usize,
    /// Distance between successive FFT starts, in samples.
    pub step_len: usize,
    pub window: Window,
    pub remove_dc: bool,
    pub scaling: SpectrumScaling,
    /// Number of consecutive FFTs mean-averaged into each time column
    /// (the original's independent time vs frequency resolution). 1 = none.
    pub averages_per_column: usize,
    /// Divide each frequency row by its median over time (the original's
    /// "medY" normalization, which flattens stationary lines).
    pub median_normalize_rows: bool,
}

impl SpectrogramParams {
    pub fn new(segment_len: usize, step_len: usize) -> Self {
        Self {
            segment_len,
            step_len: step_len.max(1),
            window: Window::Hann,
            remove_dc: false,
            scaling: SpectrumScaling::PowerDensity,
            averages_per_column: 1,
            median_normalize_rows: false,
        }
    }
}

/// Spectrogram of a regularly sampled series. The grid is stored column-major
/// (all frequency bins of the first time column, then the second, ...), with
/// `width` time columns and `height = segment_len/2 + 1` frequency rows;
/// row frequencies are `dd_y_origin_hz + row * dd_y_step_hz` (metadata keys).
pub fn spectrogram_with(
    series: &Series1D,
    params: &SpectrogramParams,
) -> Result<Grid2D, ProcessingError> {
    if series.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    let sample_rate_hz = series_sample_rate_hz(series)?;
    if series.len() < params.segment_len {
        return Err(ProcessingError::InvalidParams(format!(
            "series has {} samples, shorter than one segment of {}",
            series.len(),
            params.segment_len
        )));
    }

    let mut engine = SegmentFft::new(params.segment_len, params.window, params.remove_dc)?;
    let bins = engine.output_len();
    let group = params.averages_per_column.max(1);

    let starts: Vec<usize> =
        segment_starts(series.len(), params.segment_len, params.step_len.max(1)).collect();
    let columns = starts.len() / group + usize::from(!starts.len().is_multiple_of(group));
    let mut values: Vec<f32> = Vec::with_capacity(columns * bins);

    for chunk in starts.chunks(group) {
        let mut column = vec![0.0f64; bins];
        for start in chunk {
            let psd = engine.psd(
                &series.values[*start..*start + params.segment_len],
                sample_rate_hz,
            );
            for (slot, value) in column.iter_mut().zip(psd.iter()) {
                *slot += value;
            }
        }
        let scale = 1.0 / chunk.len() as f64;
        for value in column {
            let averaged = value * scale;
            let scaled = match params.scaling {
                SpectrumScaling::PowerDensity => averaged,
                SpectrumScaling::AmplitudeDensity => averaged.max(0.0).sqrt(),
            };
            values.push(scaled as f32);
        }
    }

    if params.median_normalize_rows {
        normalize_rows_by_median(&mut values, columns, bins);
    }

    let used_samples = starts.last().map(|s| s + params.segment_len).unwrap_or(0);
    let start_ns = series.axis.first_timestamp_ns().unwrap_or(0);
    let duration_ns = (used_samples as f64 / sample_rate_hz * 1.0e9).round() as i64;
    let step_hz = sample_rate_hz / params.segment_len as f64;

    let mut metadata: Metadata = series.metadata.clone();
    metadata.insert(meta::Y_ORIGIN_HZ.to_string(), "0".to_string());
    metadata.insert(meta::Y_STEP_HZ.to_string(), step_hz.to_string());
    metadata.insert(
        meta::SEGMENT_LEN.to_string(),
        params.segment_len.to_string(),
    );
    metadata.insert(meta::STEP_LEN.to_string(), params.step_len.to_string());
    metadata.insert(meta::WINDOW.to_string(), params.window.name().to_string());
    metadata.insert(meta::SCALING.to_string(), params.scaling.name().to_string());
    metadata.insert(meta::SEGMENTS.to_string(), group.to_string());
    metadata.insert(
        "dd_median_normalized".to_string(),
        params.median_normalize_rows.to_string(),
    );

    Ok(Grid2D {
        channel: ChannelDescriptor {
            id: format!("{}:spectrogram", series.channel.id),
            display_name: format!("{} Spectrogram", series.channel.display_name),
            unit: Some(match params.scaling {
                SpectrumScaling::PowerDensity => "1/Hz".to_string(),
                SpectrumScaling::AmplitudeDensity => "1/sqrt(Hz)".to_string(),
            }),
            sample_rate_hz: None,
            metadata: Metadata::new(),
        },
        x_range: TimeRange::new(start_ns, start_ns.saturating_add(duration_ns)),
        y_label: "Frequency".to_string(),
        y_unit: Some("Hz".to_string()),
        width: columns,
        height: bins,
        values,
        metadata,
    })
}

/// Legacy convenience wrapper kept for existing callers: Hann window, power
/// density, no averaging. Falls back to a unit sample rate (bin frequencies in
/// cycles/sample) when the rate is unknown, and clamps the window to the
/// series length, so it never fails.
pub fn spectrogram(series: &Series1D, window_size: usize, step_size: usize) -> Grid2D {
    if series.is_empty() {
        return empty_grid(series);
    }

    let segment_len = window_size.clamp(2, series.len().max(2));
    let params = SpectrogramParams::new(segment_len, step_size.max(1));

    match spectrogram_with(series, &params) {
        Ok(grid) => grid,
        Err(_) => {
            // Unknown/irregular sampling: retry against a synthetic unit-rate view.
            let mut fallback = series.clone();
            fallback.axis = TimeAxis::Regular {
                start_ns: series.axis.first_timestamp_ns().unwrap_or(0),
                sample_period_ns: 1_000_000_000,
                len: series.values.len(),
            };
            fallback.channel.sample_rate_hz = Some(1.0);
            spectrogram_with(&fallback, &params).unwrap_or_else(|_| empty_grid(series))
        }
    }
}

fn empty_grid(series: &Series1D) -> Grid2D {
    Grid2D {
        channel: ChannelDescriptor {
            id: format!("{}:spectrogram", series.channel.id),
            display_name: format!("{} Spectrogram", series.channel.display_name),
            unit: Some("1/Hz".to_string()),
            sample_rate_hz: None,
            metadata: Metadata::new(),
        },
        x_range: TimeRange::new(0, 0),
        y_label: "Frequency".to_string(),
        y_unit: Some("Hz".to_string()),
        width: 0,
        height: 0,
        values: Vec::new(),
        metadata: Metadata::new(),
    }
}

fn normalize_rows_by_median(values: &mut [f32], columns: usize, bins: usize) {
    let mut row = vec![0.0f32; columns];
    for bin in 0..bins {
        for (slot, column) in row.iter_mut().zip(0..columns) {
            *slot = values[column * bins + bin];
        }
        row.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let median = if columns == 0 {
            0.0
        } else if columns % 2 == 1 {
            row[columns / 2]
        } else {
            0.5 * (row[columns / 2 - 1] + row[columns / 2])
        };
        if median > 0.0 {
            for column in 0..columns {
                values[column * bins + bin] /= median;
            }
        }
    }
}
