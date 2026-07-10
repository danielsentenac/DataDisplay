//! Processing primitives for DATADISPLAY.
//!
//! Frequency-domain analysis follows the semantics of the original
//! dataDisplay/Frv stack: Welch-segmented, window-normalized one-sided
//! spectral densities with mean, median (bias-corrected) or
//! exponential-decay averaging.

mod brms;
mod cross;
mod error;
mod filter;
mod segment;
mod spectrogram;
mod spectrum;
mod window;

pub use brms::{brms, BrmsParams};
pub use cross::{
    coherence, cross_analysis, phase_to_delay, transfer_function, CrossAnalysis, CrossParams,
    TransferFunction,
};
pub use error::{series_sample_rate_hz, ProcessingError};
pub use filter::{
    bandpass, butterworth_sos, decimate, filtfilt, highpass, lowpass, resample_linear,
    sos_response, sosfilt, Biquad, FilterKind,
};
pub use spectrogram::{spectrogram, spectrogram_with, SpectrogramParams};
pub use spectrum::{
    band_slice, cumulative_rms, meta, spectrum_to_db, welch_spectrum, Averaging, SpectrumParams,
    SpectrumScaling,
};
pub use window::Window;

use dd_domain::{SampleAxis, SampledData, Series1D, TimeAxis};

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

/// Min/max envelope: one `[min, max]` pair per bucket, as `SampledData` with
/// sample shape `[2]` (values interleaved `min0, max0, min1, max1, ...`).
pub fn min_max_envelope(series: &Series1D, bucket_size: usize) -> SampledData {
    let bucket_size = bucket_size.max(1);
    let mut values = Vec::with_capacity(2 * series.values.len().div_ceil(bucket_size));
    for chunk in series.values.chunks(bucket_size) {
        let mut low = f64::INFINITY;
        let mut high = f64::NEG_INFINITY;
        for value in chunk {
            low = low.min(*value);
            high = high.max(*value);
        }
        values.push(low);
        values.push(high);
    }
    let buckets = values.len() / 2;

    let axis = match &series.axis {
        TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            ..
        } => TimeAxis::Regular {
            start_ns: *start_ns,
            sample_period_ns: sample_period_ns.saturating_mul(bucket_size as i64),
            len: buckets,
        },
        TimeAxis::Irregular { timestamps_ns } => TimeAxis::Irregular {
            timestamps_ns: timestamps_ns
                .iter()
                .copied()
                .step_by(bucket_size)
                .take(buckets)
                .collect(),
        },
    };

    let mut envelope_axis = SampleAxis::new("envelope", 2);
    envelope_axis.unit = series.channel.unit.clone();
    let mut metadata = series.metadata.clone();
    metadata.insert("dd_kind".to_string(), "min_max_envelope".to_string());

    SampledData {
        channel: series.channel.clone(),
        axis,
        sample_shape: vec![2],
        sample_axes: vec![envelope_axis],
        values,
        metadata,
    }
}

pub fn moving_rms(series: &Series1D, window_size: usize) -> Series1D {
    if window_size <= 1 || series.values.is_empty() {
        return series.clone();
    }

    let mut values = Vec::with_capacity(series.values.len());
    let mut sum_of_squares = 0.0;
    for index in 0..series.values.len() {
        let sample = series.values[index];
        sum_of_squares += sample * sample;
        if index >= window_size {
            let leaving = series.values[index - window_size];
            sum_of_squares -= leaving * leaving;
        }
        let count = (index + 1).min(window_size);
        values.push((sum_of_squares.max(0.0) / count as f64).sqrt());
    }

    Series1D {
        channel: series.channel.clone(),
        axis: series.axis.clone(),
        values,
        metadata: series.metadata.clone(),
    }
}
