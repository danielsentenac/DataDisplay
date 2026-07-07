//! End-to-end validation against a real Virgo GWF extract (not shipped with
//! the repository). The fixture is 40 s of V1:ENV_CEB_MAG_N (magnetometer)
//! and V1:ENV_CEB_SEIS_N starting at GPS 1467449100, produced with FrCopy
//! from raw data. Regenerate on olserver38 with:
//!
//! ```text
//! FrCopy -i <raw.gwf> -o testdata/dd_e2e_mag.gwf \
//!        -t "V1:ENV_CEB_MAG_N V1:ENV_CEB_SEIS_N" -f 1467449100 -l 40
//! ```
//!
//! Run explicitly (needs native FrameL compiled in):
//! `cargo test -p dd-ffi --test e2e_gwf -- --ignored`

use dd_ffi::{
    DatadisplayEngine, FfiPlotLayer, FfiTimeRange, OpenSourceRequest, PlotChannelRef,
    PlotRequest, PlotSpec,
};

const GPS_START: i64 = 1_467_449_100;
const DURATION_S: i64 = 40;
// GWF stream ids are `container/name` (adc, proc, sim).
const MAG_CHANNEL: &str = "adc/V1:ENV_CEB_MAG_N";

fn fixture_path() -> String {
    format!(
        "{}/../../testdata/dd_e2e_mag.gwf",
        env!("CARGO_MANIFEST_DIR")
    )
}

fn full_range() -> FfiTimeRange {
    FfiTimeRange {
        start_ns: GPS_START * 1_000_000_000,
        end_ns: (GPS_START + DURATION_S) * 1_000_000_000,
    }
}

#[test]
#[ignore = "needs testdata/dd_e2e_mag.gwf and native FrameL support"]
fn fft_of_real_magnetometer_shows_the_mains_line() {
    let path = fixture_path();
    assert!(
        std::path::Path::new(&path).exists(),
        "fixture missing: {path}"
    );

    let mut engine = DatadisplayEngine::default();
    let open = engine
        .open_source(OpenSourceRequest {
            uri: format!("gwf://{path}"),
        })
        .expect("real GWF extract should open through native FrameL");

    let response = engine
        .plot(PlotRequest {
            channels: vec![PlotChannelRef {
                source_id: open.source_id,
                channel_id: MAG_CHANNEL.to_string(),
            }],
            time_range: full_range(),
            spec: PlotSpec::Fft(
                serde_json::from_str(
                    r#"{"segment_duration_s": 4.0, "averaging": "median",
                        "fmin_hz": 1.0, "fmax_hz": 200.0}"#,
                )
                .unwrap(),
            ),
            allow_gaps: false,
        })
        .expect("FFT plot of real magnetometer data should succeed");

    let FfiPlotLayer::Line { xs, ys, .. } = &response.scenes[0].layers[0] else {
        panic!("expected line layer");
    };
    assert!(ys.iter().all(|value| value.is_finite() && *value >= 0.0));

    // The 50 Hz mains line must tower over the surrounding continuum.
    let level_at = |target_hz: f64| -> f64 {
        xs.iter()
            .zip(ys.iter())
            .filter(|(x, _)| (**x - target_hz).abs() < 0.5)
            .map(|(_, y)| *y)
            .fold(0.0f64, f64::max)
    };
    let continuum: f64 = {
        let band: Vec<f64> = xs
            .iter()
            .zip(ys.iter())
            .filter(|(x, _)| (30.0..45.0).contains(*x))
            .map(|(_, y)| *y)
            .collect();
        band.iter().sum::<f64>() / band.len() as f64
    };
    let mains = level_at(50.0);
    assert!(
        mains > 10.0 * continuum,
        "50 Hz line ({mains:.3e}) should dominate the 30-45 Hz continuum ({continuum:.3e})"
    );
}

#[test]
#[ignore = "needs testdata/dd_e2e_mag.gwf and native FrameL support"]
fn spectrogram_and_coherence_run_on_real_data() {
    let path = fixture_path();
    assert!(
        std::path::Path::new(&path).exists(),
        "fixture missing: {path}"
    );

    let mut engine = DatadisplayEngine::default();
    let open = engine
        .open_source(OpenSourceRequest {
            uri: format!("gwf://{path}"),
        })
        .expect("real GWF extract should open");

    let spectrogram = engine
        .plot(PlotRequest {
            channels: vec![PlotChannelRef {
                source_id: open.source_id,
                channel_id: MAG_CHANNEL.to_string(),
            }],
            time_range: full_range(),
            spec: PlotSpec::Spectrogram(
                serde_json::from_str(
                    r#"{"segment_duration_s": 2.0, "step_duration_s": 1.0,
                        "fmin_hz": 1.0, "fmax_hz": 100.0}"#,
                )
                .unwrap(),
            ),
            allow_gaps: false,
        })
        .expect("spectrogram of real data should succeed");
    let FfiPlotLayer::Heatmap { width, height, values, .. } =
        &spectrogram.scenes[0].layers[0]
    else {
        panic!("expected heatmap layer");
    };
    assert!(*width >= 30, "expected ~39 columns, got {width}");
    assert_eq!(values.len(), width * height);
    assert!(values.iter().all(|value| value.is_finite()));

    // Coherence of a channel with itself stays a valid identity on real data.
    let coherence = engine
        .plot(PlotRequest {
            channels: vec![
                PlotChannelRef {
                    source_id: open.source_id,
                    channel_id: MAG_CHANNEL.to_string(),
                },
                PlotChannelRef {
                    source_id: open.source_id,
                    channel_id: MAG_CHANNEL.to_string(),
                },
            ],
            time_range: full_range(),
            spec: PlotSpec::Coherence(
                serde_json::from_str(r#"{"segment_duration_s": 2.0}"#).unwrap(),
            ),
            allow_gaps: false,
        })
        .expect("self coherence on real data should succeed");
    let FfiPlotLayer::Line { ys, .. } = &coherence.scenes[0].layers[0] else {
        panic!("expected line layer");
    };
    let high = ys.iter().filter(|value| **value > 0.999).count();
    assert!(
        high as f64 > 0.95 * ys.len() as f64,
        "self coherence should be ~1 in nearly every bin ({high}/{})",
        ys.len()
    );
}
