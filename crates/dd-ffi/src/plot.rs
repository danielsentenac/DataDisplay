//! One-call plot pipeline: read channels, run dd-processing, return
//! ready-to-draw dd-render scenes. This keeps all DSP and scene assembly on
//! the Rust side of the ABI; the shell only rasterizes.

use serde::{Deserialize, Serialize};

use dd_backend::{Aggregation, ReadQuery};
use dd_domain::{DataBlock, Grid2D, Series1D, Spectrum, TimeRange};
use dd_processing::{
    band_slice, bandpass, brms, cross_analysis, cumulative_rms, decimate, downsample_mean,
    phase_to_delay, resample_linear, series_sample_rate_hz, spectrogram_with, spectrum_to_db,
    welch_spectrum, Averaging, BrmsParams, CrossParams, ProcessingError, SpectrogramParams,
    SpectrumParams, SpectrumScaling, Window,
};
use dd_render::{
    spectrogram_scene, spectrum_scene, time_series_scene, AxisSpec, PlotKind, PlotLayer,
    PlotScene,
};

use crate::{DatadisplayEngine, EngineError, EngineResult, FfiTimeRange};

fn default_overlap() -> f64 {
    0.5
}
fn default_window() -> String {
    "hann".to_string()
}
fn default_averaging() -> String {
    "mean".to_string()
}
fn default_filter_order() -> usize {
    4
}
fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PlotChannelRef {
    pub source_id: u64,
    pub channel_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PlotRequest {
    pub channels: Vec<PlotChannelRef>,
    pub time_range: FfiTimeRange,
    pub spec: PlotSpec,
    #[serde(default)]
    pub allow_gaps: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PlotSpec {
    Time(TimePlotSpec),
    Fft(SpectrumPlotSpec),
    Spectrogram(SpectrogramPlotSpec),
    Coherence(CrossPlotSpec),
    TransferFunction(CrossPlotSpec),
    Brms(BrmsPlotSpec),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
pub struct TimePlotSpec {
    /// Optional zero-phase Butterworth band-pass `[low_hz, high_hz]`.
    #[serde(default)]
    pub band_hz: Option<(f64, f64)>,
    #[serde(default = "default_filter_order")]
    pub filter_order: usize,
    #[serde(default)]
    pub remove_dc: bool,
    /// Resample to this rate (anti-aliased when decimating).
    #[serde(default)]
    pub resample_hz: Option<f64>,
    /// Downsample for display when the series is longer than this.
    #[serde(default)]
    pub max_points: Option<usize>,
    #[serde(default)]
    pub y_min: Option<f64>,
    #[serde(default)]
    pub y_max: Option<f64>,
    #[serde(default)]
    pub log_y: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SpectrumPlotSpec {
    /// FFT length in samples; alternatively give `segment_duration_s`.
    #[serde(default)]
    pub segment_len: usize,
    /// FFT length in seconds (the original's unit); wins over `segment_len`.
    #[serde(default)]
    pub segment_duration_s: Option<f64>,
    #[serde(default = "default_overlap")]
    pub overlap: f64,
    #[serde(default = "default_window")]
    pub window: String,
    /// "mean" | "median" | "decay"
    #[serde(default = "default_averaging")]
    pub averaging: String,
    #[serde(default)]
    pub max_segments: Option<usize>,
    #[serde(default)]
    pub decay_count: Option<f64>,
    #[serde(default)]
    pub remove_dc: bool,
    /// Amplitude density (1/√Hz) instead of power density (1/Hz).
    #[serde(default = "default_true")]
    pub amplitude: bool,
    #[serde(default)]
    pub db: bool,
    /// Superpose the integrated-RMS curve (ignored when `db`).
    #[serde(default)]
    pub rms_curve: bool,
    /// Displayed frequency band (the original's fmin/fmax zoom).
    #[serde(default)]
    pub fmin_hz: Option<f64>,
    #[serde(default)]
    pub fmax_hz: Option<f64>,
    #[serde(default)]
    pub y_min: Option<f64>,
    #[serde(default)]
    pub y_max: Option<f64>,
    #[serde(default = "default_true")]
    pub log_x: bool,
    #[serde(default = "default_true")]
    pub log_y: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SpectrogramPlotSpec {
    #[serde(default)]
    pub segment_len: usize,
    #[serde(default)]
    pub segment_duration_s: Option<f64>,
    #[serde(default)]
    pub step_len: usize,
    #[serde(default)]
    pub step_duration_s: Option<f64>,
    #[serde(default = "default_window")]
    pub window: String,
    #[serde(default)]
    pub remove_dc: bool,
    #[serde(default)]
    pub amplitude: bool,
    #[serde(default)]
    pub averages_per_column: Option<usize>,
    /// The original's "medY": divide each frequency row by its time median.
    #[serde(default)]
    pub median_normalize: bool,
    /// Displayed frequency band (rows outside are dropped).
    #[serde(default)]
    pub fmin_hz: Option<f64>,
    #[serde(default)]
    pub fmax_hz: Option<f64>,
    /// Manual color scale (the original's zmin/zmax; autoZ when unset).
    #[serde(default)]
    pub z_min: Option<f64>,
    #[serde(default)]
    pub z_max: Option<f64>,
    #[serde(default = "default_true")]
    pub log_z: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CrossPlotSpec {
    #[serde(default)]
    pub segment_len: usize,
    #[serde(default)]
    pub segment_duration_s: Option<f64>,
    #[serde(default = "default_overlap")]
    pub overlap: f64,
    #[serde(default = "default_window")]
    pub window: String,
    #[serde(default = "default_averaging")]
    pub averaging: String,
    #[serde(default)]
    pub max_segments: Option<usize>,
    #[serde(default)]
    pub decay_count: Option<f64>,
    #[serde(default)]
    pub remove_dc: bool,
    /// Time shift applied to channel B in seconds: positive compares A(t)
    /// with B(t + shift) (the original's inter-channel time shift).
    #[serde(default)]
    pub shift_b_s: f64,
    /// Coherence only: plot sqrt(coherence).
    #[serde(default)]
    pub sqrt: bool,
    /// Transfer function only: show delay (s) instead of phase (rad).
    #[serde(default)]
    pub phase_as_delay: bool,
    /// Displayed frequency band.
    #[serde(default)]
    pub fmin_hz: Option<f64>,
    #[serde(default)]
    pub fmax_hz: Option<f64>,
    /// Manual y range of the coherence/module pane.
    #[serde(default)]
    pub y_min: Option<f64>,
    #[serde(default)]
    pub y_max: Option<f64>,
    #[serde(default = "default_true")]
    pub log_x: bool,
    /// Log module axis (transfer function only).
    #[serde(default = "default_true")]
    pub log_y: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BrmsPlotSpec {
    pub fmin_hz: f64,
    pub fmax_hz: f64,
    #[serde(default)]
    pub segment_len: usize,
    #[serde(default)]
    pub segment_duration_s: Option<f64>,
    #[serde(default)]
    pub step_len: usize,
    #[serde(default)]
    pub step_duration_s: Option<f64>,
    #[serde(default = "default_window")]
    pub window: String,
    #[serde(default)]
    pub remove_dc: bool,
    #[serde(default)]
    pub y_min: Option<f64>,
    #[serde(default)]
    pub y_max: Option<f64>,
    #[serde(default)]
    pub log_y: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PlotResponse {
    pub title: String,
    pub scenes: Vec<FfiPlotScene>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FfiAxisSpec {
    pub label: String,
    pub unit: Option<String>,
    pub log_scale: bool,
    pub range: Option<(f64, f64)>,
}

impl From<AxisSpec> for FfiAxisSpec {
    fn from(axis: AxisSpec) -> Self {
        Self {
            label: axis.label,
            unit: axis.unit,
            log_scale: axis.log_scale,
            range: axis.range,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FfiPlotLayer {
    Line {
        label: String,
        xs: Vec<f64>,
        ys: Vec<f64>,
        color_rgba: [f32; 4],
    },
    Heatmap {
        width: usize,
        height: usize,
        x0: f64,
        dx: f64,
        y0: f64,
        dy: f64,
        values: Vec<f32>,
    },
    Volume {
        x_len: usize,
        y_len: usize,
        z_len: usize,
        values: Vec<f32>,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FfiPlotScene {
    pub title: String,
    /// "line1d" | "heatmap2d" | "volume3d"
    pub plot_kind: String,
    pub x_axis: FfiAxisSpec,
    pub y_axis: FfiAxisSpec,
    pub z_axis: Option<FfiAxisSpec>,
    pub epoch_ns: Option<i64>,
    pub time_range: Option<FfiTimeRange>,
    pub layers: Vec<FfiPlotLayer>,
}

impl From<PlotScene> for FfiPlotScene {
    fn from(scene: PlotScene) -> Self {
        Self {
            title: scene.title,
            plot_kind: match scene.kind {
                PlotKind::Line1D => "line1d".to_string(),
                PlotKind::Heatmap2D => "heatmap2d".to_string(),
                PlotKind::Volume3D => "volume3d".to_string(),
            },
            x_axis: scene.x_axis.into(),
            y_axis: scene.y_axis.into(),
            z_axis: scene.z_axis.map(FfiAxisSpec::from),
            epoch_ns: scene.epoch_ns,
            time_range: scene.time_range.map(FfiTimeRange::from),
            layers: scene
                .layers
                .into_iter()
                .map(|layer| match layer {
                    PlotLayer::Line(line) => FfiPlotLayer::Line {
                        label: line.label,
                        xs: line.xs,
                        ys: line.ys,
                        color_rgba: line.color_rgba,
                    },
                    PlotLayer::Heatmap(map) => FfiPlotLayer::Heatmap {
                        width: map.width,
                        height: map.height,
                        x0: map.x0,
                        dx: map.dx,
                        y0: map.y0,
                        dy: map.dy,
                        values: map.values,
                    },
                    PlotLayer::Volume(volume) => FfiPlotLayer::Volume {
                        x_len: volume.x_len,
                        y_len: volume.y_len,
                        z_len: volume.z_len,
                        values: volume.values,
                    },
                })
                .collect(),
        }
    }
}

fn processing_error(error: ProcessingError) -> EngineError {
    EngineError::invalid_query(error.to_string())
}

fn parse_window(name: &str) -> EngineResult<Window> {
    match name.to_ascii_lowercase().as_str() {
        "hann" | "hanning" => Ok(Window::Hann),
        "hamming" => Ok(Window::Hamming),
        "blackman" => Ok(Window::Blackman),
        "rectangular" | "none" => Ok(Window::Rectangular),
        other => Err(EngineError::invalid_query(format!(
            "unknown window `{other}` (expected hann, hamming, blackman, rectangular)"
        ))),
    }
}

fn parse_averaging(
    name: &str,
    max_segments: Option<usize>,
    decay_count: Option<f64>,
) -> EngineResult<Averaging> {
    match name.to_ascii_lowercase().as_str() {
        "mean" => Ok(Averaging::Mean { max_segments }),
        "median" => Ok(Averaging::Median),
        "decay" | "exponential_decay" => Ok(Averaging::ExponentialDecay {
            effective_count: decay_count.unwrap_or(8.0),
        }),
        other => Err(EngineError::invalid_query(format!(
            "unknown averaging `{other}` (expected mean, median, decay)"
        ))),
    }
}

fn read_series(
    engine: &DatadisplayEngine,
    channel: &PlotChannelRef,
    time_range: &TimeRange,
    allow_gaps: bool,
) -> EngineResult<Series1D> {
    let block = engine.read_block(
        channel.source_id,
        &ReadQuery {
            channel_id: channel.channel_id.clone(),
            time_range: time_range.clone(),
            resolution_hint: None,
            aggregation: Aggregation::Raw,
            allow_gaps,
        },
    )?;

    match block {
        DataBlock::Series1D(series) => Ok(series),
        DataBlock::Sampled(sampled) if sampled.is_scalar() => Ok(Series1D {
            channel: sampled.channel,
            axis: sampled.axis,
            values: sampled.values,
            metadata: sampled.metadata,
        }),
        other => Err(EngineError::invalid_query(format!(
            "channel `{}` returned {} data; this plot needs a scalar series",
            channel.channel_id,
            other.kind_name()
        ))),
    }
}

/// Resolve a segment/step length given either samples or seconds (seconds
/// win, matching the original's parameter panels).
fn resolve_len(
    len_samples: usize,
    duration_s: Option<f64>,
    sample_rate_hz: f64,
    what: &str,
) -> EngineResult<usize> {
    if let Some(duration) = duration_s {
        let resolved = (duration * sample_rate_hz).round();
        if resolved < 2.0 {
            return Err(EngineError::invalid_query(format!(
                "{what} of {duration} s is under 2 samples at {sample_rate_hz} Hz"
            )));
        }
        return Ok(resolved as usize);
    }
    if len_samples >= 2 {
        return Ok(len_samples);
    }
    Err(EngineError::invalid_query(format!(
        "{what} must be given in samples (>= 2) or seconds"
    )))
}

fn sample_rate(series: &Series1D) -> EngineResult<f64> {
    series_sample_rate_hz(series).map_err(processing_error)
}

fn apply_y_range(scene: &mut PlotScene, y_min: Option<f64>, y_max: Option<f64>) {
    if y_min.is_none() && y_max.is_none() {
        return;
    }
    let (data_min, data_max) = scene.y_axis.range.unwrap_or((0.0, 1.0));
    scene.y_axis.range = Some((y_min.unwrap_or(data_min), y_max.unwrap_or(data_max)));
}

fn maybe_band_slice(
    spectrum: Spectrum,
    fmin_hz: Option<f64>,
    fmax_hz: Option<f64>,
) -> EngineResult<Spectrum> {
    if fmin_hz.is_none() && fmax_hz.is_none() {
        return Ok(spectrum);
    }
    let fmin = fmin_hz.unwrap_or(spectrum.axis.start_hz);
    let fmax = fmax_hz.unwrap_or_else(|| spectrum.axis.last_frequency_hz().unwrap_or(fmin));
    let sliced = band_slice(&spectrum, fmin, fmax);
    if sliced.is_empty() {
        return Err(EngineError::invalid_query(format!(
            "frequency band [{fmin}, {fmax}] Hz contains no spectrum bin"
        )));
    }
    Ok(sliced)
}

/// Align channel B onto A shifted by `shift_s`: positive shift compares
/// A(t) with B(t + shift). Returns the trimmed pair.
fn shift_pair(
    a: &Series1D,
    b: &Series1D,
    shift_s: f64,
) -> EngineResult<(Series1D, Series1D)> {
    if shift_s == 0.0 {
        return Ok((a.clone(), b.clone()));
    }
    let rate = sample_rate(b)?;
    let offset = (shift_s * rate).round() as i64;
    let drop_from = |series: &Series1D, count: usize| -> EngineResult<Series1D> {
        if count >= series.len() {
            return Err(EngineError::invalid_query(format!(
                "time shift of {shift_s} s exceeds the data length"
            )));
        }
        let mut shifted = series.clone();
        shifted.values = series.values[count..].to_vec();
        if let dd_domain::TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            ..
        } = &series.axis
        {
            shifted.axis = dd_domain::TimeAxis::Regular {
                start_ns: start_ns.saturating_add(sample_period_ns * count as i64),
                sample_period_ns: *sample_period_ns,
                len: shifted.values.len(),
            };
        }
        Ok(shifted)
    };

    if offset > 0 {
        Ok((a.clone(), drop_from(b, offset as usize)?))
    } else {
        Ok((drop_from(a, (-offset) as usize)?, b.clone()))
    }
}

/// Drop spectrogram rows outside `[fmin, fmax]` (column-major grid).
fn slice_grid_rows(grid: &Grid2D, fmin_hz: f64, fmax_hz: f64) -> EngineResult<Grid2D> {
    let y0 = grid
        .metadata
        .get("dd_y_origin_hz")
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(0.0);
    let dy = grid
        .metadata
        .get("dd_y_step_hz")
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(1.0);

    let first = (((fmin_hz - y0) / dy).ceil().max(0.0)) as usize;
    let last_in_band = ((fmax_hz - y0) / dy).floor();
    if grid.height == 0 || last_in_band < first as f64 {
        return Err(EngineError::invalid_query(format!(
            "frequency band [{fmin_hz}, {fmax_hz}] Hz contains no spectrogram row"
        )));
    }
    let last = (last_in_band as usize).min(grid.height - 1);

    let rows = last + 1 - first;
    let mut values = Vec::with_capacity(grid.width * rows);
    for column in 0..grid.width {
        let base = column * grid.height;
        values.extend_from_slice(&grid.values[base + first..base + last + 1]);
    }

    let mut sliced = grid.clone();
    sliced.height = rows;
    sliced.values = values;
    sliced
        .metadata
        .insert("dd_y_origin_hz".to_string(), (y0 + dy * first as f64).to_string());
    Ok(sliced)
}

fn expect_channels(request: &PlotRequest, expected: usize, kind: &str) -> EngineResult<()> {
    if request.channels.len() != expected {
        return Err(EngineError::invalid_query(format!(
            "{kind} plot needs exactly {expected} channel(s), got {}",
            request.channels.len()
        )));
    }
    Ok(())
}

fn channel_names(series: &[Series1D]) -> String {
    series
        .iter()
        .map(|one| one.channel.display_name.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

pub(crate) fn execute(
    engine: &DatadisplayEngine,
    request: PlotRequest,
) -> EngineResult<PlotResponse> {
    if request.channels.is_empty() {
        return Err(EngineError::invalid_query(
            "plot request must include at least one channel",
        ));
    }
    let time_range = request.time_range.into_domain()?;
    let series: Vec<Series1D> = request
        .channels
        .iter()
        .map(|channel| read_series(engine, channel, &time_range, request.allow_gaps))
        .collect::<EngineResult<_>>()?;

    let (title, scenes) = match &request.spec {
        PlotSpec::Time(spec) => plot_time(&series, spec)?,
        PlotSpec::Fft(spec) => plot_fft(&series, spec)?,
        PlotSpec::Spectrogram(spec) => {
            expect_channels(&request, 1, "spectrogram")?;
            plot_spectrogram(&series[0], spec)?
        }
        PlotSpec::Coherence(spec) => {
            expect_channels(&request, 2, "coherence")?;
            plot_coherence(&series[0], &series[1], spec)?
        }
        PlotSpec::TransferFunction(spec) => {
            expect_channels(&request, 2, "transfer function")?;
            plot_transfer_function(&series[0], &series[1], spec)?
        }
        PlotSpec::Brms(spec) => plot_brms(&series, spec)?,
    };

    Ok(PlotResponse {
        title,
        scenes: scenes.into_iter().map(FfiPlotScene::from).collect(),
    })
}

fn plot_time(
    series: &[Series1D],
    spec: &TimePlotSpec,
) -> EngineResult<(String, Vec<PlotScene>)> {
    let mut processed = Vec::with_capacity(series.len());
    for one in series {
        let mut current = if let Some((low_hz, high_hz)) = spec.band_hz {
            bandpass(one, low_hz, high_hz, spec.filter_order).map_err(processing_error)?
        } else {
            one.clone()
        };
        if let Some(target_hz) = spec.resample_hz {
            let rate = sample_rate(&current)?;
            if target_hz < rate * 0.999 {
                let factor = (rate / target_hz).round().max(2.0) as usize;
                current = decimate(&current, factor).map_err(processing_error)?;
            } else if target_hz > rate * 1.001 {
                current = resample_linear(&current, target_hz).map_err(processing_error)?;
            }
        }
        if spec.remove_dc && !current.is_empty() {
            let mean = current.values.iter().sum::<f64>() / current.len() as f64;
            for value in current.values.iter_mut() {
                *value -= mean;
            }
        }
        if let Some(max_points) = spec.max_points {
            if max_points > 0 && current.len() > max_points {
                let bucket = current.len().div_ceil(max_points);
                current = downsample_mean(&current, bucket);
            }
        }
        processed.push(current);
    }

    let title = format!("Time {}", channel_names(series));
    let refs: Vec<&Series1D> = processed.iter().collect();
    let mut scene = time_series_scene(&refs, title.clone());
    scene.y_axis.log_scale = spec.log_y;
    apply_y_range(&mut scene, spec.y_min, spec.y_max);
    Ok((title, vec![scene]))
}

fn spectrum_params(spec: &SpectrumPlotSpec, segment_len: usize) -> EngineResult<SpectrumParams> {
    Ok(SpectrumParams {
        segment_len,
        overlap: spec.overlap,
        window: parse_window(&spec.window)?,
        averaging: parse_averaging(&spec.averaging, spec.max_segments, spec.decay_count)?,
        remove_dc: spec.remove_dc,
        scaling: if spec.amplitude {
            SpectrumScaling::AmplitudeDensity
        } else {
            SpectrumScaling::PowerDensity
        },
    })
}

fn plot_fft(
    series: &[Series1D],
    spec: &SpectrumPlotSpec,
) -> EngineResult<(String, Vec<PlotScene>)> {
    let segment_len = resolve_len(
        spec.segment_len,
        spec.segment_duration_s,
        sample_rate(&series[0])?,
        "FFT length",
    )?;
    let params = spectrum_params(spec, segment_len)?;
    let mut spectra: Vec<Spectrum> = series
        .iter()
        .map(|one| {
            welch_spectrum(one, &params)
                .map_err(processing_error)
                .and_then(|spectrum| maybe_band_slice(spectrum, spec.fmin_hz, spec.fmax_hz))
        })
        .collect::<EngineResult<_>>()?;

    if spec.rms_curve && !spec.db {
        let curves: Vec<Spectrum> = spectra
            .iter()
            .map(|spectrum| cumulative_rms(spectrum, true))
            .collect();
        spectra.extend(curves);
    }
    if spec.db {
        spectra = spectra.iter().map(spectrum_to_db).collect();
    }

    let title = format!("FFT {}", channel_names(series));
    let refs: Vec<&Spectrum> = spectra.iter().collect();
    let mut scene = spectrum_scene(&refs, title.clone(), spec.log_x, spec.log_y && !spec.db);
    apply_y_range(&mut scene, spec.y_min, spec.y_max);
    Ok((title, vec![scene]))
}

fn plot_spectrogram(
    series: &Series1D,
    spec: &SpectrogramPlotSpec,
) -> EngineResult<(String, Vec<PlotScene>)> {
    let rate = sample_rate(series)?;
    let params = SpectrogramParams {
        segment_len: resolve_len(
            spec.segment_len,
            spec.segment_duration_s,
            rate,
            "spectrogram FFT length",
        )?,
        step_len: resolve_len(spec.step_len, spec.step_duration_s, rate, "spectrogram step")?,
        window: parse_window(&spec.window)?,
        remove_dc: spec.remove_dc,
        scaling: if spec.amplitude {
            SpectrumScaling::AmplitudeDensity
        } else {
            SpectrumScaling::PowerDensity
        },
        averages_per_column: spec.averages_per_column.unwrap_or(1),
        median_normalize_rows: spec.median_normalize,
    };
    let mut grid = spectrogram_with(series, &params).map_err(processing_error)?;
    if spec.fmin_hz.is_some() || spec.fmax_hz.is_some() {
        grid = slice_grid_rows(
            &grid,
            spec.fmin_hz.unwrap_or(0.0),
            spec.fmax_hz.unwrap_or(rate / 2.0),
        )?;
    }

    let mut scene = spectrogram_scene(&grid, spec.log_z);
    if spec.z_min.is_some() || spec.z_max.is_some() {
        if let Some(z_axis) = scene.z_axis.as_mut() {
            let (data_min, data_max) = z_axis.range.unwrap_or((0.0, 1.0));
            z_axis.range = Some((
                spec.z_min.unwrap_or(data_min),
                spec.z_max.unwrap_or(data_max),
            ));
        }
    }
    let title = format!("Spectrogram {}", series.channel.display_name);
    Ok((title, vec![scene]))
}

fn cross_params(spec: &CrossPlotSpec, segment_len: usize) -> EngineResult<CrossParams> {
    Ok(CrossParams {
        segment_len,
        overlap: spec.overlap,
        window: parse_window(&spec.window)?,
        averaging: parse_averaging(&spec.averaging, spec.max_segments, spec.decay_count)?,
        remove_dc: spec.remove_dc,
    })
}

fn plot_coherence(
    a: &Series1D,
    b: &Series1D,
    spec: &CrossPlotSpec,
) -> EngineResult<(String, Vec<PlotScene>)> {
    let (a, b) = shift_pair(a, b, spec.shift_b_s)?;
    let segment_len = resolve_len(
        spec.segment_len,
        spec.segment_duration_s,
        sample_rate(&a)?,
        "FFT length",
    )?;
    let analysis =
        cross_analysis(&a, &b, &cross_params(spec, segment_len)?).map_err(processing_error)?;
    let mut result = maybe_band_slice(analysis.coherence, spec.fmin_hz, spec.fmax_hz)?;

    let label = if spec.sqrt {
        for value in result.values.iter_mut() {
            *value = value.max(0.0).sqrt();
        }
        "sqrt(Coherence)"
    } else {
        "Coherence"
    };

    let title = format!(
        "{label} {} / {}",
        a.channel.display_name, b.channel.display_name
    );
    let mut scene = spectrum_scene(&[&result], title.clone(), spec.log_x, false);
    scene.y_axis.range = Some((0.0, 1.0));
    scene.y_axis.label = label.to_string();
    apply_y_range(&mut scene, spec.y_min, spec.y_max);
    Ok((title, vec![scene]))
}

fn plot_transfer_function(
    a: &Series1D,
    b: &Series1D,
    spec: &CrossPlotSpec,
) -> EngineResult<(String, Vec<PlotScene>)> {
    let (a, b) = shift_pair(a, b, spec.shift_b_s)?;
    let segment_len = resolve_len(
        spec.segment_len,
        spec.segment_duration_s,
        sample_rate(&a)?,
        "FFT length",
    )?;
    let analysis =
        cross_analysis(&a, &b, &cross_params(spec, segment_len)?).map_err(processing_error)?;
    let title = format!(
        "Transfer function {} -> {}",
        a.channel.display_name, b.channel.display_name
    );

    let module_spectrum =
        maybe_band_slice(analysis.transfer.module, spec.fmin_hz, spec.fmax_hz)?;
    let mut module = spectrum_scene(
        &[&module_spectrum],
        format!("{title} (module)"),
        spec.log_x,
        spec.log_y,
    );
    module.y_axis.label = "Module".to_string();
    apply_y_range(&mut module, spec.y_min, spec.y_max);

    let second = if spec.phase_as_delay {
        let delay =
            maybe_band_slice(phase_to_delay(&analysis.transfer.phase_rad), spec.fmin_hz, spec.fmax_hz)?;
        let mut scene = spectrum_scene(&[&delay], format!("{title} (delay)"), spec.log_x, false);
        scene.y_axis.label = "Delay".to_string();
        scene
    } else {
        let phase =
            maybe_band_slice(analysis.transfer.phase_rad, spec.fmin_hz, spec.fmax_hz)?;
        let mut scene = spectrum_scene(&[&phase], format!("{title} (phase)"), spec.log_x, false);
        scene.y_axis.label = "Phase".to_string();
        scene.y_axis.range = Some((-std::f64::consts::PI, std::f64::consts::PI));
        scene
    };

    Ok((title, vec![module, second]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{OpenSourceRequest, PlotRequest};
    use dd_backend::SourceRegistry;
    use dd_domain::{ChannelDescriptor, Metadata, TimeAxis};
    use dd_io_hdf5::{Hdf5Dataset, Hdf5Factory, Hdf5Layout};
    use std::sync::Arc;

    const FS: f64 = 1000.0;
    const LEN: usize = 8000;

    fn sine_series(id: &str, amplitude: f64) -> Series1D {
        let mut channel = ChannelDescriptor::new(id, id);
        channel.sample_rate_hz = Some(FS);
        channel.unit = Some("V".to_string());
        Series1D {
            channel,
            axis: TimeAxis::Regular {
                start_ns: 0,
                sample_period_ns: 1_000_000,
                len: LEN,
            },
            values: (0..LEN)
                .map(|n| {
                    amplitude
                        * (2.0 * std::f64::consts::PI * 50.0 * n as f64 / FS).sin()
                })
                .collect(),
            metadata: Metadata::new(),
        }
    }

    fn engine_with_sines() -> (DatadisplayEngine, u64) {
        let factory = Hdf5Factory::new();
        factory
            .register_layout(
                "hdf5:///test/plot.h5",
                Hdf5Layout::new()
                    .with_dataset(Hdf5Dataset::series(
                        "/channels/a",
                        sine_series("chan.a", 1.0),
                        Vec::<String>::new(),
                    ))
                    .with_dataset(Hdf5Dataset::series(
                        "/channels/b",
                        sine_series("chan.b", 2.0),
                        Vec::<String>::new(),
                    )),
            )
            .expect("layout registration should succeed");

        let mut engine = DatadisplayEngine::with_registry(SourceRegistry::new());
        engine.register_factory(Arc::new(factory));
        let open = engine
            .open_source(OpenSourceRequest {
                uri: "hdf5:///test/plot.h5".to_string(),
            })
            .expect("source should open");
        (engine, open.source_id)
    }

    fn full_range() -> FfiTimeRange {
        FfiTimeRange {
            start_ns: 0,
            end_ns: 8_000_000_000,
        }
    }

    fn channel(source_id: u64, channel_id: &str) -> PlotChannelRef {
        PlotChannelRef {
            source_id,
            channel_id: channel_id.to_string(),
        }
    }

    #[test]
    fn fft_plot_peaks_at_signal_frequency() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Fft(
                    serde_json::from_str(r#"{"segment_len": 1000}"#).unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("fft plot should succeed");

        assert_eq!(response.scenes.len(), 1);
        let scene = &response.scenes[0];
        assert_eq!(scene.plot_kind, "line1d");
        assert!(scene.x_axis.log_scale);
        assert!(scene.y_axis.log_scale);
        let FfiPlotLayer::Line { xs, ys, .. } = &scene.layers[0] else {
            panic!("expected line layer");
        };
        assert_eq!(xs.len(), 501);
        assert!((xs[1] - 1.0).abs() < 1e-9);
        let peak = ys
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap()
            .0;
        assert_eq!(peak, 50);
    }

    #[test]
    fn transfer_function_returns_module_and_phase_scenes() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a"), channel(source_id, "chan.b")],
                time_range: full_range(),
                spec: PlotSpec::TransferFunction(
                    serde_json::from_str(r#"{"segment_len": 500}"#).unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("transfer function plot should succeed");

        assert_eq!(response.scenes.len(), 2);
        let FfiPlotLayer::Line { ys, .. } = &response.scenes[0].layers[0] else {
            panic!("expected line layer");
        };
        // chan.b = 2 * chan.a: module 2 at the 50 Hz bin (df = 2 Hz -> bin 25).
        assert!((ys[25] - 2.0).abs() < 0.01, "module {}", ys[25]);
    }

    #[test]
    fn coherence_of_identical_channels_is_one() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a"), channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Coherence(
                    serde_json::from_str(r#"{"segment_len": 500}"#).unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("coherence plot should succeed");

        let scene = &response.scenes[0];
        assert_eq!(scene.y_axis.range, Some((0.0, 1.0)));
        let FfiPlotLayer::Line { ys, .. } = &scene.layers[0] else {
            panic!("expected line layer");
        };
        assert!(ys[25] > 0.999, "self coherence {}", ys[25]);
    }

    #[test]
    fn time_plot_downsamples_to_max_points() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Time(TimePlotSpec {
                    max_points: Some(100),
                    ..TimePlotSpec::default()
                }),
                allow_gaps: false,
            })
            .expect("time plot should succeed");

        let scene = &response.scenes[0];
        assert_eq!(scene.epoch_ns, Some(0));
        let FfiPlotLayer::Line { xs, .. } = &scene.layers[0] else {
            panic!("expected line layer");
        };
        assert!(xs.len() <= 100, "got {} points", xs.len());
    }

    #[test]
    fn spectrogram_plot_returns_positioned_heatmap() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Spectrogram(
                    serde_json::from_str(r#"{"segment_len": 200, "step_len": 100}"#)
                        .unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("spectrogram plot should succeed");

        let scene = &response.scenes[0];
        assert_eq!(scene.plot_kind, "heatmap2d");
        let FfiPlotLayer::Heatmap { height, dy, .. } = &scene.layers[0] else {
            panic!("expected heatmap layer");
        };
        assert_eq!(*height, 101);
        assert!((dy - 5.0).abs() < 1e-9);
    }

    #[test]
    fn cross_plots_require_two_channels() {
        let (engine, source_id) = engine_with_sines();
        let result = engine.plot(PlotRequest {
            channels: vec![channel(source_id, "chan.a")],
            time_range: full_range(),
            spec: PlotSpec::Coherence(
                serde_json::from_str(r#"{"segment_len": 500}"#).unwrap(),
            ),
            allow_gaps: false,
        });
        assert!(result.is_err());
    }

    #[test]
    fn fft_band_zoom_and_duration_based_length() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Fft(
                    serde_json::from_str(
                        r#"{"segment_duration_s": 1.0, "fmin_hz": 40, "fmax_hz": 60}"#,
                    )
                    .unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("fft plot should succeed");

        let FfiPlotLayer::Line { xs, ys, .. } = &response.scenes[0].layers[0] else {
            panic!("expected line layer");
        };
        // 1.0 s at 1 kHz -> df = 1 Hz; band [40, 60] -> 21 bins from 40 Hz.
        assert_eq!(xs.len(), 21);
        assert!((xs[0] - 40.0).abs() < 1e-9);
        let peak = ys
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap()
            .0;
        assert!((xs[peak] - 50.0).abs() < 1e-9);
    }

    #[test]
    fn coherence_sqrt_and_tf_delay_options() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a"), channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Coherence(
                    serde_json::from_str(r#"{"segment_len": 500, "sqrt": true}"#).unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("sqrt coherence should succeed");
        assert_eq!(response.scenes[0].y_axis.label, "sqrt(Coherence)");

        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a"), channel(source_id, "chan.b")],
                time_range: full_range(),
                spec: PlotSpec::TransferFunction(
                    serde_json::from_str(r#"{"segment_len": 500, "phase_as_delay": true}"#)
                        .unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("tf with delay pane should succeed");
        assert_eq!(response.scenes.len(), 2);
        assert_eq!(response.scenes[1].y_axis.label, "Delay");
        assert_eq!(response.scenes[1].y_axis.unit.as_deref(), Some("s"));
    }

    #[test]
    fn spectrogram_band_zoom_and_manual_color_scale() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Spectrogram(
                    serde_json::from_str(
                        r#"{"segment_len": 200, "step_len": 100,
                            "fmin_hz": 25, "fmax_hz": 100, "z_min": 1e-9, "z_max": 1.0}"#,
                    )
                    .unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("spectrogram plot should succeed");

        let scene = &response.scenes[0];
        // df = 5 Hz: rows 5..=20 survive the [25, 100] Hz zoom.
        let FfiPlotLayer::Heatmap { height, y0, .. } = &scene.layers[0] else {
            panic!("expected heatmap layer");
        };
        assert_eq!(*height, 16);
        assert!((y0 - 25.0).abs() < 1e-9);
        assert_eq!(
            scene.z_axis.as_ref().unwrap().range,
            Some((1e-9, 1.0))
        );
    }

    #[test]
    fn time_plot_resamples_and_honours_manual_y_range() {
        let (engine, source_id) = engine_with_sines();
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::Time(TimePlotSpec {
                    resample_hz: Some(200.0),
                    y_min: Some(-3.0),
                    y_max: Some(3.0),
                    ..TimePlotSpec::default()
                }),
                allow_gaps: false,
            })
            .expect("time plot should succeed");

        let scene = &response.scenes[0];
        assert_eq!(scene.y_axis.range, Some((-3.0, 3.0)));
        let FfiPlotLayer::Line { xs, .. } = &scene.layers[0] else {
            panic!("expected line layer");
        };
        // 8000 samples at 1 kHz decimated by 5 -> 1600 points.
        assert_eq!(xs.len(), 1600);
    }

    #[test]
    fn cross_time_shift_is_applied() {
        let (engine, source_id) = engine_with_sines();
        // chan.a vs chan.a shifted by 10 ms: at 50 Hz that is a half period,
        // so the transfer-function phase at the 50 Hz bin flips to ~pi.
        let response = engine
            .plot(PlotRequest {
                channels: vec![channel(source_id, "chan.a"), channel(source_id, "chan.a")],
                time_range: full_range(),
                spec: PlotSpec::TransferFunction(
                    serde_json::from_str(r#"{"segment_len": 500, "shift_b_s": 0.01}"#)
                        .unwrap(),
                ),
                allow_gaps: false,
            })
            .expect("shifted tf should succeed");

        let FfiPlotLayer::Line { ys, .. } = &response.scenes[1].layers[0] else {
            panic!("expected line layer");
        };
        assert!(
            (ys[25].abs() - std::f64::consts::PI).abs() < 0.05,
            "phase at 50 Hz: {}",
            ys[25]
        );
    }

    #[test]
    fn plot_request_json_contract() {
        let request: PlotRequest = serde_json::from_str(
            r#"{
                "channels": [{"source_id": 1, "channel_id": "chan.a"}],
                "time_range": {"start_ns": 0, "end_ns": 1000000000},
                "spec": {"kind": "fft", "segment_len": 256, "averaging": "median", "db": true}
            }"#,
        )
        .expect("request should parse");

        let PlotSpec::Fft(spec) = &request.spec else {
            panic!("expected fft spec");
        };
        assert_eq!(spec.segment_len, 256);
        assert_eq!(spec.averaging, "median");
        assert!(spec.db);
        assert!(spec.amplitude, "amplitude should default to true");
        assert!((spec.overlap - 0.5).abs() < 1e-12);

        let brms: PlotRequest = serde_json::from_str(
            r#"{
                "channels": [{"source_id": 1, "channel_id": "chan.a"}],
                "time_range": {"start_ns": 0, "end_ns": 1000000000},
                "spec": {"kind": "brms", "fmin_hz": 10, "fmax_hz": 100,
                         "segment_len": 1000, "step_len": 500}
            }"#,
        )
        .expect("brms request should parse");
        assert!(matches!(brms.spec, PlotSpec::Brms(_)));
    }
}

fn plot_brms(series: &[Series1D], spec: &BrmsPlotSpec) -> EngineResult<(String, Vec<PlotScene>)> {
    let rate = sample_rate(&series[0])?;
    let params = BrmsParams {
        fmin_hz: spec.fmin_hz,
        fmax_hz: spec.fmax_hz,
        segment_len: resolve_len(
            spec.segment_len,
            spec.segment_duration_s,
            rate,
            "BRMS FFT length",
        )?,
        step_len: resolve_len(spec.step_len, spec.step_duration_s, rate, "BRMS step")?,
        window: parse_window(&spec.window)?,
        remove_dc: spec.remove_dc,
    };
    let trends: Vec<Series1D> = series
        .iter()
        .map(|one| brms(one, &params).map_err(processing_error))
        .collect::<EngineResult<_>>()?;

    let title = format!(
        "BRMS {}-{} Hz {}",
        spec.fmin_hz,
        spec.fmax_hz,
        channel_names(series)
    );
    let refs: Vec<&Series1D> = trends.iter().collect();
    let mut scene = time_series_scene(&refs, title.clone());
    scene.y_axis.log_scale = spec.log_y;
    apply_y_range(&mut scene, spec.y_min, spec.y_max);
    Ok((title, vec![scene]))
}
