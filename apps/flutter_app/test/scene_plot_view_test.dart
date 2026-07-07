import 'package:datadisplay_app/src/plot_scene.dart';
import 'package:datadisplay_app/src/scene_plot_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpScene(WidgetTester tester, PlotSceneData scene) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            child: SizedBox(
              width: 480,
              height: 320,
              child: ScenePlotView(scene: scene),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('ScenePlotView paints a log-log line scene without exceptions', (
    tester,
  ) async {
    const scene = PlotSceneData(
      title: 'FFT chan.a',
      plotKind: 'line1d',
      xAxis: PlotAxis(
        label: 'Frequency',
        unit: 'Hz',
        logScale: true,
        rangeMin: null,
        rangeMax: null,
      ),
      yAxis: PlotAxis(
        label: 'ASD',
        unit: 'V/√Hz',
        logScale: true,
        rangeMin: null,
        rangeMax: null,
      ),
      zAxis: null,
      epochNs: null,
      timeRange: null,
      layers: [
        // Includes zero / negative samples that must be skipped on log axes.
        LinePlotLayer(
          label: 'chan.a ASD',
          xs: [0.0, 1.0, 10.0, 100.0, 500.0],
          ys: [1e-3, 2e-2, -1.0, 5e-1, 1e-4],
          colorRgba: [0.1, 0.45, 0.95, 1.0],
        ),
        LinePlotLayer(
          label: 'chan.b ASD',
          xs: [1.0, 10.0, 100.0, 500.0],
          ys: [3e-3, 0.0, 2e-1, 4e-3],
          colorRgba: [0.8, 0.3, 0.1, 1.0],
        ),
      ],
    );

    await _pumpScene(tester, scene);
    expect(tester.takeException(), isNull);
    expect(find.byType(ScenePlotView), findsOneWidget);
  });

  testWidgets('ScenePlotView paints a log-z heatmap scene without exceptions', (
    tester,
  ) async {
    final values = <double>[
      for (var column = 0; column < 4; column++)
        for (var row = 0; row < 5; row++)
          // Include a zero to exercise the non-positive clamp on log z.
          column == 0 && row == 0 ? 0.0 : (column + 1) * (row + 1) * 1e-3,
    ];
    final scene = PlotSceneData(
      title: 'Spectrogram chan.a',
      plotKind: 'heatmap2d',
      xAxis: const PlotAxis(
        label: 'Time',
        unit: 's',
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      yAxis: const PlotAxis(
        label: 'Frequency',
        unit: 'Hz',
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      zAxis: const PlotAxis(
        label: 'Power',
        unit: null,
        logScale: true,
        rangeMin: null,
        rangeMax: null,
      ),
      epochNs: 0,
      timeRange: null,
      layers: [
        HeatmapPlotLayer(
          width: 4,
          height: 5,
          x0: 0.0,
          dx: 0.5,
          y0: 0.0,
          dy: 10.0,
          values: values,
        ),
      ],
    );

    await _pumpScene(tester, scene);
    expect(tester.takeException(), isNull);
    expect(find.byType(ScenePlotView), findsOneWidget);
  });

  testWidgets('ScenePlotView shows a placeholder for unsupported kinds', (
    tester,
  ) async {
    const scene = PlotSceneData(
      title: 'Volume',
      plotKind: 'volume3d',
      xAxis: PlotAxis(
        label: 'X',
        unit: null,
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      yAxis: PlotAxis(
        label: 'Y',
        unit: null,
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      zAxis: null,
      epochNs: null,
      timeRange: null,
      layers: [
        VolumePlotLayer(xLen: 1, yLen: 1, zLen: 1, values: [1.0]),
      ],
    );

    await _pumpScene(tester, scene);
    expect(tester.takeException(), isNull);
  });
}
