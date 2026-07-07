import 'dart:convert';

import 'package:datadisplay_app/src/plot_scene.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtureJson = '''
{
  "title": "FFT chan.a",
  "scenes": [
    {
      "title": "FFT chan.a",
      "plot_kind": "line1d",
      "x_axis": {
        "label": "Frequency",
        "unit": "Hz",
        "log_scale": true,
        "range": [1.0, 500.0]
      },
      "y_axis": {
        "label": "ASD",
        "unit": "V/\\u221aHz",
        "log_scale": true,
        "range": null
      },
      "z_axis": null,
      "epoch_ns": null,
      "time_range": {"start_ns": 0, "end_ns": 8000000000},
      "layers": [
        {
          "kind": "line",
          "label": "chan.a ASD",
          "xs": [1.0, 2.0, 3.0],
          "ys": [0.5, 2.0, 0.25],
          "color_rgba": [0.1, 0.45, 0.95, 1.0]
        },
        {
          "kind": "line",
          "label": "chan.b ASD",
          "xs": [1.0, 2.0, 3.0],
          "ys": [1.5, 0.75, 0.5],
          "color_rgba": [0.8, 0.3, 0.1, 1.0]
        }
      ]
    },
    {
      "title": "Spectrogram chan.a",
      "plot_kind": "heatmap2d",
      "x_axis": {
        "label": "Time",
        "unit": "s",
        "log_scale": false,
        "range": null
      },
      "y_axis": {
        "label": "Frequency",
        "unit": "Hz",
        "log_scale": false,
        "range": null
      },
      "z_axis": {
        "label": "Power",
        "unit": null,
        "log_scale": true,
        "range": null
      },
      "epoch_ns": 1000000000,
      "time_range": null,
      "layers": [
        {
          "kind": "heatmap",
          "width": 2,
          "height": 3,
          "x0": 0.0,
          "dx": 0.1,
          "y0": 0.0,
          "dy": 5.0,
          "values": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        }
      ]
    }
  ]
}
''';

void main() {
  test('PlotFigure parses a line + heatmap response fixture', () {
    final figure = PlotFigure.fromJson(
      jsonDecode(_fixtureJson) as Map<String, dynamic>,
    );

    expect(figure.title, 'FFT chan.a');
    expect(figure.scenes, hasLength(2));

    final lineScene = figure.scenes[0];
    expect(lineScene.plotKind, 'line1d');
    expect(lineScene.xAxis.label, 'Frequency');
    expect(lineScene.xAxis.unit, 'Hz');
    expect(lineScene.xAxis.logScale, isTrue);
    expect(lineScene.xAxis.hasRange, isTrue);
    expect(lineScene.xAxis.rangeMin, 1.0);
    expect(lineScene.xAxis.rangeMax, 500.0);
    expect(lineScene.yAxis.hasRange, isFalse);
    expect(lineScene.zAxis, isNull);
    expect(lineScene.epochNs, isNull);
    expect(lineScene.timeRange?.startNs, 0);
    expect(lineScene.timeRange?.endNs, 8000000000);
    expect(lineScene.lineLayers, hasLength(2));

    final firstLine = lineScene.layers.first as LinePlotLayer;
    expect(firstLine.label, 'chan.a ASD');
    expect(firstLine.xs, [1.0, 2.0, 3.0]);
    expect(firstLine.ys, [0.5, 2.0, 0.25]);
    expect(firstLine.colorRgba, [0.1, 0.45, 0.95, 1.0]);

    final heatmapScene = figure.scenes[1];
    expect(heatmapScene.plotKind, 'heatmap2d');
    expect(heatmapScene.zAxis?.logScale, isTrue);
    expect(heatmapScene.epochNs, 1000000000);

    final heatmap = heatmapScene.firstHeatmapLayer;
    expect(heatmap, isNotNull);
    expect(heatmap!.width, 2);
    expect(heatmap.height, 3);
    expect(heatmap.dx, 0.1);
    expect(heatmap.dy, 5.0);
    // Values are column-major: column 0 first, then column 1.
    expect(heatmap.valueAt(0, 0), 1.0);
    expect(heatmap.valueAt(0, 2), 3.0);
    expect(heatmap.valueAt(1, 0), 4.0);
    expect(heatmap.valueAt(1, 2), 6.0);
  });

  test('PlotChannelRef serializes to the wire contract', () {
    const ref = PlotChannelRef(sourceId: 3, channelId: 'V1:Hrec');
    expect(ref.toJson(), {'source_id': 3, 'channel_id': 'V1:Hrec'});
  });
}
