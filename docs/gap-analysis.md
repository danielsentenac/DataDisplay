# Gap Analysis & Continuation Plan — Dy (v11r3) → DATADISPLAY rewrite

Date: 2026-07-06.
Reference: original C/XForms/ROOT source at `olserver38:/virgoApp/Dy/v11r3/src` (~40k lines);
rewrite at `/home/sentenac/DATADISPLAY` (Rust workspace + Flutter shell + Java Tomcat backend).

## Where the rewrite stands

The layered architecture (dd-domain → dd-backend → adapters → dd-ffi → Flutter shell) is real,
compiling, and contract-tested (19 Rust tests passing). Genuinely working today:

- **GWF/FFL reading** via native FrameL (adc/proc/sim channels; `ser` metadata-only)
- **HDF5 reading** (pure Rust, rank-1/2/3 datasets, `dd_*` attribute conventions)
- **Tomcat HTTP backend** (channel search, raw/bucketed queries, live polling) backed by the
  Java WAR on olserver134 that bridges FFL archives and shared-memory/Zfd live streams
- **Flutter shell**: catalog browser, multi-channel series deck (overlay/stacked), brush zoom,
  live polling panel, PNG/JPEG/PDF/ASCII export
- Windows installer path in `dist/`, CI-ish build scripts

## Load-bearing gaps (ordered by severity)

1. **No DSP.** `dd-processing` has only `downsample_mean`, a naive `moving_rms`, and a *fake*
   spectrogram (windowed energy with a fabricated taper — no FFT dependency exists anywhere in
   the workspace). Every frequency-domain plot type of the original (FFT, COHERENCE, TRFCT,
   FFTTIME, BRMSTIME, TRFCTTIME, COHETIME — i.e. most of what dataDisplay is used for) is
   currently impossible.
2. **No frequency-domain data model.** `dd-domain` has no `Spectrum`/`FrequencyAxis` block type.
3. **dd-render is orphaned.** The scene model exists (Line1D/Heatmap2D/Volume3D) but is not
   exposed over FFI and not consumed by Flutter; all plotting is ad-hoc Dart `CustomPainter`s.
   The repo's own docs name the "plot scene bridge" as the intended next step.
4. **No session/config persistence** (original: `dy.cfg` capturing channels, plots, params, layout).
5. **Input gaps**: FrSerData (`ser` / SMS slow-monitoring channels) not readable; HDF5 MinMax
   aggregation unimplemented; no native online transport (online data only via the Tomcat Java tier).
6. **Interaction gaps**: no log axes, no cursors/readouts, no per-pad zoom propagation/unzoom-all,
   no reference-plot superposition, no user-defined channel maths, no trigger/ITF-lock gating.
7. **Test depth**: zero tests in dd-processing/dd-render/dd-domain/dd-io-tomcat; no numerical or
   fixture-based integration tests.

## Feature parity matrix (original → rewrite)

| Original capability | Status |
|---|---|
| TIME plots (band-pass, noDC, resampling, offsets, bits) | Partial — raw series only, no filtering/noDC/resample |
| FFT/PSD (Hann, mean/median/decay avg, 1/Hz vs 1/√Hz, dB, RMS curve) | **Missing** |
| TRFCT (module+phase dual pad, delay), COHERENCE (incl. 2D) | **Missing** |
| FFTTIME spectrogram (medY normalize, palettes, logz) | Fake stub |
| BRMSTIME band-limited RMS trends | Missing (only plain moving RMS) |
| 1D/2D distributions, 1DTIME | Missing |
| RAW / RAWTIME image plots | Grid2D plumbing exists; no dedicated view |
| AUDIO playback + WAV export | Missing (niche; modern audio APIs, not OSS) |
| Filtering (Butterworth, filtfilt), anti-alias decimation | **Missing** |
| GWF files + FFL | **Done** (native; `ser` reads missing) |
| Shared memory online (FdShm) | Indirect via Tomcat live polling only |
| Cm servers / DataSender | Out of scope by design (Cm-free); Tomcat is the replacement bridge |
| ASCII / WAV file input | Missing (low effort, low priority) |
| Reference plots (.root save/superpose) | Missing (needs new format) |
| User functions (runtime-compiled C via ROOT) | Missing (needs a different design — expression engine) |
| Trigger / ITF-lock gating | Missing |
| Config save/load (dy.cfg) | Missing |
| Channel browser (search/filter/sort) | **Done** |
| Multi-pad canvas, superposition, zoom | Partial (deck + brush zoom; no log axes/cursors/sync-zoom) |
| Image export (.png/.jpg/.eps/.root) | Done (PNG/JPEG/PDF/ASCII) |
| Batch/headless snapshot mode (`-b`, `-o`) | Missing |
| GWF re-writing / stream recording | Missing (niche) |

Dropped by design (do not port): Cm/ROOT/XForms dependencies, VEGA input, `.car` configs,
OSS `/dev/dsp` audio, coffee panel.

## Continuation plan

### Phase A — DSP core (unblocks everything frequency-domain) — DONE 2026-07-06
1. ✅ `realfft` in `dd-processing`; Hann/Hamming/Blackman/rectangular windows; Welch-segmented
   PSD/ASD (`welch_spectrum`) with the three original averaging modes (fixed-N mean,
   bias-corrected median, exponential-decay running average), `1/Hz` vs `1/√Hz` scaling,
   `spectrum_to_db`, per-segment noDC.
2. ✅ `FrequencyAxis` + `Spectrum` in `dd-domain` (+ `DataBlock::Spectrum`, `StreamKind::Spectrum`,
   FFI mirror types); spectrogram row frequencies via `dd_y_origin_hz`/`dd_y_step_hz` metadata.
3. ✅ `cross_analysis`/`coherence`/`transfer_function` (module + phase, H1 estimator) and
   `phase_to_delay`.
4. ✅ Real FFT spectrogram (`spectrogram_with`, legacy `spectrogram` signature kept),
   per-column FFT averaging, medY row normalization.
5. ✅ `brms` (band-integrated PSD vs time) and `cumulative_rms` spectra curves.
6. ✅ `butterworth_sos` (LP/HP any order, band-pass as HP+LP cascade), `sosfilt`, zero-phase
   `filtfilt`, `bandpass`/`lowpass`/`highpass`, anti-aliased `decimate`, `resample_linear`.
7. ✅ 24 numerical tests (Parseval, flat-noise level, median glitch robustness, coherence
   identities, TF gain/phase/delay recovery, −3 dB points, alias rejection, zero-phase check).
   Still open: validate against original Dy output on a shared GWF file (needs olserver data).

### Phase B — Plot-scene bridge (the repo's own declared next step) — DONE 2026-07-06
1. ✅ `dd-render` rebuilt: time-valued x in seconds against `epoch_ns`, log-scale axis flags,
   per-trace legend labels + default color cycle, positioned heatmaps (`x0/dx/y0/dy` from the
   `dd_y_*_hz` metadata), axis range hints; builders `time_series_scene` / `spectrum_scene` /
   `spectrogram_scene`.
2. ✅ `dd_engine_plot_json`: one call = read + process + scene. Specs: `time` (band-pass, noDC,
   display decimation), `fft` (full Welch parameter set, ASD/PSD, dB, RMS curve), `spectrogram`
   (medY, column averaging), `coherence`, `transfer_function` (returns module + phase panes),
   `brms`. 7 pipeline tests in `dd-ffi` including the JSON contract.
3. ✅ Flutter: `plot()` bound in the native backend (worker isolate), `ScenePlotView` generic
   renderer (log/linear ticks, legends, heatmap + colorbar), new **Analysis** sidebar section
   (channel pickers, plot type, parameters, GPS start/duration → stacked scenes).
   Retiring the remaining ad-hoc series-deck painters can proceed incrementally as the
   Analysis path proves itself.
   Still open: success-path e2e against a real data file (no `.gwf`/`.h5` fixture ships in the
   repo); `averages_per_column` not yet exposed in the UI; `volume3d` renders a placeholder.

### Phase C — Core plot-type parity in the shell — DONE 2026-07-06
TIME, FFT, FFTTIME, COHERENCE, TRFCT, BRMSTIME each expose the original's key controls.
- ✅ Engine: `fmin_hz`/`fmax_hz` band zoom (spectra via `band_slice`, spectrogram row slicing),
  lengths in seconds (`segment_duration_s`/`step_duration_s`, resolved against the channel rate),
  manual `y_min`/`y_max` and spectrogram `z_min`/`z_max` (autoscale when unset), `resample_hz` on
  time plots, `shift_b_s` inter-channel time shift, `sqrt` coherence, `phase_as_delay` TF pane.
  15 dd-ffi pipeline tests (π phase-flip shift check, band-zoom peak, delay pane units...).
- ✅ Shell: Analysis form reworked to seconds-based lengths + all new fields/toggles
  (`lib/src/analysis_spec.dart` makes the emitted JSON unit-testable); heatmap color scale
  honors manual z range; **multi-plot grid deck** (`lib/src/analysis_deck.dart` + controller
  state): Add-to-deck, 1×1…3×3 pad layouts, Compute-all against the shared GPS window,
  per-entry recompute/edit-back-into-form/move/remove. 16 Flutter tests.
  Still open: per-plot refresh/live updating of deck entries (ties into Phase E online story).

### Phase D — Session persistence — DONE 2026-07-07
- ✅ Versioned JSON session (v1): sources, GPS window, pad grid, deck entries
  (`lib/src/session_store.dart`); Save/Load in the Session sidebar section; debounced
  autosave to `$XDG_STATE_HOME/datadisplay/last_session.json` with an explicit
  "Restore last session" banner (never silent); version/app mismatch rejected atomically.
- ✅ One-way `dy.cfg` importer (`lib/src/dy_config_import.dart`, pure function): DY_TIMING/
  DY_INPUT/DY_PADS/DY_PLOT parsing per the original DyConfig.c writer format; maps TIME, FFT,
  TRFCT, COHE, FFTTIME, BRMSTIME (fft_duration→seconds, tstep%→overlap, median/decay averaging,
  hertz→ASD/PSD, ±2e31 auto-range sentinels, superposition merge onto one pad); everything
  unmappable becomes an explicit warning in the import summary (Cm/ONLINE inputs → "use Tomcat",
  unsupported plot types, one-sided filters). Tested against two real production configs.
- ✅ Real-data e2e (`crates/dd-ffi/tests/e2e_gwf.rs`, `--ignored`-gated): 40 s Virgo extract
  (`testdata/dd_e2e_mag.gwf`, V1:ENV_CEB_MAG_N + SEIS, GPS 1467449100) through native FrameL →
  Welch FFT shows the 50 Hz mains line >10× the continuum; spectrogram and self-coherence
  validated. Note: GWF stream ids are `container/name` (e.g. `adc/V1:...`).
  Still open: numerical cross-check against original Dy output on the same file (needs ROOT-side
  export on olserver38); Flutter controller keeps a single active source (multi-source sessions
  reopen only the first URI, with warnings).

### Phase E — Input completion — DONE 2026-07-08
- ✅ FrSerData (`ser`/SMS) reads in dd-io-gwf: stations expand to per-variable
  `ser/STATION.VARIABLE` catalog entries (variables and `units` annotations discovered from the
  first frame's record, FrameL `FrSerDataReadT` under the hood); reads return Series1D on an
  irregular axis (one sample per distinct record, repeated rebroadcasts deduplicated), with
  real units. Validated e2e against a real Virgo SMS station (V1:ENV_CEB_SEIS_N_50Hz_rms).
- ✅ Found and fixed in the process: FrameL keeps global static state, so all native calls are
  now serialized behind one process-wide lock (`framel_files()`); a per-reader mutex was not
  enough and parallel engines corrupted each other's reads.
- ✅ HDF5 MinMax aggregation: `min_max_envelope` in dd-processing returns SampledData with
  sample shape `[2]` (interleaved min/max per bucket).
- **Online-data decision**: the Tomcat Java tier stays the sole live bridge. Rationale: the
  rewrite's goals are Cm-free and cross-platform — Windows/macOS clients cannot map Virgo
  shared memory regardless, and the Tomcat backend already decodes FdShm/Zfd live streams
  server-side (reused dataviewer classes) behind plain HTTP. A native on-site FdShm adapter
  remains possible later behind the same `DataSource` trait (a `dd-io-shm` crate slot) if
  latency profiling ever demands it; nothing in the architecture forecloses it.
- ✅ Shell: reference plots — freeze any computed line figure to a `.ddref.json`
  (`lib/src/reference_plots.dart`), manage in an Analysis "Reference plots" panel
  (load, 8-color palette, show/hide, remove, "Fit references" autoscale toggle), superposed
  dashed with "(ref)" legend suffix on x-unit-compatible line scenes only; persisted in
  sessions (additive, tolerant of old files).
- ✅ Shell: live deck refresh — Live toggle + 5/10/30/60 s interval + "follow now" sliding
  GPS window (duration preserved, 30 s latency margin, `gpsNowSeconds` = unix − 315964800
  + 18 leap s) recomputing all deck entries sequentially with overlap-skip; live config
  persisted in sessions; restoring a live session resumes the loop after the restore compute.
  Still open: dy.cfg import of FFTTIME time-resolution stays approximated; live loop timer
  itself untested (window math unit-tested); references restricted to line1d targets.

### Phase F — Interaction & advanced parity — DONE 2026-07-10 (with recorded deferrals)
- ✅ Engine: user-defined channel maths — hand-rolled expression evaluator in dd-processing
  (`evaluate_expression`: ch0..chN variables, arithmetic incl. `^`, pi/e, 16 one-arg + 4
  two-arg functions; Pratt parser, per-sample eval, rate check + shortest-length truncation);
  wired as the optional request-level `expression` on `dd_engine_plot_json` (replaces the
  original's runtime-compiled C UserOp; single-series plot kinds only).
- ✅ Engine: 1D/2D distributions — `histogram1d`/`histogram2d` in dd-processing (auto or
  manual ranges, NaN-safe, degenerate-constant widening); spec kinds `histogram` (multi-trace
  step curves) and `histogram2d` (value-vs-value heatmap with counts color scale).
- ✅ Shell: "Combine channels" expression field (up to 4 channels via C/D pickers; expression
  travels as a request-level key, persisted in deck entries and sessions); 1D/2D distribution
  plot kinds with bins/range/log controls; hover + pinned cursors with per-trace readouts
  (line scenes and heatmap cells, references included); brush sync-zoom shared across
  same-x-unit deck cells with per-cell Unzoom and deck-level Unzoom all (view-level only,
  no recompute; zoom state not persisted).
- Deferred (recorded, not started): batch/headless snapshot CLI for web monitoring (a
  `dd-snapshot` bin rendering scenes to PNG, e.g. via plotters), trigger/ITF-lock gating
  (can ride on the expression engine as a gate condition), audio playback, GWF re-writing.

### Suggested immediate next actions
- Commit the two uncommitted dd-io-gwf diagnostic changes.
- Start Phase A step 1 (FFT + Welch PSD) — it is prerequisite to most of the parity matrix and
  independent of any UI decision.
