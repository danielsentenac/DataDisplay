//! Numerical validation of the DSP primitives against known signals.

use dd_domain::{ChannelDescriptor, Series1D, TimeAxis};
use dd_processing::{
    bandpass, brms, butterworth_sos, coherence, cumulative_rms, decimate, filtfilt,
    phase_to_delay, resample_linear, sos_response, spectrogram, spectrogram_with,
    transfer_function, welch_spectrum, Averaging, BrmsParams, CrossParams, FilterKind,
    SpectrogramParams, SpectrumParams, SpectrumScaling,
};

const TWO_PI: f64 = 2.0 * std::f64::consts::PI;

fn series(values: Vec<f64>, sample_rate_hz: f64) -> Series1D {
    let mut channel = ChannelDescriptor::new("test:channel", "Test channel");
    channel.sample_rate_hz = Some(sample_rate_hz);
    channel.unit = Some("V".to_string());
    let len = values.len();
    Series1D {
        channel,
        axis: TimeAxis::Regular {
            start_ns: 0,
            sample_period_ns: (1.0e9 / sample_rate_hz).round() as i64,
            len,
        },
        values,
        metadata: dd_domain::Metadata::new(),
    }
}

fn sine(amplitude: f64, frequency_hz: f64, sample_rate_hz: f64, len: usize) -> Vec<f64> {
    (0..len)
        .map(|n| amplitude * (TWO_PI * frequency_hz * n as f64 / sample_rate_hz).sin())
        .collect()
}

/// Deterministic uniform noise in [-1, 1] (variance 1/3).
fn noise(len: usize, seed: u64) -> Vec<f64> {
    let mut state = seed.wrapping_mul(2862933555777941757).wrapping_add(3037000493);
    (0..len)
        .map(|_| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((state >> 11) as f64 / (1u64 << 53) as f64) * 2.0 - 1.0
        })
        .collect()
}

const NOISE_VARIANCE: f64 = 1.0 / 3.0;

#[test]
fn welch_psd_of_sine_peaks_at_frequency_and_preserves_power() {
    let fs = 1000.0;
    let amplitude = 2.0;
    let input = series(sine(amplitude, 50.0, fs, 8000), fs);
    let params = SpectrumParams::new(1000); // df = 1 Hz, 50 Hz is an exact bin

    let psd = welch_spectrum(&input, &params).expect("welch should succeed");
    assert!(psd.is_consistent());
    assert_eq!(psd.axis.len, 501);
    assert!((psd.axis.step_hz - 1.0).abs() < 1e-9);

    let peak_bin = psd
        .values
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap()
        .0;
    assert_eq!(peak_bin, 50);

    // Parseval: integrated PSD equals the signal power A^2/2.
    let total_power: f64 = psd.values.iter().sum::<f64>() * psd.axis.step_hz;
    let expected = amplitude * amplitude / 2.0;
    assert!(
        (total_power - expected).abs() / expected < 0.01,
        "total power {total_power} vs expected {expected}"
    );
}

#[test]
fn welch_psd_of_white_noise_is_flat_at_the_right_level() {
    let fs = 1000.0;
    let input = series(noise(200_000, 7), fs);
    let params = SpectrumParams::new(1000);

    let psd = welch_spectrum(&input, &params).expect("welch should succeed");

    // Integrated PSD returns the variance.
    let total_power: f64 = psd.values.iter().sum::<f64>() * psd.axis.step_hz;
    assert!(
        (total_power - NOISE_VARIANCE).abs() / NOISE_VARIANCE < 0.03,
        "integrated PSD {total_power} vs variance {NOISE_VARIANCE}"
    );

    // One-sided density of white noise is 2*sigma^2/fs, flat across the band.
    let expected_level = 2.0 * NOISE_VARIANCE / fs;
    let mid_band = &psd.values[10..450];
    let mean_level: f64 = mid_band.iter().sum::<f64>() / mid_band.len() as f64;
    assert!(
        (mean_level - expected_level).abs() / expected_level < 0.05,
        "mid-band level {mean_level} vs expected {expected_level}"
    );
}

#[test]
fn amplitude_scaling_is_square_root_of_power() {
    let fs = 1000.0;
    let input = series(sine(2.0, 50.0, fs, 8000), fs);
    let mut params = SpectrumParams::new(1000);
    let power = welch_spectrum(&input, &params).unwrap();
    params.scaling = SpectrumScaling::AmplitudeDensity;
    let amplitude = welch_spectrum(&input, &params).unwrap();

    for (asd, psd) in amplitude.values.iter().zip(power.values.iter()) {
        assert!((asd * asd - psd).abs() <= 1e-9 * psd.abs().max(1e-30));
    }
    assert_eq!(amplitude.channel.unit.as_deref(), Some("V/sqrt(Hz)"));
    assert_eq!(power.channel.unit.as_deref(), Some("(V)^2/Hz"));
}

#[test]
fn median_averaging_matches_mean_level_and_resists_glitches() {
    let fs = 1000.0;
    let mut values = noise(200_000, 11);
    let clean = series(values.clone(), fs);

    // Corrupt one region with a huge burst.
    for value in values[50_000..50_500].iter_mut() {
        *value += 1.0e4;
    }
    let glitched = series(values, fs);

    let mean_params = SpectrumParams::new(1000);
    let median_params = SpectrumParams {
        averaging: Averaging::Median,
        ..SpectrumParams::new(1000)
    };

    let mean_clean = welch_spectrum(&clean, &mean_params).unwrap();
    let median_clean = welch_spectrum(&clean, &median_params).unwrap();
    let mean_glitched = welch_spectrum(&glitched, &mean_params).unwrap();
    let median_glitched = welch_spectrum(&glitched, &median_params).unwrap();

    let band_level = |spectrum: &dd_domain::Spectrum| -> f64 {
        spectrum.values[10..450].iter().sum::<f64>() / 440.0
    };

    // Bias-corrected median matches the mean estimate on stationary noise.
    let ratio = band_level(&median_clean) / band_level(&mean_clean);
    assert!(
        (ratio - 1.0).abs() < 0.05,
        "median/mean ratio on clean noise: {ratio}"
    );

    // The glitch wrecks the mean estimate but not the median one.
    assert!(band_level(&mean_glitched) / band_level(&mean_clean) > 100.0);
    let median_ratio = band_level(&median_glitched) / band_level(&median_clean);
    assert!(
        (median_ratio - 1.0).abs() < 0.1,
        "median level changed by glitch: {median_ratio}"
    );
}

#[test]
fn exponential_decay_average_converges_to_noise_level() {
    let fs = 1000.0;
    let input = series(noise(100_000, 23), fs);
    let params = SpectrumParams {
        averaging: Averaging::ExponentialDecay {
            effective_count: 20.0,
        },
        ..SpectrumParams::new(1000)
    };

    let psd = welch_spectrum(&input, &params).unwrap();
    let expected_level = 2.0 * NOISE_VARIANCE / fs;
    let mid_band = &psd.values[10..450];
    let mean_level: f64 = mid_band.iter().sum::<f64>() / mid_band.len() as f64;
    assert!(
        (mean_level - expected_level).abs() / expected_level < 0.15,
        "decay-averaged level {mean_level} vs expected {expected_level}"
    );
}

#[test]
fn coherence_of_identical_and_independent_signals() {
    let fs = 1000.0;
    let x = series(noise(100_000, 31), fs);
    let z = series(noise(100_000, 77), fs);
    let params = CrossParams::new(1000);

    let self_coherence = coherence(&x, &x, &params).unwrap();
    assert!(self_coherence.values[5..450]
        .iter()
        .all(|value| *value > 0.999));

    let cross_coherence = coherence(&x, &z, &params).unwrap();
    let mean: f64 =
        cross_coherence.values[5..450].iter().sum::<f64>() / (450 - 5) as f64;
    assert!(mean < 0.1, "independent-noise coherence too high: {mean}");
}

#[test]
fn transfer_function_recovers_gain_delay_and_phase() {
    let fs = 1000.0;
    let gain = 3.0;
    let delay_samples = 5usize;
    let x_values = noise(100_000, 41);
    let mut y_values = vec![0.0; x_values.len()];
    for i in delay_samples..x_values.len() {
        y_values[i] = gain * x_values[i - delay_samples];
    }
    let x = series(x_values, fs);
    let y = series(y_values, fs);

    let params = CrossParams::new(500); // df = 2 Hz
    let tf = transfer_function(&x, &y, &params).unwrap();

    // Gain across the mid band.
    for bin in 10..200 {
        let module = tf.module.values[bin];
        assert!(
            (module - gain).abs() / gain < 0.03,
            "bin {bin}: module {module} vs gain {gain}"
        );
    }

    // Phase at 50 Hz (bin 25): -2*pi*f*delay = -pi/2.
    let expected_phase = -TWO_PI * 50.0 * delay_samples as f64 / fs;
    let phase = tf.phase_rad.values[25];
    assert!(
        (phase - expected_phase).abs() < 0.05,
        "phase {phase} vs expected {expected_phase}"
    );

    // Delay reading at the same bin.
    let delay = phase_to_delay(&tf.phase_rad);
    let expected_delay = delay_samples as f64 / fs;
    assert!(
        (delay.values[25] - expected_delay).abs() < 2e-4,
        "delay {} vs expected {expected_delay}",
        delay.values[25]
    );
}

#[test]
fn butterworth_lowpass_frequency_response() {
    let fs = 1000.0;
    let sos = butterworth_sos(4, &FilterKind::LowPass { cutoff_hz: 100.0 }, fs).unwrap();

    let at = |f: f64| sos_response(&sos, f, fs).norm();
    assert!((at(1.0) - 1.0).abs() < 1e-3);
    assert!((at(100.0) - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-3);
    assert!(at(400.0) < 0.01);
}

#[test]
fn butterworth_highpass_and_bandpass_response() {
    let fs = 1000.0;
    let hp = butterworth_sos(4, &FilterKind::HighPass { cutoff_hz: 100.0 }, fs).unwrap();
    let hp_at = |f: f64| sos_response(&hp, f, fs).norm();
    assert!((hp_at(100.0) - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-3);
    assert!(hp_at(10.0) < 0.01);
    assert!((hp_at(450.0) - 1.0).abs() < 1e-3);

    let bp = butterworth_sos(
        4,
        &FilterKind::BandPass {
            low_hz: 50.0,
            high_hz: 150.0,
        },
        fs,
    )
    .unwrap();
    let bp_at = |f: f64| sos_response(&bp, f, fs).norm();
    assert!((bp_at(100.0) - 1.0).abs() < 0.05);
    assert!(bp_at(5.0) < 0.01);
    assert!(bp_at(480.0) < 0.02);
}

#[test]
fn filtfilt_is_zero_phase_in_the_passband() {
    let fs = 1000.0;
    let amplitude = 1.0;
    let original = sine(amplitude, 30.0, fs, 4096);
    let input = series(original.clone(), fs);

    let filtered = bandpass(&input, 10.0, 100.0, 4).unwrap();

    // Mid region: no attenuation, no phase shift.
    for i in 1000..3000 {
        assert!(
            (filtered.values[i] - original[i]).abs() < 0.02 * amplitude,
            "sample {i}: {} vs {}",
            filtered.values[i],
            original[i]
        );
    }
}

#[test]
fn decimate_preserves_low_band_and_rejects_aliases() {
    let fs = 1000.0;
    let n = 10_000;
    let low = sine(1.0, 10.0, fs, n);
    let high = sine(1.0, 130.0, fs, n);
    let mixed: Vec<f64> = low.iter().zip(high.iter()).map(|(a, b)| a + b).collect();
    let input = series(mixed, fs);

    let decimated = decimate(&input, 5).unwrap();
    assert_eq!(decimated.channel.sample_rate_hz, Some(200.0));
    let TimeAxis::Regular {
        sample_period_ns, ..
    } = decimated.axis
    else {
        panic!("expected regular axis");
    };
    assert_eq!(sample_period_ns, 5_000_000);

    // Mid region matches the pure 10 Hz tone at the decimated instants;
    // the 130 Hz component (above the new Nyquist of 100 Hz) is gone.
    let mid = 500..(decimated.len() - 500);
    let mut error_power = 0.0;
    let mut count = 0usize;
    for i in mid {
        let expected = (TWO_PI * 10.0 * (i * 5) as f64 / fs).sin();
        let diff = decimated.values[i] - expected;
        error_power += diff * diff;
        count += 1;
    }
    let error_rms = (error_power / count as f64).sqrt();
    assert!(error_rms < 0.03, "residual error RMS {error_rms}");
}

#[test]
fn filtfilt_short_input_passthrough() {
    let sos = butterworth_sos(4, &FilterKind::LowPass { cutoff_hz: 100.0 }, 1000.0).unwrap();
    assert_eq!(filtfilt(&sos, &[1.0]), vec![1.0]);
    assert_eq!(filtfilt(&sos, &[]), Vec::<f64>::new());
}

#[test]
fn brms_tracks_in_band_amplitude() {
    let fs = 1000.0;
    let amplitude = 2.0;
    let input = series(sine(amplitude, 50.0, fs, 20_000), fs);

    let in_band = brms(&input, &BrmsParams::new(40.0, 60.0, 1000, 500)).unwrap();
    let expected = amplitude / std::f64::consts::SQRT_2;
    for value in &in_band.values {
        assert!(
            (value - expected).abs() / expected < 0.02,
            "in-band BRMS {value} vs expected {expected}"
        );
    }

    let out_of_band = brms(&input, &BrmsParams::new(100.0, 200.0, 1000, 500)).unwrap();
    assert!(out_of_band.values.iter().all(|value| *value < 0.05));

    // Segment centers, stepped by the requested stride.
    let TimeAxis::Regular {
        start_ns,
        sample_period_ns,
        ..
    } = in_band.axis
    else {
        panic!("expected regular axis");
    };
    assert_eq!(start_ns, 500_000_000);
    assert_eq!(sample_period_ns, 500_000_000);
}

#[test]
fn spectrogram_places_tone_on_the_right_row() {
    let fs = 1000.0;
    let input = series(sine(1.0, 50.0, fs, 5000), fs);
    let grid = spectrogram(&input, 200, 100); // df = 5 Hz -> row 10

    assert!(grid.is_consistent());
    assert_eq!(grid.height, 101);
    assert_eq!(grid.metadata.get("dd_y_step_hz").map(String::as_str), Some("5"));

    for column in 0..grid.width {
        let rows = &grid.values[column * grid.height..(column + 1) * grid.height];
        let peak_row = rows
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap()
            .0;
        assert_eq!(peak_row, 10, "column {column}");
    }
}

#[test]
fn spectrogram_median_normalization_flattens_stationary_lines() {
    let fs = 1000.0;
    let input = series(sine(1.0, 50.0, fs, 20_000), fs);
    let params = SpectrogramParams {
        median_normalize_rows: true,
        ..SpectrogramParams::new(1000, 500)
    };
    let grid = spectrogram_with(&input, &params).unwrap();

    // The stationary 50 Hz row is normalized to ~1 everywhere.
    for column in 0..grid.width {
        let value = grid.values[column * grid.height + 50];
        assert!((value - 1.0).abs() < 0.05, "column {column}: {value}");
    }
}

#[test]
fn legacy_spectrogram_survives_degenerate_inputs() {
    let empty = series(Vec::new(), 1000.0);
    let grid = spectrogram(&empty, 32, 16);
    assert!(grid.is_consistent());
    assert_eq!(grid.width, 0);

    let short = series(vec![1.0, 2.0, 3.0], 1000.0);
    let grid = spectrogram(&short, 32, 16);
    assert!(grid.is_consistent());
    assert!(grid.width >= 1);
}

#[test]
fn cumulative_rms_of_sine_reaches_signal_rms() {
    let fs = 1000.0;
    let amplitude = 2.0;
    let input = series(sine(amplitude, 50.0, fs, 8000), fs);
    let psd = welch_spectrum(&input, &SpectrumParams::new(1000)).unwrap();

    let ascending = cumulative_rms(&psd, false);
    let total = *ascending.values.last().unwrap();
    let expected = amplitude / std::f64::consts::SQRT_2;
    assert!(
        (total - expected).abs() / expected < 0.02,
        "cumulative RMS {total} vs expected {expected}"
    );

    let descending = cumulative_rms(&psd, true);
    assert!((descending.values[0] - total).abs() / total < 1e-9);
}

#[test]
fn resample_linear_upsamples_faithfully() {
    let fs = 1000.0;
    let input = series(sine(1.0, 10.0, fs, 1000), fs);
    let resampled = resample_linear(&input, 4000.0).unwrap();

    assert_eq!(resampled.channel.sample_rate_hz, Some(4000.0));
    assert!(resampled.len() > 3900);
    for (i, value) in resampled.values.iter().enumerate() {
        let expected = (TWO_PI * 10.0 * i as f64 / 4000.0).sin();
        assert!(
            (value - expected).abs() < 0.01,
            "sample {i}: {value} vs {expected}"
        );
    }
}

#[test]
fn welch_rejects_impossible_inputs() {
    let fs = 1000.0;
    let short = series(vec![1.0; 10], fs);
    assert!(welch_spectrum(&short, &SpectrumParams::new(100)).is_err());

    let irregular = Series1D {
        channel: ChannelDescriptor::new("irr", "Irregular"),
        axis: TimeAxis::Irregular {
            timestamps_ns: vec![0, 5, 11],
        },
        values: vec![1.0, 2.0, 3.0],
        metadata: dd_domain::Metadata::new(),
    };
    assert!(welch_spectrum(&irregular, &SpectrumParams::new(2)).is_err());
}
