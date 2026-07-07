/// Spectral analysis windows. Coefficients are the "periodic" variants, which
/// are the correct choice for Welch-style segmented FFT analysis.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Window {
    Rectangular,
    Hann,
    Hamming,
    Blackman,
}

impl Window {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Rectangular => "rectangular",
            Self::Hann => "hann",
            Self::Hamming => "hamming",
            Self::Blackman => "blackman",
        }
    }

    pub fn coefficients(&self, len: usize) -> Vec<f64> {
        use std::f64::consts::PI;

        (0..len)
            .map(|n| {
                let phase = 2.0 * PI * n as f64 / len as f64;
                match self {
                    Self::Rectangular => 1.0,
                    Self::Hann => 0.5 * (1.0 - phase.cos()),
                    Self::Hamming => 0.54 - 0.46 * phase.cos(),
                    Self::Blackman => 0.42 - 0.5 * phase.cos() + 0.08 * (2.0 * phase).cos(),
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hann_periodic_properties() {
        let coeffs = Window::Hann.coefficients(8);
        assert_eq!(coeffs.len(), 8);
        assert!(coeffs[0].abs() < 1e-12);
        // Periodic Hann of even length peaks at exactly len/2.
        assert!((coeffs[4] - 1.0).abs() < 1e-12);
        // Sum of periodic Hann coefficients is len/2.
        let sum: f64 = coeffs.iter().sum();
        assert!((sum - 4.0).abs() < 1e-12);
    }

    #[test]
    fn rectangular_is_all_ones() {
        assert!(Window::Rectangular
            .coefficients(5)
            .iter()
            .all(|value| *value == 1.0));
    }
}
