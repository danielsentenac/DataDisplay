use std::fmt;

use dd_domain::{Series1D, TimeAxis};

#[derive(Clone, Debug, PartialEq)]
pub enum ProcessingError {
    /// The operation requires regularly sampled data.
    IrregularSampling,
    /// The sample rate could not be derived from the axis or channel.
    UnknownSampleRate,
    EmptyInput,
    InvalidParams(String),
    MismatchedInputs(String),
}

impl fmt::Display for ProcessingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::IrregularSampling => {
                write!(f, "operation requires regularly sampled data")
            }
            Self::UnknownSampleRate => {
                write!(f, "sample rate is unknown for this series")
            }
            Self::EmptyInput => write!(f, "input series is empty"),
            Self::InvalidParams(message) => write!(f, "invalid parameters: {message}"),
            Self::MismatchedInputs(message) => write!(f, "mismatched inputs: {message}"),
        }
    }
}

impl std::error::Error for ProcessingError {}

/// Best-estimate sample rate: prefer the channel's declared rate (exact even
/// when the integer-ns period cannot represent it, e.g. 16384 Hz), fall back
/// to the regular axis period.
pub fn series_sample_rate_hz(series: &Series1D) -> Result<f64, ProcessingError> {
    if let Some(rate) = series.channel.sample_rate_hz {
        if rate > 0.0 {
            return Ok(rate);
        }
    }

    match &series.axis {
        TimeAxis::Regular {
            sample_period_ns, ..
        } if *sample_period_ns > 0 => Ok(1.0e9 / *sample_period_ns as f64),
        TimeAxis::Regular { .. } => Err(ProcessingError::UnknownSampleRate),
        TimeAxis::Irregular { .. } => Err(ProcessingError::IrregularSampling),
    }
}
