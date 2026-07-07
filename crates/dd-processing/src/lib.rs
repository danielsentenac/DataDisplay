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
pub use error::ProcessingError;
pub use filter::{
    bandpass, butterworth_sos, decimate, filtfilt, highpass, lowpass, resample_linear,
    sos_response, sosfilt, Biquad, FilterKind,
};
pub use spectrogram::{spectrogram, spectrogram_with, SpectrogramParams};
pub use spectrum::{
    cumulative_rms, meta, spectrum_to_db, welch_spectrum, Averaging, SpectrumParams,
    SpectrumScaling,
};
pub use window::Window;

use dd_domain::{Series1D, TimeAxis};

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
