//! Band-limited RMS trends (the original's BRMSTIME plot).

use dd_domain::{ChannelDescriptor, Series1D, TimeAxis};

use crate::error::{series_sample_rate_hz, ProcessingError};
use crate::segment::{segment_starts, SegmentFft};
use crate::spectrum::meta;
use crate::window::Window;

#[derive(Clone, Debug, PartialEq)]
pub struct BrmsParams {
    pub fmin_hz: f64,
    pub fmax_hz: f64,
    /// FFT length in samples (frequency resolution = rate / segment_len).
    pub segment_len: usize,
    /// Distance between successive FFT starts, in samples (time resolution).
    pub step_len: usize,
    pub window: Window,
    pub remove_dc: bool,
}

impl BrmsParams {
    pub fn new(fmin_hz: f64, fmax_hz: f64, segment_len: usize, step_len: usize) -> Self {
        Self {
            fmin_hz,
            fmax_hz,
            segment_len,
            step_len: step_len.max(1),
            window: Window::Hann,
            remove_dc: false,
        }
    }
}

/// RMS of the signal content in `[fmin_hz, fmax_hz]` versus time: one value
/// per FFT segment, integrating the one-sided PSD over the band. Output
/// timestamps are segment centers.
pub fn brms(series: &Series1D, params: &BrmsParams) -> Result<Series1D, ProcessingError> {
    if series.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    if !(params.fmin_hz >= 0.0 && params.fmax_hz > params.fmin_hz) {
        return Err(ProcessingError::InvalidParams(format!(
            "invalid band [{}, {}] Hz",
            params.fmin_hz, params.fmax_hz
        )));
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
    let step_hz = sample_rate_hz / params.segment_len as f64;
    let bin_min = (params.fmin_hz / step_hz).ceil() as usize;
    let bin_max = ((params.fmax_hz / step_hz).floor() as usize).min(engine.output_len() - 1);
    if bin_min > bin_max {
        return Err(ProcessingError::InvalidParams(format!(
            "band [{}, {}] Hz contains no FFT bin at {step_hz} Hz resolution",
            params.fmin_hz, params.fmax_hz
        )));
    }

    let mut values = Vec::new();
    for start in segment_starts(series.len(), params.segment_len, params.step_len) {
        let psd = engine.psd(
            &series.values[start..start + params.segment_len],
            sample_rate_hz,
        );
        let band_power: f64 = psd[bin_min..=bin_max].iter().sum::<f64>() * step_hz;
        values.push(band_power.sqrt());
    }
    if values.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }

    let start_ns = series.axis.first_timestamp_ns().unwrap_or(0);
    let period_ns = (params.step_len as f64 / sample_rate_hz * 1.0e9).round() as i64;
    let center_offset_ns =
        (params.segment_len as f64 / 2.0 / sample_rate_hz * 1.0e9).round() as i64;
    let axis = TimeAxis::Regular {
        start_ns: start_ns.saturating_add(center_offset_ns),
        sample_period_ns: period_ns.max(1),
        len: values.len(),
    };

    let mut metadata = series.metadata.clone();
    metadata.insert(meta::FMIN_HZ.to_string(), params.fmin_hz.to_string());
    metadata.insert(meta::FMAX_HZ.to_string(), params.fmax_hz.to_string());
    metadata.insert(
        meta::SEGMENT_LEN.to_string(),
        params.segment_len.to_string(),
    );
    metadata.insert(meta::STEP_LEN.to_string(), params.step_len.to_string());
    metadata.insert(meta::WINDOW.to_string(), params.window.name().to_string());
    metadata.insert(meta::KIND.to_string(), "brms".to_string());

    Ok(Series1D {
        channel: ChannelDescriptor {
            id: format!(
                "{}:brms[{}-{}Hz]",
                series.channel.id, params.fmin_hz, params.fmax_hz
            ),
            display_name: format!(
                "{} BRMS {}-{} Hz",
                series.channel.display_name, params.fmin_hz, params.fmax_hz
            ),
            unit: series.channel.unit.clone(),
            sample_rate_hz: Some(sample_rate_hz / params.step_len as f64),
            metadata: series.channel.metadata.clone(),
        },
        axis,
        values,
        metadata,
    })
}
