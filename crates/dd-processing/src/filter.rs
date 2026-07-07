//! IIR filtering: Butterworth designs, zero-phase filtering, anti-aliased
//! decimation and linear resampling.

use num_complex::Complex64;

use dd_domain::{Series1D, TimeAxis};

use crate::error::{series_sample_rate_hz, ProcessingError};

/// One second-order section, normalized so `a0 = 1`. First-order sections use
/// `b2 = a2 = 0`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Biquad {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FilterKind {
    LowPass { cutoff_hz: f64 },
    HighPass { cutoff_hz: f64 },
    /// Cascade of a high-pass at `low_hz` and a low-pass at `high_hz`, each of
    /// the requested order (the band-pass idiom of the original's fmin/fmax
    /// pre-filter).
    BandPass { low_hz: f64, high_hz: f64 },
}

/// Butterworth filter as a cascade of second-order sections (bilinear
/// transform with frequency pre-warping; exact digital Butterworth for
/// low-pass and high-pass of any order).
pub fn butterworth_sos(
    order: usize,
    kind: &FilterKind,
    sample_rate_hz: f64,
) -> Result<Vec<Biquad>, ProcessingError> {
    if order == 0 {
        return Err(ProcessingError::InvalidParams(
            "filter order must be at least 1".to_string(),
        ));
    }
    let nyquist = sample_rate_hz / 2.0;
    let check = |frequency: f64, label: &str| -> Result<(), ProcessingError> {
        if frequency <= 0.0 || frequency >= nyquist {
            Err(ProcessingError::InvalidParams(format!(
                "{label} frequency {frequency} Hz must be in (0, {nyquist}) Hz"
            )))
        } else {
            Ok(())
        }
    };

    match kind {
        FilterKind::LowPass { cutoff_hz } => {
            check(*cutoff_hz, "cutoff")?;
            Ok(butterworth_half(order, *cutoff_hz, sample_rate_hz, false))
        }
        FilterKind::HighPass { cutoff_hz } => {
            check(*cutoff_hz, "cutoff")?;
            Ok(butterworth_half(order, *cutoff_hz, sample_rate_hz, true))
        }
        FilterKind::BandPass { low_hz, high_hz } => {
            check(*low_hz, "band low")?;
            check(*high_hz, "band high")?;
            if low_hz >= high_hz {
                return Err(ProcessingError::InvalidParams(format!(
                    "band low {low_hz} Hz must be below band high {high_hz} Hz"
                )));
            }
            let mut sos = butterworth_half(order, *low_hz, sample_rate_hz, true);
            sos.extend(butterworth_half(order, *high_hz, sample_rate_hz, false));
            Ok(sos)
        }
    }
}

/// Butterworth LP/HP of arbitrary order: one biquad per conjugate pole pair
/// with the prototype quality factors `Q_k = 1 / (2 cos θ_k)`, plus a
/// first-order section for odd orders.
fn butterworth_half(order: usize, cutoff_hz: f64, sample_rate_hz: f64, highpass: bool) -> Vec<Biquad> {
    use std::f64::consts::PI;

    let k = (PI * cutoff_hz / sample_rate_hz).tan();
    let mut sos = Vec::with_capacity(order / 2 + order % 2);

    for section in 0..order / 2 {
        let theta = PI * (2 * section + 1) as f64 / (2 * order) as f64;
        let q = 1.0 / (2.0 * theta.cos());
        let norm = 1.0 / (1.0 + k / q + k * k);
        let (b0, b1, b2) = if highpass {
            (norm, -2.0 * norm, norm)
        } else {
            (k * k * norm, 2.0 * k * k * norm, k * k * norm)
        };
        sos.push(Biquad {
            b0,
            b1,
            b2,
            a1: 2.0 * (k * k - 1.0) * norm,
            a2: (1.0 - k / q + k * k) * norm,
        });
    }

    if order % 2 == 1 {
        let norm = 1.0 / (k + 1.0);
        let (b0, b1) = if highpass {
            (norm, -norm)
        } else {
            (k * norm, k * norm)
        };
        sos.push(Biquad {
            b0,
            b1,
            b2: 0.0,
            a1: (k - 1.0) * norm,
            a2: 0.0,
        });
    }

    sos
}

/// Causal filtering through a cascade of sections (direct form II transposed).
pub fn sosfilt(sos: &[Biquad], input: &[f64]) -> Vec<f64> {
    let mut output = input.to_vec();
    for section in sos {
        let mut z1 = 0.0;
        let mut z2 = 0.0;
        for value in output.iter_mut() {
            let x0 = *value;
            let y0 = section.b0 * x0 + z1;
            z1 = section.b1 * x0 - section.a1 * y0 + z2;
            z2 = section.b2 * x0 - section.a2 * y0;
            *value = y0;
        }
    }
    output
}

/// Zero-phase forward-backward filtering with odd-extension edge padding
/// (the original's DyFiltfilt). The magnitude response is applied twice.
pub fn filtfilt(sos: &[Biquad], input: &[f64]) -> Vec<f64> {
    let n = input.len();
    if n < 2 || sos.is_empty() {
        return input.to_vec();
    }

    let padlen = (n - 1).min((6 * sos.len() + 2).max(64));
    let mut extended = Vec::with_capacity(n + 2 * padlen);
    for i in (1..=padlen).rev() {
        extended.push(2.0 * input[0] - input[i]);
    }
    extended.extend_from_slice(input);
    for i in (1..=padlen).rev() {
        extended.push(2.0 * input[n - 1] - input[n - 1 - i]);
    }

    let mut filtered = sosfilt(sos, &extended);
    filtered.reverse();
    let mut filtered = sosfilt(sos, &filtered);
    filtered.reverse();

    filtered[padlen..padlen + n].to_vec()
}

/// Complex frequency response of a section cascade at `frequency_hz`.
pub fn sos_response(sos: &[Biquad], frequency_hz: f64, sample_rate_hz: f64) -> Complex64 {
    let omega = 2.0 * std::f64::consts::PI * frequency_hz / sample_rate_hz;
    let z1 = Complex64::from_polar(1.0, -omega);
    let z2 = z1 * z1;
    sos.iter().fold(Complex64::new(1.0, 0.0), |acc, s| {
        acc * (s.b0 + s.b1 * z1 + s.b2 * z2) / (1.0 + s.a1 * z1 + s.a2 * z2)
    })
}

/// Zero-phase Butterworth band-pass of a series (the per-plot fmin/fmax
/// pre-filter of the original).
pub fn bandpass(
    series: &Series1D,
    low_hz: f64,
    high_hz: f64,
    order: usize,
) -> Result<Series1D, ProcessingError> {
    filter_series(series, order, &FilterKind::BandPass { low_hz, high_hz })
}

pub fn lowpass(
    series: &Series1D,
    cutoff_hz: f64,
    order: usize,
) -> Result<Series1D, ProcessingError> {
    filter_series(series, order, &FilterKind::LowPass { cutoff_hz })
}

pub fn highpass(
    series: &Series1D,
    cutoff_hz: f64,
    order: usize,
) -> Result<Series1D, ProcessingError> {
    filter_series(series, order, &FilterKind::HighPass { cutoff_hz })
}

fn filter_series(
    series: &Series1D,
    order: usize,
    kind: &FilterKind,
) -> Result<Series1D, ProcessingError> {
    if series.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    let sample_rate_hz = series_sample_rate_hz(series)?;
    let sos = butterworth_sos(order, kind, sample_rate_hz)?;

    let mut filtered = series.clone();
    filtered.values = filtfilt(&sos, &series.values);
    filtered.metadata.insert(
        "dd_filter".to_string(),
        match kind {
            FilterKind::LowPass { cutoff_hz } => format!("butterworth_lp({order},{cutoff_hz}Hz)"),
            FilterKind::HighPass { cutoff_hz } => format!("butterworth_hp({order},{cutoff_hz}Hz)"),
            FilterKind::BandPass { low_hz, high_hz } => {
                format!("butterworth_bp({order},{low_hz}-{high_hz}Hz)")
            }
        },
    );
    Ok(filtered)
}

/// Anti-aliased decimation by an integer factor: zero-phase order-8
/// Butterworth low-pass at 80% of the new Nyquist, then sample picking.
pub fn decimate(series: &Series1D, factor: usize) -> Result<Series1D, ProcessingError> {
    if factor <= 1 {
        return Ok(series.clone());
    }
    if series.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    let sample_rate_hz = series_sample_rate_hz(series)?;
    let new_rate_hz = sample_rate_hz / factor as f64;
    let sos = butterworth_sos(
        8,
        &FilterKind::LowPass {
            cutoff_hz: 0.8 * new_rate_hz / 2.0,
        },
        sample_rate_hz,
    )?;

    let filtered = filtfilt(&sos, &series.values);
    let values: Vec<f64> = filtered.iter().copied().step_by(factor).collect();

    let axis = match &series.axis {
        TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            ..
        } => TimeAxis::Regular {
            start_ns: *start_ns,
            sample_period_ns: sample_period_ns.saturating_mul(factor as i64),
            len: values.len(),
        },
        TimeAxis::Irregular { .. } => return Err(ProcessingError::IrregularSampling),
    };

    let mut channel = series.channel.clone();
    if channel.sample_rate_hz.is_some() {
        channel.sample_rate_hz = Some(new_rate_hz);
    }
    let mut metadata = series.metadata.clone();
    metadata.insert("dd_decimated_by".to_string(), factor.to_string());

    Ok(Series1D {
        channel,
        axis,
        values,
        metadata,
    })
}

/// Linear-interpolation resampling to `target_rate_hz`. Intended for
/// up-sampling (e.g. audio); for down-sampling use [`decimate`], which
/// anti-aliases.
pub fn resample_linear(
    series: &Series1D,
    target_rate_hz: f64,
) -> Result<Series1D, ProcessingError> {
    if series.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    if target_rate_hz <= 0.0 {
        return Err(ProcessingError::InvalidParams(format!(
            "target rate {target_rate_hz} Hz must be positive"
        )));
    }
    let source_rate_hz = series_sample_rate_hz(series)?;
    let ratio = source_rate_hz / target_rate_hz;
    let output_len = (((series.len() - 1) as f64 / ratio).floor() as usize) + 1;

    let mut values = Vec::with_capacity(output_len);
    for index in 0..output_len {
        let position = index as f64 * ratio;
        let base = position.floor() as usize;
        let fraction = position - base as f64;
        let value = if base + 1 < series.len() {
            series.values[base] * (1.0 - fraction) + series.values[base + 1] * fraction
        } else {
            series.values[series.len() - 1]
        };
        values.push(value);
    }

    let start_ns = series.axis.first_timestamp_ns().unwrap_or(0);
    let axis = TimeAxis::Regular {
        start_ns,
        sample_period_ns: ((1.0e9 / target_rate_hz).round() as i64).max(1),
        len: values.len(),
    };
    let mut channel = series.channel.clone();
    channel.sample_rate_hz = Some(target_rate_hz);
    let mut metadata = series.metadata.clone();
    metadata.insert(
        "dd_resampled_to_hz".to_string(),
        target_rate_hz.to_string(),
    );

    Ok(Series1D {
        channel,
        axis,
        values,
        metadata,
    })
}
