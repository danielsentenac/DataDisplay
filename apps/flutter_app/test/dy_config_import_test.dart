import 'package:datadisplay_app/src/dy_config_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real production config: TIME plot, ONLINE (Cm) input, auto pads,
/// endless duration.
const _fixtureTime = '''
/*** Made on 05_Jun_2026_10:14:30 by sentenac using dataDisplay v10r17 on (null) (display=localhost:10.0) ***/

DY_TIMING
 starttime 1464682484.000000  (Fri Jun  5 08:14:26 2026)
 duration  -1.000000

DY_OPTIONS
 debug            0
 fullwhite        1

DY_INPUT
 chindex 0  V1:AATuning_LOOP_ENBL
 inputtype 1  ONLINE
 inputname FbmMainUsers

DY_PADS
 ncol 0
 nrow 0

DY_PLOT 1 dy1
 type           7 TIME
 numpad         1
 superposed     0
 hidden         0
 chx_name       V1:VAC_DELTAP2_PRESSURE
 chx_inputname  FbmMainUsers
 chx_inputtype  1
 chx_sampFreq   1
 chx_resampFreq 1
 chx_realunits  1
 gridx          1
 gridy          1
 logx           0
 logy           0
 ydb            0
 tsize         4
 tstep         50
 ymin          2e+31
 ymax          -2e+31
 yoffset       0
 yscale        0
 bits          0
 nodc          0
 autoscale     1
 filter_fmin   0
 filter_fmax   0
''';

/// Real production config: FFT plot plus a superposed FFT on the same pad
/// (the "(same remaining keys)" shorthand in the source expanded verbatim).
const _fixtureFftSuperposed = '''
DY_PLOT 1 dy1
 type           8 FFT
 numpad         1
 superposed     0
 hidden         0
 chx_name       V1:LSC_DARM
 chx_inputname  FbmMainUsers
 chx_inputtype  1
 chx_sampFreq   10000
 chx_resampFreq 10000
 chx_realunits  1
 gridx          1
 gridy          1
 logx           1
 logy           1
 ydb            0
 fft_duration  2
 tstep         50
 max_average   10
 refresh_fft   1
 fmin          0
 fmax          5000
 ymin          2e+31
 ymax          -2e+31
 yscale        1
 hertz         0
 median        0
 rmsfft        0
 decayfft      0
 nodc          1
 autoscale     1
 filter_fmin   0
 filter_fmax   0

DY_PLOT 2 dy2
 type           8 FFT
 numpad         1
 superposed     1
 hidden         0
 chx_name       V1:LSC_DARM_NOISE
 chx_inputname  FbmMainUsers
 chx_inputtype  1
 chx_sampFreq   10000
 chx_resampFreq 10000
 chx_realunits  1
 gridx          1
 gridy          1
 logx           1
 logy           1
 ydb            0
 fft_duration  2
 tstep         50
 max_average   10
 refresh_fft   1
 fmin          0
 fmax          5000
 ymin          2e+31
 ymax          -2e+31
 yscale        1
 hertz         0
 median        0
 rmsfft        0
 decayfft      0
 nodc          1
 autoscale     1
 filter_fmin   0
 filter_fmax   0
''';

void main() {
  test('TIME fixture: timing, ONLINE warning, auto pads, time plot mapping',
      () {
    final result = parseDyConfig(_fixtureTime);

    expect(result.gpsStartSeconds, 1464682484.0);
    expect(result.durationSeconds, isNull);
    expect(
      result.warnings,
      contains(
        'duration is -1 (endless/online) — duration left unchanged.',
      ),
    );
    expect(
      result.warnings.where(
        (warning) =>
            warning.contains('V1:AATuning_LOOP_ENBL') &&
            warning.contains('ONLINE (Cm)') &&
            warning.contains('Tomcat'),
      ),
      hasLength(1),
    );

    // `ncol 0 / nrow 0` means automatic pads: keep the current grid.
    expect(result.gridColumns, isNull);
    expect(result.gridRows, isNull);
    // ONLINE input maps to no source URI.
    expect(result.sourceUris, isEmpty);

    expect(result.importedCount, 1);
    expect(result.skippedCount, 0);
    final plot = result.plots.single;
    expect(plot.channels, ['V1:VAC_DELTAP2_PRESSURE']);
    expect(plot.label, 'Time V1:VAC_DELTAP2_PRESSURE');
    expect(plot.spec['kind'], 'time');
    expect(plot.spec['remove_dc'], false);
    expect(plot.spec['log_y'], false);
    // filter 0/0 -> no band, no warning; resamp == samp -> no resample.
    expect(plot.spec.containsKey('band_hz'), isFalse);
    expect(plot.spec.containsKey('resample_hz'), isFalse);
    // autoscale 1 + sentinel ymin/ymax -> auto range.
    expect(plot.spec.containsKey('y_min'), isFalse);
    expect(plot.spec.containsKey('y_max'), isFalse);
  });

  test('FFT fixture: superposed plot merges into one multi-channel entry',
      () {
    final result = parseDyConfig(_fixtureFftSuperposed);

    expect(result.importedCount, 1);
    expect(result.skippedCount, 0);
    final plot = result.plots.single;
    expect(plot.channels, ['V1:LSC_DARM', 'V1:LSC_DARM_NOISE']);
    expect(plot.label, 'FFT V1:LSC_DARM, V1:LSC_DARM_NOISE');

    final spec = plot.spec;
    expect(spec['kind'], 'fft');
    expect(spec['segment_duration_s'], 2.0);
    expect(spec['overlap'], 0.5); // tstep 50% -> 1 - 0.5
    expect(spec['max_segments'], 10);
    expect(spec['amplitude'], true); // hertz 0
    expect(spec['db'], false);
    expect(spec['rms_curve'], false);
    expect(spec['remove_dc'], true); // nodc 1
    expect(spec['log_x'], true);
    expect(spec['log_y'], true);
    expect(spec.containsKey('averaging'), isFalse); // mean by default
    // fmin 0 omitted; fmax 5000 == sampFreq/2 omitted.
    expect(spec.containsKey('fmin_hz'), isFalse);
    expect(spec.containsKey('fmax_hz'), isFalse);
    expect(spec.containsKey('y_min'), isFalse);
    expect(spec.containsKey('y_max'), isFalse);
  });

  test('superposed plot with different parameters stays on its own pad', () {
    // Change the SECOND plot's fft_duration so the specs no longer match.
    final parts = _fixtureFftSuperposed.split('DY_PLOT 2 dy2');
    final modified =
        '${parts[0]}DY_PLOT 2 dy2${parts[1].replaceFirst('fft_duration  2', 'fft_duration  4')}';

    final result = parseDyConfig(modified);
    expect(result.importedCount, 2);
    expect(result.plots[0].channels, ['V1:LSC_DARM']);
    expect(result.plots[1].channels, ['V1:LSC_DARM_NOISE']);
    expect(result.plots[1].spec['segment_duration_s'], 4.0);
    expect(
      result.warnings.where(
        (warning) =>
            warning.contains('superposed') && warning.contains('dy2'),
      ),
      hasLength(1),
    );
  });

  test('unsupported plot types are skipped with a warning', () {
    const text = '''
DY_PLOT 1 dy1
 type           2 1D
 numpad         1
 superposed     0
 hidden         0
 chx_name       V1:SOMETHING
''';
    final result = parseDyConfig(text);
    expect(result.importedCount, 0);
    expect(result.skippedCount, 1);
    expect(
      result.warnings.single,
      allOf(contains('1D'), contains('not supported yet')),
    );
  });

  test('hidden plots are skipped with a warning', () {
    const text = '''
DY_PLOT 1 dy1
 type           7 TIME
 numpad         1
 superposed     0
 hidden         1
 chx_name       V1:SOMETHING
''';
    final result = parseDyConfig(text);
    expect(result.importedCount, 0);
    expect(result.skippedCount, 1);
    expect(result.warnings.single, contains('hidden'));
  });

  test('GWF_FILE inputs map to deduplicated source uris', () {
    const text = '''
DY_INPUT
 chindex 0  V1:LSC_DARM
 inputtype 0  GWF_FILE
 inputname /virgoData/ffl/raw.ffl
 chindex 1  V1:LSC_MICH
 inputtype 0  GWF_FILE
 inputname /virgoData/ffl/raw.ffl
 chindex 2  V1:Hrec_hoft
 inputtype 0  GWF_FILE
 inputname /data/V-raw-1446446000-100.gwf
''';
    final result = parseDyConfig(text);
    expect(result.sourceUris, [
      'ffl:///virgoData/ffl/raw.ffl',
      'gwf:///data/V-raw-1446446000-100.gwf',
    ]);
    expect(result.warnings, isEmpty);
  });

  test('pad grid is clamped to supported shapes with a warning', () {
    const text = '''
DY_PADS
 ncol 4
 nrow 5
''';
    final result = parseDyConfig(text);
    expect(result.gridColumns, 3);
    expect(result.gridRows, 3);
    expect(result.warnings.single, contains('clamped'));
  });

  test('coherence plots take both channels and cross parameters', () {
    const text = '''
DY_PLOT 1 dy1
 type           10 COHE
 numpad         2
 superposed     0
 hidden         0
 chx_name       V1:LSC_DARM
 chx_sampFreq   10000
 chy_name       V1:LSC_MICH
 logx           1
 logy           0
 fft_duration  1
 tstep         50
 max_average   0
 fmin          2
 fmax          100
 median        1
 nodc          0
 autoscale     1
''';
    final result = parseDyConfig(text);
    final plot = result.plots.single;
    expect(plot.spec['kind'], 'coherence');
    expect(plot.channels, ['V1:LSC_DARM', 'V1:LSC_MICH']);
    expect(plot.label, 'Coherence V1:LSC_DARM / V1:LSC_MICH');
    expect(plot.spec['segment_duration_s'], 1.0);
    expect(plot.spec['averaging'], 'median');
    expect(plot.spec.containsKey('max_segments'), isFalse);
    expect(plot.spec['fmin_hz'], 2.0);
    expect(plot.spec['fmax_hz'], 100.0);
    expect(plot.spec['log_x'], true);
    expect(plot.spec['log_y'], false);
  });
}
