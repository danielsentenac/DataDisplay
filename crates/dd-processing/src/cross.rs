//! Averaged cross-spectral estimates: coherence and transfer function.

use dd_domain::{ChannelDescriptor, FrequencyAxis, Series1D, Spectrum};

use crate::error::{series_sample_rate_hz, ProcessingError};
use crate::segment::{segment_starts, step_from_overlap, Accumulator, SegmentFft};
use crate::spectrum::{meta, used_time_range, Averaging};
use crate::window::Window;

#[derive(Clone, Debug, PartialEq)]
pub struct CrossParams {
    pub segment_len: usize,
    /// Fractional segment overlap in `[0, 1)`.
    pub overlap: f64,
    pub window: Window,
    pub averaging: Averaging,
    pub remove_dc: bool,
}

impl CrossParams {
    pub fn new(segment_len: usize) -> Self {
        Self {
            segment_len,
            overlap: 0.5,
            window: Window::Hann,
            averaging: Averaging::Mean { max_segments: None },
            remove_dc: false,
        }
    }
}

/// Transfer function from `a` to `b`: `H = P_ab / P_aa` (H1 estimator).
/// Positive delay of `b` relative to `a` shows as negative phase slope.
#[derive(Clone, Debug, PartialEq)]
pub struct TransferFunction {
    pub module: Spectrum,
    pub phase_rad: Spectrum,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CrossAnalysis {
    pub coherence: Spectrum,
    pub transfer: TransferFunction,
    pub segments: usize,
}

/// Coherence and transfer function between two series in one pass over the
/// segments. With a single segment the coherence is identically 1 (degenerate
/// estimator) — use several averages for a meaningful value.
pub fn cross_analysis(
    a: &Series1D,
    b: &Series1D,
    params: &CrossParams,
) -> Result<CrossAnalysis, ProcessingError> {
    if a.is_empty() || b.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    let rate_a = series_sample_rate_hz(a)?;
    let rate_b = series_sample_rate_hz(b)?;
    if ((rate_a - rate_b) / rate_a).abs() > 1e-6 {
        return Err(ProcessingError::MismatchedInputs(format!(
            "sample rates differ: {rate_a} Hz vs {rate_b} Hz (resample first)"
        )));
    }

    let total_len = a.len().min(b.len());
    if total_len < params.segment_len {
        return Err(ProcessingError::InvalidParams(format!(
            "series overlap of {total_len} samples is shorter than one segment of {}",
            params.segment_len
        )));
    }

    let mut engine_a = SegmentFft::new(params.segment_len, params.window, params.remove_dc)?;
    let mut engine_b = SegmentFft::new(params.segment_len, params.window, params.remove_dc)?;
    let bins = engine_a.output_len();
    let step = step_from_overlap(params.segment_len, params.overlap);

    // Median averaging is applied component-wise (P_aa, P_bb, Re/Im of P_ab);
    // any bias factor cancels in the coherence and transfer-function ratios.
    let mut acc_aa = Accumulator::new(&params.averaging, bins);
    let mut acc_bb = Accumulator::new(&params.averaging, bins);
    let mut acc_ab_re = Accumulator::new(&params.averaging, bins);
    let mut acc_ab_im = Accumulator::new(&params.averaging, bins);
    let mut last_start = 0usize;

    for start in segment_starts(total_len, params.segment_len, step) {
        if acc_aa.is_full() {
            break;
        }
        last_start = start;
        let spec_a = engine_a.transform(&a.values[start..start + params.segment_len]);
        let spec_b = engine_b.transform(&b.values[start..start + params.segment_len]);

        let mut p_aa = Vec::with_capacity(bins);
        let mut p_bb = Vec::with_capacity(bins);
        let mut p_ab_re = Vec::with_capacity(bins);
        let mut p_ab_im = Vec::with_capacity(bins);
        for (va, vb) in spec_a.iter().zip(spec_b.iter()) {
            let cross = va.conj() * vb;
            p_aa.push(va.norm_sqr());
            p_bb.push(vb.norm_sqr());
            p_ab_re.push(cross.re);
            p_ab_im.push(cross.im);
        }
        acc_aa.push(p_aa);
        acc_bb.push(p_bb);
        acc_ab_re.push(p_ab_re);
        acc_ab_im.push(p_ab_im);
    }

    let (p_aa, segments) = acc_aa.finish().ok_or(ProcessingError::EmptyInput)?;
    let (p_bb, _) = acc_bb.finish().ok_or(ProcessingError::EmptyInput)?;
    let (p_ab_re, _) = acc_ab_re.finish().ok_or(ProcessingError::EmptyInput)?;
    let (p_ab_im, _) = acc_ab_im.finish().ok_or(ProcessingError::EmptyInput)?;

    let mut coherence = Vec::with_capacity(bins);
    let mut tf_module = Vec::with_capacity(bins);
    let mut tf_phase = Vec::with_capacity(bins);
    for bin in 0..bins {
        let cross_power = p_ab_re[bin] * p_ab_re[bin] + p_ab_im[bin] * p_ab_im[bin];
        let denominator = p_aa[bin] * p_bb[bin];
        coherence.push(if denominator > 0.0 {
            (cross_power / denominator).clamp(0.0, 1.0)
        } else {
            0.0
        });
        if p_aa[bin] > 0.0 {
            tf_module.push(cross_power.sqrt() / p_aa[bin]);
            tf_phase.push(p_ab_im[bin].atan2(p_ab_re[bin]));
        } else {
            tf_module.push(0.0);
            tf_phase.push(0.0);
        }
    }

    let axis = FrequencyAxis::new(0.0, rate_a / params.segment_len as f64, bins);
    let time_range = used_time_range(a, last_start + params.segment_len, rate_a);
    let mut base_metadata = a.metadata.clone();
    base_metadata.insert(meta::SEGMENTS.to_string(), segments.to_string());
    base_metadata.insert(
        meta::SEGMENT_LEN.to_string(),
        params.segment_len.to_string(),
    );
    base_metadata.insert(meta::STEP_LEN.to_string(), step.to_string());
    base_metadata.insert(meta::WINDOW.to_string(), params.window.name().to_string());
    base_metadata.insert(meta::OVERLAP.to_string(), params.overlap.to_string());
    base_metadata.insert(
        meta::AVERAGING.to_string(),
        params.averaging.name().to_string(),
    );
    base_metadata.insert(meta::REMOVE_DC.to_string(), params.remove_dc.to_string());

    let make = |kind: &str, unit: Option<String>, values: Vec<f64>| -> Spectrum {
        let mut metadata = base_metadata.clone();
        metadata.insert(meta::KIND.to_string(), kind.to_string());
        Spectrum {
            channel: pair_channel(&a.channel, &b.channel, kind, unit),
            time_range: time_range.clone(),
            axis: axis.clone(),
            values,
            metadata,
        }
    };

    let ratio_unit = match (&a.channel.unit, &b.channel.unit) {
        (Some(ua), Some(ub)) if ua != ub => Some(format!("{ub}/{ua}")),
        _ => None,
    };

    Ok(CrossAnalysis {
        coherence: make("coherence", None, coherence),
        transfer: TransferFunction {
            module: make("tf_module", ratio_unit, tf_module),
            phase_rad: make("tf_phase", Some("rad".to_string()), tf_phase),
        },
        segments,
    })
}

pub fn coherence(
    a: &Series1D,
    b: &Series1D,
    params: &CrossParams,
) -> Result<Spectrum, ProcessingError> {
    Ok(cross_analysis(a, b, params)?.coherence)
}

pub fn transfer_function(
    a: &Series1D,
    b: &Series1D,
    params: &CrossParams,
) -> Result<TransferFunction, ProcessingError> {
    Ok(cross_analysis(a, b, params)?.transfer)
}

/// Group delay reading of a transfer-function phase: `delay = -phase / (2πf)`,
/// in seconds; positive when the second channel lags the first. The DC bin is 0.
pub fn phase_to_delay(phase: &Spectrum) -> Spectrum {
    let values = phase
        .values
        .iter()
        .enumerate()
        .map(|(bin, value)| {
            let frequency = phase.axis.frequency_hz(bin);
            if frequency > 0.0 {
                -value / (2.0 * std::f64::consts::PI * frequency)
            } else {
                0.0
            }
        })
        .collect();

    let mut channel = phase.channel.clone();
    channel.id = channel.id.replace(":tf_phase", ":tf_delay");
    channel.display_name = channel.display_name.replace("phase", "delay");
    channel.unit = Some("s".to_string());
    let mut metadata = phase.metadata.clone();
    metadata.insert(meta::KIND.to_string(), "tf_delay".to_string());

    Spectrum {
        channel,
        time_range: phase.time_range.clone(),
        axis: phase.axis.clone(),
        values,
        metadata,
    }
}

fn pair_channel(
    a: &ChannelDescriptor,
    b: &ChannelDescriptor,
    kind: &str,
    unit: Option<String>,
) -> ChannelDescriptor {
    let label = match kind {
        "coherence" => "Coherence",
        "tf_module" => "TF module",
        "tf_phase" => "TF phase",
        other => other,
    };
    ChannelDescriptor {
        id: format!("{}~{}:{kind}", a.id, b.id),
        display_name: format!("{label} {} / {}", a.display_name, b.display_name),
        unit,
        sample_rate_hz: None,
        metadata: dd_domain::Metadata::new(),
    }
}
