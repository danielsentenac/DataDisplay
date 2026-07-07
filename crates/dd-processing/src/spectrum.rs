//! Welch-style averaged spectra.

use dd_domain::{ChannelDescriptor, FrequencyAxis, Metadata, Series1D, Spectrum, TimeRange};

use crate::error::{series_sample_rate_hz, ProcessingError};
use crate::segment::{median_bias, segment_starts, step_from_overlap, Accumulator, SegmentFft};
use crate::window::Window;

/// Metadata keys attached to processing results.
pub mod meta {
    pub const SEGMENTS: &str = "dd_segments";
    pub const SEGMENT_LEN: &str = "dd_segment_len";
    pub const STEP_LEN: &str = "dd_step_len";
    pub const WINDOW: &str = "dd_window";
    pub const OVERLAP: &str = "dd_overlap";
    pub const AVERAGING: &str = "dd_averaging";
    pub const SCALING: &str = "dd_scaling";
    pub const REMOVE_DC: &str = "dd_remove_dc";
    pub const KIND: &str = "dd_kind";
    pub const Y_ORIGIN_HZ: &str = "dd_y_origin_hz";
    pub const Y_STEP_HZ: &str = "dd_y_step_hz";
    pub const FMIN_HZ: &str = "dd_fmin_hz";
    pub const FMAX_HZ: &str = "dd_fmax_hz";
}

/// How per-segment spectra are combined, mirroring the original dataDisplay
/// (Frv) modes: fixed-count mean, glitch-robust median, and the running
/// exponential-decay average used for endless online streams.
#[derive(Clone, Debug, PartialEq)]
pub enum Averaging {
    Mean { max_segments: Option<usize> },
    Median,
    ExponentialDecay { effective_count: f64 },
}

impl Averaging {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Mean { .. } => "mean",
            Self::Median => "median",
            Self::ExponentialDecay { .. } => "exponential_decay",
        }
    }
}

/// `PowerDensity` is `1/Hz`; `AmplitudeDensity` is its square root, `1/√Hz`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpectrumScaling {
    PowerDensity,
    AmplitudeDensity,
}

impl SpectrumScaling {
    pub fn name(&self) -> &'static str {
        match self {
            Self::PowerDensity => "power_density",
            Self::AmplitudeDensity => "amplitude_density",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpectrumParams {
    pub segment_len: usize,
    /// Fractional segment overlap in `[0, 1)`.
    pub overlap: f64,
    pub window: Window,
    pub averaging: Averaging,
    /// Remove each segment's mean before windowing (the original's "noDC").
    pub remove_dc: bool,
    pub scaling: SpectrumScaling,
}

impl SpectrumParams {
    pub fn new(segment_len: usize) -> Self {
        Self {
            segment_len,
            overlap: 0.5,
            window: Window::Hann,
            averaging: Averaging::Mean { max_segments: None },
            remove_dc: false,
            scaling: SpectrumScaling::PowerDensity,
        }
    }
}

/// Averaged one-sided spectral density of a regularly sampled series.
pub fn welch_spectrum(
    series: &Series1D,
    params: &SpectrumParams,
) -> Result<Spectrum, ProcessingError> {
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
    let step = step_from_overlap(params.segment_len, params.overlap);
    let mut accumulator = Accumulator::new(&params.averaging, engine.output_len());
    let mut last_start = 0usize;

    for start in segment_starts(series.len(), params.segment_len, step) {
        if accumulator.is_full() {
            break;
        }
        last_start = start;
        let segment = &series.values[start..start + params.segment_len];
        accumulator.push(engine.psd(segment, sample_rate_hz));
    }

    let (mut values, segments) = accumulator
        .finish()
        .ok_or(ProcessingError::EmptyInput)?;

    if matches!(params.averaging, Averaging::Median) {
        let bias = median_bias(segments);
        for value in values.iter_mut() {
            *value /= bias;
        }
    }

    if params.scaling == SpectrumScaling::AmplitudeDensity {
        for value in values.iter_mut() {
            *value = value.max(0.0).sqrt();
        }
    }

    let axis = FrequencyAxis::new(0.0, sample_rate_hz / params.segment_len as f64, values.len());
    let time_range = used_time_range(series, last_start + params.segment_len, sample_rate_hz);
    let channel = derived_channel(&series.channel, params.scaling);
    let metadata = spectrum_metadata(series, params, step, segments);

    Ok(Spectrum {
        channel,
        time_range,
        axis,
        values,
        metadata,
    })
}

/// Restrict a spectrum to the `[fmin_hz, fmax_hz]` band (the original's
/// per-plot frequency zoom). Returns an empty spectrum when the band does not
/// overlap the axis.
pub fn band_slice(spectrum: &Spectrum, fmin_hz: f64, fmax_hz: f64) -> Spectrum {
    let axis = &spectrum.axis;
    let mut sliced = spectrum.clone();
    if axis.len == 0 || axis.step_hz <= 0.0 || fmax_hz < fmin_hz {
        sliced.axis = FrequencyAxis::new(fmin_hz.max(axis.start_hz), axis.step_hz, 0);
        sliced.values = Vec::new();
        return sliced;
    }

    let first = ((fmin_hz - axis.start_hz) / axis.step_hz).ceil().max(0.0) as usize;
    let last_in_band = ((fmax_hz - axis.start_hz) / axis.step_hz).floor();
    if last_in_band < first as f64 {
        sliced.axis = FrequencyAxis::new(axis.frequency_hz(first.min(axis.len)), axis.step_hz, 0);
        sliced.values = Vec::new();
        return sliced;
    }
    let last = (last_in_band as usize).min(axis.len - 1);

    sliced.axis = FrequencyAxis::new(axis.frequency_hz(first), axis.step_hz, last + 1 - first);
    sliced.values = spectrum.values[first..=last].to_vec();
    sliced
        .metadata
        .insert(meta::FMIN_HZ.to_string(), fmin_hz.to_string());
    sliced
        .metadata
        .insert(meta::FMAX_HZ.to_string(), fmax_hz.to_string());
    sliced
}

/// Cumulative RMS curve of a spectral density: at each frequency, the RMS
/// contributed by all bins integrated from one end up to that frequency (the
/// curve dataDisplay superposes on spectra). `descending` integrates from the
/// highest frequency downwards.
pub fn cumulative_rms(spectrum: &Spectrum, descending: bool) -> Spectrum {
    let is_amplitude = spectrum
        .metadata
        .get(meta::SCALING)
        .map(|scaling| scaling == SpectrumScaling::AmplitudeDensity.name())
        .unwrap_or(false);
    let step_hz = spectrum.axis.step_hz;

    let power_of = |value: f64| if is_amplitude { value * value } else { value };
    let mut values = vec![0.0; spectrum.values.len()];
    let mut total = 0.0;
    let indices: Vec<usize> = if descending {
        (0..spectrum.values.len()).rev().collect()
    } else {
        (0..spectrum.values.len()).collect()
    };
    for index in indices {
        total += power_of(spectrum.values[index]) * step_hz;
        values[index] = total.sqrt();
    }

    let mut channel = spectrum.channel.clone();
    channel.id = format!("{}:rms", channel.id);
    channel.display_name = format!("{} RMS", channel.display_name);
    channel.unit = spectrum
        .channel
        .unit
        .as_ref()
        .map(|unit| base_unit(unit).to_string());

    let mut metadata = spectrum.metadata.clone();
    metadata.insert(meta::KIND.to_string(), "cumulative_rms".to_string());

    Spectrum {
        channel,
        time_range: spectrum.time_range.clone(),
        axis: spectrum.axis.clone(),
        values,
        metadata,
    }
}

/// Convert a spectral density to decibels: `10·log10` for power densities,
/// `20·log10` for amplitude densities (per the `dd_scaling` metadata).
/// Non-positive values become NaN.
pub fn spectrum_to_db(spectrum: &Spectrum) -> Spectrum {
    let is_amplitude = spectrum
        .metadata
        .get(meta::SCALING)
        .map(|scaling| scaling == SpectrumScaling::AmplitudeDensity.name())
        .unwrap_or(false);
    let factor = if is_amplitude { 20.0 } else { 10.0 };

    let values = spectrum
        .values
        .iter()
        .map(|value| {
            if *value > 0.0 {
                factor * value.log10()
            } else {
                f64::NAN
            }
        })
        .collect();

    let mut channel = spectrum.channel.clone();
    channel.unit = Some("dB".to_string());
    let mut metadata = spectrum.metadata.clone();
    metadata.insert("dd_db".to_string(), "true".to_string());

    Spectrum {
        channel,
        time_range: spectrum.time_range.clone(),
        axis: spectrum.axis.clone(),
        values,
        metadata,
    }
}

pub(crate) fn used_time_range(
    series: &Series1D,
    used_samples: usize,
    sample_rate_hz: f64,
) -> TimeRange {
    let start_ns = series.axis.first_timestamp_ns().unwrap_or(0);
    let duration_ns = (used_samples as f64 / sample_rate_hz * 1.0e9).round() as i64;
    TimeRange::new(start_ns, start_ns.saturating_add(duration_ns))
}

pub(crate) fn spectrum_metadata(
    series: &Series1D,
    params: &SpectrumParams,
    step: usize,
    segments: usize,
) -> Metadata {
    let mut metadata = series.metadata.clone();
    metadata.insert(meta::SEGMENTS.to_string(), segments.to_string());
    metadata.insert(
        meta::SEGMENT_LEN.to_string(),
        params.segment_len.to_string(),
    );
    metadata.insert(meta::STEP_LEN.to_string(), step.to_string());
    metadata.insert(meta::WINDOW.to_string(), params.window.name().to_string());
    metadata.insert(meta::OVERLAP.to_string(), params.overlap.to_string());
    metadata.insert(
        meta::AVERAGING.to_string(),
        params.averaging.name().to_string(),
    );
    metadata.insert(meta::SCALING.to_string(), params.scaling.name().to_string());
    metadata.insert(meta::REMOVE_DC.to_string(), params.remove_dc.to_string());
    metadata
}

fn derived_channel(channel: &ChannelDescriptor, scaling: SpectrumScaling) -> ChannelDescriptor {
    let (suffix, label) = match scaling {
        SpectrumScaling::PowerDensity => ("psd", "PSD"),
        SpectrumScaling::AmplitudeDensity => ("asd", "ASD"),
    };
    let unit = match (&channel.unit, scaling) {
        (Some(unit), SpectrumScaling::PowerDensity) => format!("({unit})^2/Hz"),
        (Some(unit), SpectrumScaling::AmplitudeDensity) => format!("{unit}/sqrt(Hz)"),
        (None, SpectrumScaling::PowerDensity) => "1/Hz".to_string(),
        (None, SpectrumScaling::AmplitudeDensity) => "1/sqrt(Hz)".to_string(),
    };
    ChannelDescriptor {
        id: format!("{}:{suffix}", channel.id),
        display_name: format!("{} {label}", channel.display_name),
        unit: Some(unit),
        sample_rate_hz: None,
        metadata: channel.metadata.clone(),
    }
}

fn base_unit(unit: &str) -> &str {
    unit.strip_suffix("/sqrt(Hz)")
        .or_else(|| {
            unit.strip_suffix("^2/Hz")
                .map(|stripped| stripped.trim_start_matches('(').trim_end_matches(')'))
        })
        .unwrap_or(unit)
}
