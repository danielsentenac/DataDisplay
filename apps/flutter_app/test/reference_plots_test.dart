import 'package:datadisplay_app/src/datadisplay_backend.dart';
import 'package:datadisplay_app/src/plot_scene.dart';
import 'package:datadisplay_app/src/reference_plots.dart';
import 'package:flutter_test/flutter_test.dart';

PlotSceneData _lineScene({String? xUnit = 'Hz', String title = 'FFT chan.a'}) {
  return PlotSceneData(
    title: title,
    plotKind: 'line1d',
    xAxis: PlotAxis(
      label: 'Frequency',
      unit: xUnit,
      logScale: true,
      rangeMin: 1.0,
      rangeMax: 500.0,
    ),
    yAxis: const PlotAxis(
      label: 'ASD',
      unit: 'V/√Hz',
      logScale: true,
      rangeMin: null,
      rangeMax: null,
    ),
    zAxis: null,
    epochNs: null,
    timeRange: const TimeRange(startNs: 0, endNs: 8000000000),
    layers: const [
      LinePlotLayer(
        label: 'chan.a ASD',
        xs: [1.0, 2.0, 3.0],
        ys: [0.5, 2.0, 0.25],
        colorRgba: [0.1, 0.45, 0.95, 1.0],
      ),
    ],
  );
}

PlotSceneData _heatmapScene() {
  return const PlotSceneData(
    title: 'Spectrogram chan.a',
    plotKind: 'heatmap2d',
    xAxis: PlotAxis(
      label: 'Time',
      unit: 's',
      logScale: false,
      rangeMin: null,
      rangeMax: null,
    ),
    yAxis: PlotAxis(
      label: 'Frequency',
      unit: 'Hz',
      logScale: false,
      rangeMin: null,
      rangeMax: null,
    ),
    zAxis: null,
    epochNs: null,
    timeRange: null,
    layers: [
      HeatmapPlotLayer(
        width: 1,
        height: 1,
        x0: 0,
        dx: 1,
        y0: 0,
        dy: 1,
        values: [1.0],
      ),
    ],
  );
}

void main() {
  test('reference file round-trips title, timestamp and scenes', () {
    final encoded = encodeReferenceFigure(
      title: 'FFT chan.a',
      savedAt: '2026-07-07T10:00:00.000Z',
      scenes: [_lineScene()],
    );
    final reference = decodeReferenceFigure(
      encoded,
      filePath: '/tmp/fft.ddref.json',
    );

    expect(reference.title, 'FFT chan.a');
    expect(reference.savedAt, '2026-07-07T10:00:00.000Z');
    expect(reference.filePath, '/tmp/fft.ddref.json');
    expect(reference.colorIndex, 0);
    expect(reference.visible, isTrue);
    expect(reference.scenes, hasLength(1));

    final scene = reference.scenes.single;
    expect(scene.plotKind, 'line1d');
    expect(scene.xAxis.unit, 'Hz');
    expect(scene.xAxis.logScale, isTrue);
    expect(scene.xAxis.rangeMin, 1.0);
    expect(scene.timeRange?.endNs, 8000000000);
    final layer = scene.layers.single as LinePlotLayer;
    expect(layer.label, 'chan.a ASD');
    expect(layer.xs, [1.0, 2.0, 3.0]);
    expect(layer.ys, [0.5, 2.0, 0.25]);
    expect(layer.colorRgba, [0.1, 0.45, 0.95, 1.0]);
  });

  test('heatmap figures are refused with a clear message', () {
    expect(referenceSaveBlocker([_lineScene()]), isNull);
    expect(
      referenceSaveBlocker([_lineScene(), _heatmapScene()]),
      contains('Only line plots'),
    );
    expect(referenceSaveBlocker(const []), isNotNull);
  });

  test('decode rejects foreign files, kinds and versions', () {
    expect(
      () => decodeReferenceFigure('not json', filePath: 'x'),
      throwsA(isA<ReferenceFormatException>()),
    );
    expect(
      () => decodeReferenceFigure(
        '{"version": 1, "app": "datadisplay", "kind": "session"}',
        filePath: 'x',
      ),
      throwsA(isA<ReferenceFormatException>()),
    );
    expect(
      () => decodeReferenceFigure(
        '{"version": 2, "app": "datadisplay", "kind": "reference"}',
        filePath: 'x',
      ),
      throwsA(isA<ReferenceFormatException>()),
    );
    expect(
      () => decodeReferenceFigure(
        '{"version": 1, "app": "other", "kind": "reference"}',
        filePath: 'x',
      ),
      throwsA(isA<ReferenceFormatException>()),
    );
  });

  test('compatibility: only visible references with matching x unit apply',
      () {
    final hzReference = LoadedReference(
      filePath: '/tmp/a.ddref.json',
      title: 'Yesterday',
      savedAt: null,
      scenes: [_lineScene()],
      colorIndex: 2,
    );

    // Same x unit (Hz) -> superposed with "(ref)" label and override color.
    final hzTraces = compatibleReferenceTraces([hzReference], _lineScene());
    expect(hzTraces, hasLength(1));
    expect(hzTraces.single.label, 'chan.a ASD (ref)');
    expect(hzTraces.single.color, referencePalette[2]);
    expect(hzTraces.single.xs, [1.0, 2.0, 3.0]);

    // Time scene (unit s) -> the Hz reference is not drawn.
    final timeScene = PlotSceneData(
      title: 'Time chan.a',
      plotKind: 'line1d',
      xAxis: const PlotAxis(
        label: 'Time',
        unit: 's',
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      yAxis: const PlotAxis(
        label: 'Value',
        unit: null,
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      zAxis: null,
      epochNs: 0,
      timeRange: null,
      layers: const [
        LinePlotLayer(label: 'chan.a', xs: [0, 1], ys: [1, 2], colorRgba: []),
      ],
    );
    expect(compatibleReferenceTraces([hzReference], timeScene), isEmpty);

    // Hidden references are skipped.
    hzReference.visible = false;
    expect(compatibleReferenceTraces([hzReference], _lineScene()), isEmpty);

    // Heatmap targets never take reference overlays.
    hzReference.visible = true;
    expect(
      compatibleReferenceTraces([hzReference], _heatmapScene()),
      isEmpty,
    );
  });
}
