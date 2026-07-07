import 'package:datadisplay_app/src/analysis_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnalysisSpecForm.build', () {
    test('time spec includes new optional fields only when set', () {
      final full = AnalysisSpecForm(
        kind: AnalysisPlotKind.time,
        bandLow: '5',
        bandHigh: '50',
        filterOrder: '6',
        resampleHz: '200',
        maxPoints: '4096',
        yMin: '-2',
        yMax: '2',
        removeDc: true,
        logY: false,
      ).build();

      expect(full['kind'], 'time');
      expect(full['band_hz'], [5.0, 50.0]);
      expect(full['filter_order'], 6);
      expect(full['resample_hz'], 200.0);
      expect(full['max_points'], 4096);
      expect(full['y_min'], -2.0);
      expect(full['y_max'], 2.0);
      expect(full['remove_dc'], true);
      expect(full['log_y'], false);

      final minimal = AnalysisSpecForm(kind: AnalysisPlotKind.time).build();
      expect(minimal.containsKey('band_hz'), isFalse);
      expect(minimal.containsKey('resample_hz'), isFalse);
      expect(minimal.containsKey('max_points'), isFalse);
      expect(minimal.containsKey('y_min'), isFalse);
      expect(minimal.containsKey('y_max'), isFalse);
      expect(minimal['filter_order'], 4);
    });

    test('fft spec sends seconds-based length and frequency zoom', () {
      final spec = AnalysisSpecForm(
        kind: AnalysisPlotKind.fft,
        segmentSeconds: '2.5',
        overlap: '0.75',
        window: 'blackman',
        averaging: 'decay',
        maxSegments: '12',
        decayCount: '10',
        fmin: '5',
        fmax: '400',
        yMin: '1e-9',
        yMax: '1e-3',
        db: true,
      ).build();

      expect(spec['kind'], 'fft');
      expect(spec['segment_duration_s'], 2.5);
      expect(spec.containsKey('segment_len'), isFalse);
      expect(spec['overlap'], 0.75);
      expect(spec['window'], 'blackman');
      expect(spec['averaging'], 'decay');
      expect(spec['max_segments'], 12);
      expect(spec['decay_count'], 10.0);
      expect(spec['fmin_hz'], 5.0);
      expect(spec['fmax_hz'], 400.0);
      expect(spec['y_min'], 1e-9);
      expect(spec['y_max'], 1e-3);
      expect(spec['db'], true);

      final minimal = AnalysisSpecForm(kind: AnalysisPlotKind.fft).build();
      expect(minimal['segment_duration_s'], 1.0);
      expect(minimal.containsKey('fmin_hz'), isFalse);
      expect(minimal.containsKey('fmax_hz'), isFalse);
      expect(minimal.containsKey('y_min'), isFalse);
      expect(minimal.containsKey('decay_count'), isFalse);
      expect(minimal.containsKey('max_segments'), isFalse);
      expect(minimal['amplitude'], true);
      expect(minimal['log_x'], true);
      expect(minimal['log_y'], true);
    });

    test('spectrogram spec exposes step, averages and manual z range', () {
      final spec = AnalysisSpecForm(
        kind: AnalysisPlotKind.spectrogram,
        segmentSeconds: '1',
        stepSeconds: '0.25',
        averagesPerColumn: '4',
        fmin: '10',
        fmax: '1000',
        zMin: '1e-10',
        zMax: '1e-4',
        medianNormalize: true,
        logZ: false,
      ).build();

      expect(spec['kind'], 'spectrogram');
      expect(spec['segment_duration_s'], 1.0);
      expect(spec['step_duration_s'], 0.25);
      expect(spec['averages_per_column'], 4);
      expect(spec['fmin_hz'], 10.0);
      expect(spec['fmax_hz'], 1000.0);
      expect(spec['z_min'], 1e-10);
      expect(spec['z_max'], 1e-4);
      expect(spec['median_normalize'], true);
      expect(spec['log_z'], false);

      final minimal = AnalysisSpecForm(
        kind: AnalysisPlotKind.spectrogram,
      ).build();
      expect(minimal.containsKey('averages_per_column'), isFalse);
      expect(minimal.containsKey('z_min'), isFalse);
      expect(minimal.containsKey('z_max'), isFalse);
      expect(minimal['step_duration_s'], 0.5);
    });

    test('coherence spec sends shift and sqrt; TF sends phase_as_delay', () {
      final coherence = AnalysisSpecForm(
        kind: AnalysisPlotKind.coherence,
        segmentSeconds: '4',
        shiftB: '-0.125',
        sqrtCoherence: true,
        fmin: '2',
        yMin: '0.1',
        yMax: '1',
      ).build();

      expect(coherence['kind'], 'coherence');
      expect(coherence['segment_duration_s'], 4.0);
      expect(coherence['shift_b_s'], -0.125);
      expect(coherence['sqrt'], true);
      expect(coherence.containsKey('phase_as_delay'), isFalse);
      expect(coherence['fmin_hz'], 2.0);
      expect(coherence.containsKey('fmax_hz'), isFalse);
      expect(coherence['y_min'], 0.1);
      expect(coherence['y_max'], 1.0);

      final tf = AnalysisSpecForm(
        kind: AnalysisPlotKind.transferFunction,
        phaseAsDelay: true,
      ).build();
      expect(tf['kind'], 'transfer_function');
      expect(tf['phase_as_delay'], true);
      expect(tf.containsKey('sqrt'), isFalse);
      expect(tf['shift_b_s'], 0.0);
    });

    test('brms spec keeps required band and adds seconds lengths + y range',
        () {
      final spec = AnalysisSpecForm(
        kind: AnalysisPlotKind.brms,
        brmsFmin: '10',
        brmsFmax: '90',
        segmentSeconds: '2',
        stepSeconds: '1',
        yMin: '1e-8',
      ).build();

      expect(spec['kind'], 'brms');
      expect(spec['fmin_hz'], 10.0);
      expect(spec['fmax_hz'], 90.0);
      expect(spec['segment_duration_s'], 2.0);
      expect(spec['step_duration_s'], 1.0);
      expect(spec['y_min'], 1e-8);
      expect(spec.containsKey('y_max'), isFalse);
      expect(spec.containsKey('segment_len'), isFalse);
      expect(spec.containsKey('step_len'), isFalse);
    });

    test('invalid input raises AnalysisSpecException', () {
      expect(
        () => AnalysisSpecForm(
          kind: AnalysisPlotKind.fft,
          segmentSeconds: '',
        ).build(),
        throwsA(isA<AnalysisSpecException>()),
      );
      expect(
        () => AnalysisSpecForm(
          kind: AnalysisPlotKind.fft,
          fmin: '100',
          fmax: '10',
        ).build(),
        throwsA(isA<AnalysisSpecException>()),
      );
      expect(
        () => AnalysisSpecForm(
          kind: AnalysisPlotKind.time,
          bandLow: '5',
        ).build(),
        throwsA(isA<AnalysisSpecException>()),
      );
      expect(
        () => AnalysisSpecForm(
          kind: AnalysisPlotKind.spectrogram,
          zMin: '10',
          zMax: '1',
        ).build(),
        throwsA(isA<AnalysisSpecException>()),
      );
      expect(
        () => AnalysisSpecForm(
          kind: AnalysisPlotKind.brms,
          brmsFmin: '100',
          brmsFmax: '10',
        ).build(),
        throwsA(isA<AnalysisSpecException>()),
      );
    });
  });

  group('AnalysisSpecForm.fromSpec', () {
    test('round-trips a built spec back into form values', () {
      final original = AnalysisSpecForm(
        kind: AnalysisPlotKind.transferFunction,
        segmentSeconds: '4',
        overlap: '0.66',
        window: 'hamming',
        averaging: 'median',
        shiftB: '0.5',
        fmin: '3',
        fmax: '300',
        yMin: '0.01',
        phaseAsDelay: true,
        removeDc: true,
        logX: false,
        logY: false,
      );
      final restored = AnalysisSpecForm.fromSpec(original.build());

      expect(restored.kind, AnalysisPlotKind.transferFunction);
      expect(restored.segmentSeconds, '4');
      expect(restored.overlap, '0.66');
      expect(restored.window, 'hamming');
      expect(restored.averaging, 'median');
      expect(restored.shiftB, '0.5');
      expect(restored.fmin, '3');
      expect(restored.fmax, '300');
      expect(restored.yMin, '0.01');
      expect(restored.yMax, '');
      expect(restored.phaseAsDelay, isTrue);
      expect(restored.removeDc, isTrue);
      expect(restored.logX, isFalse);
      expect(restored.logY, isFalse);

      // Rebuilding from the restored form yields the same wire spec.
      expect(restored.build(), original.build());
    });

    test('restores the BRMS band into the dedicated fields', () {
      final restored = AnalysisSpecForm.fromSpec(
        AnalysisSpecForm(
          kind: AnalysisPlotKind.brms,
          brmsFmin: '15',
          brmsFmax: '85',
        ).build(),
      );
      expect(restored.kind, AnalysisPlotKind.brms);
      expect(restored.brmsFmin, '15');
      expect(restored.brmsFmax, '85');
      expect(restored.fmin, '');
      expect(restored.fmax, '');
    });
  });
}
