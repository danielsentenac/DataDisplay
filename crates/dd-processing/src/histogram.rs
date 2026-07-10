//! Sample-value distributions (the original's 1D-DISTRIB and 2D-DISTRIB).

use dd_domain::{ChannelDescriptor, Grid2D, Metadata, Series1D, TimeRange};

use crate::error::ProcessingError;

pub struct Histogram1D {
    pub start: f64,
    pub bin_width: f64,
    pub counts: Vec<f64>,
}

fn finite_range(values: &[f64]) -> Option<(f64, f64)> {
    let mut range: Option<(f64, f64)> = None;
    for value in values.iter().filter(|value| value.is_finite()) {
        range = Some(match range {
            Some((low, high)) => (low.min(*value), high.max(*value)),
            None => (*value, *value),
        });
    }
    range
}

fn resolve_range(
    values: &[f64],
    manual_min: Option<f64>,
    manual_max: Option<f64>,
) -> Result<(f64, f64), ProcessingError> {
    let auto = finite_range(values);
    let low = manual_min.or(auto.map(|range| range.0));
    let high = manual_max.or(auto.map(|range| range.1));
    let (Some(low), Some(high)) = (low, high) else {
        return Err(ProcessingError::EmptyInput);
    };
    if high <= low {
        // Degenerate constant data: widen a hair so the single bin renders.
        return Ok((low - 0.5, low + 0.5));
    }
    Ok((low, high))
}

/// Histogram of sample values over `bins` equal-width bins in
/// `[min, max]` (auto-ranged from the finite data when unset).
pub fn histogram1d(
    series: &Series1D,
    bins: usize,
    manual_min: Option<f64>,
    manual_max: Option<f64>,
) -> Result<Histogram1D, ProcessingError> {
    if series.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    let bins = bins.clamp(1, 1_000_000);
    let (low, high) = resolve_range(&series.values, manual_min, manual_max)?;
    let bin_width = (high - low) / bins as f64;

    let mut counts = vec![0.0; bins];
    for value in series.values.iter().filter(|value| value.is_finite()) {
        if *value < low || *value > high {
            continue;
        }
        let index = (((value - low) / bin_width) as usize).min(bins - 1);
        counts[index] += 1.0;
    }

    Ok(Histogram1D {
        start: low,
        bin_width,
        counts,
    })
}

/// 2D correlation histogram of two aligned series (x from `a`, y from `b`),
/// as a column-major Grid2D with bin coordinates in
/// `dd_x_origin`/`dd_x_step`/`dd_y_origin`/`dd_y_step` metadata.
#[allow(clippy::too_many_arguments)]
pub fn histogram2d(
    a: &Series1D,
    b: &Series1D,
    x_bins: usize,
    y_bins: usize,
    x_min: Option<f64>,
    x_max: Option<f64>,
    y_min: Option<f64>,
    y_max: Option<f64>,
) -> Result<Grid2D, ProcessingError> {
    if a.is_empty() || b.is_empty() {
        return Err(ProcessingError::EmptyInput);
    }
    let x_bins = x_bins.clamp(1, 10_000);
    let y_bins = y_bins.clamp(1, 10_000);
    let len = a.len().min(b.len());
    let (x_low, x_high) = resolve_range(&a.values[..len], x_min, x_max)?;
    let (y_low, y_high) = resolve_range(&b.values[..len], y_min, y_max)?;
    let x_step = (x_high - x_low) / x_bins as f64;
    let y_step = (y_high - y_low) / y_bins as f64;

    // Column-major like the spectrogram grids: all y rows of column 0 first.
    let mut values = vec![0.0f32; x_bins * y_bins];
    for index in 0..len {
        let x = a.values[index];
        let y = b.values[index];
        if !x.is_finite() || !y.is_finite() {
            continue;
        }
        if x < x_low || x > x_high || y < y_low || y > y_high {
            continue;
        }
        let column = (((x - x_low) / x_step) as usize).min(x_bins - 1);
        let row = (((y - y_low) / y_step) as usize).min(y_bins - 1);
        values[column * y_bins + row] += 1.0;
    }

    let mut metadata = Metadata::new();
    metadata.insert("dd_kind".to_string(), "histogram2d".to_string());
    metadata.insert("dd_x_origin".to_string(), x_low.to_string());
    metadata.insert("dd_x_step".to_string(), x_step.to_string());
    metadata.insert("dd_y_origin_hz".to_string(), y_low.to_string());
    metadata.insert("dd_y_step_hz".to_string(), y_step.to_string());

    Ok(Grid2D {
        channel: ChannelDescriptor {
            id: format!("hist2d({},{})", a.channel.id, b.channel.id),
            display_name: format!(
                "{} vs {}",
                b.channel.display_name, a.channel.display_name
            ),
            unit: Some("counts".to_string()),
            sample_rate_hz: None,
            metadata: Metadata::new(),
        },
        x_range: TimeRange::new(0, 0),
        y_label: b.channel.display_name.clone(),
        y_unit: b.channel.unit.clone(),
        width: x_bins,
        height: y_bins,
        values,
        metadata,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use dd_domain::TimeAxis;

    fn series(values: Vec<f64>) -> Series1D {
        let len = values.len();
        Series1D {
            channel: ChannelDescriptor::new("ch", "ch"),
            axis: TimeAxis::Regular {
                start_ns: 0,
                sample_period_ns: 1_000_000,
                len,
            },
            values,
            metadata: Metadata::new(),
        }
    }

    #[test]
    fn histogram1d_counts_and_ranges() {
        let data = series(vec![0.0, 0.5, 1.0, 1.5, 2.0, f64::NAN]);
        let histogram = histogram1d(&data, 2, Some(0.0), Some(2.0)).unwrap();
        assert_eq!(histogram.counts, vec![2.0, 3.0]);
        assert_eq!(histogram.start, 0.0);
        assert_eq!(histogram.bin_width, 1.0);

        // Constant data widens to a renderable single bin.
        let flat = histogram1d(&series(vec![5.0; 10]), 4, None, None).unwrap();
        assert_eq!(flat.counts.iter().sum::<f64>(), 10.0);
    }

    #[test]
    fn histogram2d_places_pairs_in_cells() {
        let a = series(vec![0.0, 0.0, 1.0, 1.0]);
        let b = series(vec![0.0, 1.0, 0.0, 1.0]);
        let grid = histogram2d(&a, &b, 2, 2, Some(0.0), Some(1.0), Some(0.0), Some(1.0))
            .unwrap();
        assert!(grid.is_consistent());
        // Every quadrant holds exactly one pair.
        assert_eq!(grid.values, vec![1.0, 1.0, 1.0, 1.0]);
    }
}
