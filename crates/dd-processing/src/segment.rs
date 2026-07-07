//! Shared segmented-FFT machinery used by spectra, cross-spectra,
//! spectrograms and BRMS.

use std::sync::Arc;

use num_complex::Complex64;
use realfft::{RealFftPlanner, RealToComplex};

use crate::error::ProcessingError;
use crate::spectrum::Averaging;
use crate::window::Window;

pub(crate) struct SegmentFft {
    fft: Arc<dyn RealToComplex<f64>>,
    window: Vec<f64>,
    window_power: f64,
    remove_dc: bool,
    input: Vec<f64>,
}

impl SegmentFft {
    pub fn new(
        segment_len: usize,
        window: Window,
        remove_dc: bool,
    ) -> Result<Self, ProcessingError> {
        if segment_len < 2 {
            return Err(ProcessingError::InvalidParams(
                "segment length must be at least 2 samples".to_string(),
            ));
        }

        let coefficients = window.coefficients(segment_len);
        let window_power = coefficients.iter().map(|w| w * w).sum();
        let fft = RealFftPlanner::<f64>::new().plan_fft_forward(segment_len);

        Ok(Self {
            fft,
            window: coefficients,
            window_power,
            remove_dc,
            input: vec![0.0; segment_len],
        })
    }

    pub fn output_len(&self) -> usize {
        self.window.len() / 2 + 1
    }

    /// Complex one-sided FFT of one windowed (and optionally de-meaned) segment.
    pub fn transform(&mut self, samples: &[f64]) -> Vec<Complex64> {
        debug_assert_eq!(samples.len(), self.window.len());

        let mean = if self.remove_dc {
            samples.iter().sum::<f64>() / samples.len() as f64
        } else {
            0.0
        };

        for (slot, (sample, coeff)) in self
            .input
            .iter_mut()
            .zip(samples.iter().zip(self.window.iter()))
        {
            *slot = (sample - mean) * coeff;
        }

        let mut output = self.fft.make_output_vec();
        self.fft
            .process(&mut self.input, &mut output)
            .expect("buffer sizes are fixed by construction");
        output
    }

    /// One-sided power spectral density (`1/Hz`) of one segment, normalized by
    /// the window power so broadband levels are unbiased. DC and (for even
    /// lengths) Nyquist bins are not doubled.
    pub fn psd(&mut self, samples: &[f64], sample_rate_hz: f64) -> Vec<f64> {
        let spectrum = self.transform(samples);
        self.normalize_psd(&spectrum, sample_rate_hz)
    }

    fn normalize_psd(&self, spectrum: &[Complex64], sample_rate_hz: f64) -> Vec<f64> {
        let norm = 1.0 / (sample_rate_hz * self.window_power);
        let last = spectrum.len() - 1;
        let even_len = self.window.len().is_multiple_of(2);
        spectrum
            .iter()
            .enumerate()
            .map(|(bin, value)| {
                let one_sided = if bin == 0 || (even_len && bin == last) {
                    1.0
                } else {
                    2.0
                };
                value.norm_sqr() * norm * one_sided
            })
            .collect()
    }
}

/// Segment step (in samples) for a fractional overlap in `[0, 1)`.
pub(crate) fn step_from_overlap(segment_len: usize, overlap: f64) -> usize {
    let step = ((1.0 - overlap.clamp(0.0, 0.99)) * segment_len as f64).round() as usize;
    step.max(1)
}

/// Start offsets of every full segment of `segment_len` samples.
pub(crate) fn segment_starts(
    total_len: usize,
    segment_len: usize,
    step: usize,
) -> impl Iterator<Item = usize> {
    let count = if total_len < segment_len {
        0
    } else {
        1 + (total_len - segment_len) / step.max(1)
    };
    (0..count).map(move |index| index * step.max(1))
}

/// Bin-wise averaging accumulator over per-segment spectra.
pub(crate) enum Accumulator {
    Mean {
        sum: Vec<f64>,
        count: usize,
        max_segments: Option<usize>,
    },
    Median {
        rows: Vec<Vec<f64>>,
    },
    Decay {
        current: Option<Vec<f64>>,
        alpha: f64,
        count: usize,
    },
}

impl Accumulator {
    pub fn new(averaging: &Averaging, bins: usize) -> Self {
        match averaging {
            Averaging::Mean { max_segments } => Self::Mean {
                sum: vec![0.0; bins],
                count: 0,
                max_segments: *max_segments,
            },
            Averaging::Median => Self::Median { rows: Vec::new() },
            Averaging::ExponentialDecay { effective_count } => Self::Decay {
                current: None,
                alpha: 1.0 - 1.0 / effective_count.max(1.0),
                count: 0,
            },
        }
    }

    pub fn is_full(&self) -> bool {
        match self {
            Self::Mean {
                count,
                max_segments: Some(max),
                ..
            } => count >= max,
            _ => false,
        }
    }

    pub fn push(&mut self, row: Vec<f64>) {
        if self.is_full() {
            return;
        }
        match self {
            Self::Mean { sum, count, .. } => {
                for (total, value) in sum.iter_mut().zip(row.iter()) {
                    *total += value;
                }
                *count += 1;
            }
            Self::Median { rows } => rows.push(row),
            Self::Decay {
                current,
                alpha,
                count,
            } => {
                match current {
                    Some(state) => {
                        for (slot, value) in state.iter_mut().zip(row.iter()) {
                            *slot = *alpha * *slot + (1.0 - *alpha) * value;
                        }
                    }
                    None => *current = Some(row),
                }
                *count += 1;
            }
        }
    }

    /// Averaged spectrum and the number of segments folded in. `None` when no
    /// segment was pushed.
    pub fn finish(self) -> Option<(Vec<f64>, usize)> {
        match self {
            Self::Mean { sum, count, .. } => {
                if count == 0 {
                    None
                } else {
                    let values = sum.into_iter().map(|total| total / count as f64).collect();
                    Some((values, count))
                }
            }
            Self::Median { rows } => {
                if rows.is_empty() {
                    return None;
                }
                let count = rows.len();
                let bins = rows[0].len();
                let mut values = Vec::with_capacity(bins);
                let mut column = vec![0.0; count];
                for bin in 0..bins {
                    for (slot, row) in column.iter_mut().zip(rows.iter()) {
                        *slot = row[bin];
                    }
                    values.push(median_in_place(&mut column));
                }
                Some((values, count))
            }
            Self::Decay { current, count, .. } => current.map(|values| (values, count)),
        }
    }
}

fn median_in_place(values: &mut [f64]) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = values.len() / 2;
    if values.len() % 2 == 1 {
        values[mid]
    } else {
        0.5 * (values[mid - 1] + values[mid])
    }
}

/// Expected ratio `E[median]/E[mean]` of `count` independent exponentially
/// distributed samples (the statistics of averaged periodogram bins for
/// Gaussian noise). Dividing a median-averaged PSD by this factor makes it an
/// unbiased estimate of the mean PSD while staying robust to glitches.
pub(crate) fn median_bias(count: usize) -> f64 {
    if count <= 1 {
        return 1.0;
    }
    let harmonic = |n: usize| -> f64 { (1..=n).map(|i| 1.0 / i as f64).sum() };
    if count % 2 == 1 {
        harmonic(count) - harmonic(count / 2)
    } else {
        let half = count / 2;
        harmonic(count) - 0.5 * (harmonic(half) + harmonic(half - 1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segment_starts_counts_full_windows() {
        let starts: Vec<usize> = segment_starts(10, 4, 2).collect();
        assert_eq!(starts, vec![0, 2, 4, 6]);
        assert_eq!(segment_starts(3, 4, 2).count(), 0);
    }

    #[test]
    fn median_bias_known_values() {
        assert_eq!(median_bias(1), 1.0);
        assert!((median_bias(2) - 1.0).abs() < 1e-12);
        // n=3: H(3) - H(1) = 1/2 + 1/3
        assert!((median_bias(3) - (0.5 + 1.0 / 3.0)).abs() < 1e-12);
        // Large n approaches ln 2.
        assert!((median_bias(10_001) - std::f64::consts::LN_2).abs() < 1e-4);
    }

    #[test]
    fn mean_accumulator_respects_max_segments() {
        let averaging = Averaging::Mean {
            max_segments: Some(2),
        };
        let mut acc = Accumulator::new(&averaging, 1);
        acc.push(vec![1.0]);
        acc.push(vec![3.0]);
        assert!(acc.is_full());
        acc.push(vec![100.0]);
        let (values, count) = acc.finish().unwrap();
        assert_eq!(count, 2);
        assert_eq!(values, vec![2.0]);
    }
}
