import 'package:datadisplay_app/src/plot_scene.dart';
import 'package:datadisplay_app/src/reference_plots.dart';
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

  testWidgets(
    'ScenePlotView paints dashed reference overlays without exceptions',
    (tester) async {
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
          unit: null,
          logScale: true,
          rangeMin: null,
          rangeMax: null,
        ),
        zAxis: null,
        epochNs: null,
        timeRange: null,
        layers: [
          LinePlotLayer(
            label: 'chan.a ASD',
            xs: [1.0, 10.0, 100.0],
            ys: [1e-3, 5e-2, 1e-4],
            colorRgba: [0.1, 0.45, 0.95, 1.0],
          ),
        ],
      );
      const references = [
        // Includes non-positive values that must be skipped on log axes.
        ReferenceTrace(
          label: 'yesterday (ref)',
          xs: [0.0, 1.0, 10.0, 100.0],
          ys: [1e-2, 2e-3, 0.0, 2e-4],
          color: Color(0xFF7B1FA2),
        ),
      ];

      for (final fit in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  child: SizedBox(
                    width: 480,
                    height: 320,
                    child: ScenePlotView(
                      scene: scene,
                      references: references,
                      fitReferences: fit,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    },
  );

  test('nearestIndexForX snaps to the closest monotonic sample', () {
    expect(nearestIndexForX(const [], 5), -1);
    const xs = [0.0, 1.0, 2.0, 5.0, 10.0];
    expect(nearestIndexForX(xs, -3), 0);
    expect(nearestIndexForX(xs, 0.4), 0);
    expect(nearestIndexForX(xs, 0.6), 1);
    expect(nearestIndexForX(xs, 3.4), 2);
    expect(nearestIndexForX(xs, 4.0), 3);
    expect(nearestIndexForX(xs, 99), 4);
  });

  test('formatReadoutValue switches to scientific outside 1e-2..1e4', () {
    expect(formatReadoutValue(0), '0');
    expect(formatReadoutValue(double.nan), '—');
    expect(formatReadoutValue(1.2345), '1.234');
    expect(formatReadoutValue(123.456), '123.5');
    expect(formatReadoutValue(0.5), '0.500');
    // Scientific for tiny and huge magnitudes.
    expect(formatReadoutValue(0.005), '5.000e-3');
    expect(formatReadoutValue(12000.0), '1.200e+4');
    expect(formatReadoutValue(-3.2e-8), '-3.200e-8');
  });

  testWidgets('tap pins a cursor readout on a line scene', (tester) async {
    const scene = PlotSceneData(
      title: 'Time chan.a',
      plotKind: 'line1d',
      xAxis: PlotAxis(
        label: 'Time',
        unit: 's',
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      yAxis: PlotAxis(
        label: 'Value',
        unit: null,
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      zAxis: null,
      epochNs: 0,
      timeRange: null,
      layers: [
        LinePlotLayer(
          label: 'chan.a',
          xs: [0.0, 1.0, 2.0, 3.0, 4.0],
          ys: [0.0, 1.0, 0.5, 2.0, 1.5],
          colorRgba: [0.1, 0.45, 0.95, 1.0],
        ),
      ],
    );

    await _pumpScene(tester, scene);
    final origin = tester.getTopLeft(find.byType(ScenePlotView));
    // Inside the plot rect (insets 78 left, 40 top).
    await tester.tapAt(origin + const Offset(240, 160));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Second tap unpins.
    await tester.tapAt(origin + const Offset(240, 160));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap pins an (x, y, z) readout on a heatmap scene', (
    tester,
  ) async {
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
          height: 4,
          x0: 0,
          dx: 1,
          y0: 0,
          dy: 10,
          values: [for (var i = 0; i < 16; i++) (i + 1).toDouble()],
        ),
      ],
    );

    await _pumpScene(tester, scene);
    final origin = tester.getTopLeft(find.byType(ScenePlotView));
    await tester.tapAt(origin + const Offset(200, 150));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal drag reports an x-range zoom', (tester) async {
    const scene = PlotSceneData(
      title: 'Time chan.a',
      plotKind: 'line1d',
      xAxis: PlotAxis(
        label: 'Time',
        unit: 's',
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      yAxis: PlotAxis(
        label: 'Value',
        unit: null,
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      zAxis: null,
      epochNs: 0,
      timeRange: null,
      layers: [
        LinePlotLayer(
          label: 'chan.a',
          xs: [0.0, 100.0],
          ys: [0.0, 1.0],
          colorRgba: [0.1, 0.45, 0.95, 1.0],
        ),
      ],
    );

    final zooms = <(double, double)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              height: 320,
              child: ScenePlotView(
                scene: scene,
                onXZoom: (xMin, xMax) => zooms.add((xMin, xMax)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final origin = tester.getTopLeft(find.byType(ScenePlotView));
    // Plot rect spans x in 78..458 (data 0..100). Drag across the middle.
    await tester.timedDragFrom(
      origin + const Offset(173, 160),
      const Offset(190, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(zooms, hasLength(1));
    final (xMin, xMax) = zooms.single;
    expect(xMax, greaterThan(xMin));
    // Roughly the dragged quarter-to-three-quarter span (touch slop allowed).
    expect(xMin, inInclusiveRange(15.0, 40.0));
    expect(xMax, inInclusiveRange(60.0, 85.0));
  });

  testWidgets('renders a histogram step scene with an x viewport', (
    tester,
  ) async {
    // Step curve as returned by the engine histogram (2 points per bin).
    const scene = PlotSceneData(
      title: '1D distribution chan.a',
      plotKind: 'line1d',
      xAxis: PlotAxis(
        label: 'Value',
        unit: 'V',
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      yAxis: PlotAxis(
        label: 'Counts',
        unit: null,
        logScale: false,
        rangeMin: null,
        rangeMax: null,
      ),
      zAxis: null,
      epochNs: null,
      timeRange: null,
      layers: [
        LinePlotLayer(
          label: 'chan.a',
          xs: [-1.0, -0.5, -0.5, 0.0, 0.0, 0.5, 0.5, 1.0],
          ys: [120.0, 120.0, 40.0, 40.0, 44.0, 44.0, 130.0, 130.0],
          colorRgba: [0.1, 0.45, 0.95, 1.0],
        ),
      ],
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              height: 320,
              child: ScenePlotView(scene: scene, xViewport: (-0.6, 0.6)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
