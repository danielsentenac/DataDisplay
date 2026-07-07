import 'datadisplay_backend.dart';

/// Models for the `dd_engine_plot_json` one-call plot pipeline.
///
/// The engine reads channels, runs DSP in Rust, and returns ready-to-draw
/// scenes; these classes mirror the JSON contract in
/// `crates/dd-ffi/src/plot.rs` (`PlotResponse` / `FfiPlotScene`).

class PlotChannelRef {
  const PlotChannelRef({required this.sourceId, required this.channelId});

  final int sourceId;
  final String channelId;

  Map<String, Object> toJson() => {
    'source_id': sourceId,
    'channel_id': channelId,
  };
}

class PlotAxis {
  const PlotAxis({
    required this.label,
    required this.unit,
    required this.logScale,
    required this.rangeMin,
    required this.rangeMax,
  });

  final String label;
  final String? unit;
  final bool logScale;
  final double? rangeMin;
  final double? rangeMax;

  bool get hasRange => rangeMin != null && rangeMax != null;

  String get titleLabel {
    if (unit == null || unit!.isEmpty) {
      return label;
    }
    return '$label ($unit)';
  }

  factory PlotAxis.fromJson(Map<String, dynamic> json) {
    final range = json['range'] as List<dynamic>?;
    return PlotAxis(
      label: json['label'] as String? ?? '',
      unit: json['unit'] as String?,
      logScale: json['log_scale'] as bool? ?? false,
      rangeMin: range != null && range.isNotEmpty
          ? (range[0] as num).toDouble()
          : null,
      rangeMax: range != null && range.length > 1
          ? (range[1] as num).toDouble()
          : null,
    );
  }
}

abstract class PlotLayerData {
  const PlotLayerData();

  factory PlotLayerData.fromJson(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'line':
        return LinePlotLayer(
          label: json['label'] as String? ?? '',
          xs: _doubleListFromJson(json['xs']),
          ys: _doubleListFromJson(json['ys']),
          colorRgba: _doubleListFromJson(json['color_rgba']),
        );
      case 'heatmap':
        return HeatmapPlotLayer(
          width: json['width'] as int? ?? 0,
          height: json['height'] as int? ?? 0,
          x0: (json['x0'] as num?)?.toDouble() ?? 0.0,
          dx: (json['dx'] as num?)?.toDouble() ?? 1.0,
          y0: (json['y0'] as num?)?.toDouble() ?? 0.0,
          dy: (json['dy'] as num?)?.toDouble() ?? 1.0,
          values: _doubleListFromJson(json['values']),
        );
      case 'volume':
        return VolumePlotLayer(
          xLen: json['x_len'] as int? ?? 0,
          yLen: json['y_len'] as int? ?? 0,
          zLen: json['z_len'] as int? ?? 0,
          values: _doubleListFromJson(json['values']),
        );
      default:
        throw BackendException(
          'invalid_response',
          'Unknown plot layer kind `${json['kind']}`.',
        );
    }
  }
}

class LinePlotLayer extends PlotLayerData {
  const LinePlotLayer({
    required this.label,
    required this.xs,
    required this.ys,
    required this.colorRgba,
  });

  final String label;
  final List<double> xs;
  final List<double> ys;

  /// `[r, g, b, a]` components in 0..1.
  final List<double> colorRgba;
}

/// Heatmap cells positioned on real axes; `values` is column-major
/// (all `height` rows of column 0, then column 1, ...).
class HeatmapPlotLayer extends PlotLayerData {
  const HeatmapPlotLayer({
    required this.width,
    required this.height,
    required this.x0,
    required this.dx,
    required this.y0,
    required this.dy,
    required this.values,
  });

  final int width;
  final int height;
  final double x0;
  final double dx;
  final double y0;
  final double dy;
  final List<double> values;

  double valueAt(int column, int row) => values[column * height + row];
}

class VolumePlotLayer extends PlotLayerData {
  const VolumePlotLayer({
    required this.xLen,
    required this.yLen,
    required this.zLen,
    required this.values,
  });

  final int xLen;
  final int yLen;
  final int zLen;
  final List<double> values;
}

class PlotSceneData {
  const PlotSceneData({
    required this.title,
    required this.plotKind,
    required this.xAxis,
    required this.yAxis,
    required this.zAxis,
    required this.epochNs,
    required this.timeRange,
    required this.layers,
  });

  final String title;

  /// "line1d" | "heatmap2d" | "volume3d".
  final String plotKind;
  final PlotAxis xAxis;
  final PlotAxis yAxis;
  final PlotAxis? zAxis;
  final int? epochNs;
  final TimeRange? timeRange;
  final List<PlotLayerData> layers;

  factory PlotSceneData.fromJson(Map<String, dynamic> json) {
    return PlotSceneData(
      title: json['title'] as String? ?? '',
      plotKind: json['plot_kind'] as String? ?? 'line1d',
      xAxis: PlotAxis.fromJson(
        json['x_axis'] as Map<String, dynamic>? ?? const {},
      ),
      yAxis: PlotAxis.fromJson(
        json['y_axis'] as Map<String, dynamic>? ?? const {},
      ),
      zAxis: json['z_axis'] == null
          ? null
          : PlotAxis.fromJson(Map<String, dynamic>.from(json['z_axis'] as Map)),
      epochNs: (json['epoch_ns'] as num?)?.toInt(),
      timeRange: json['time_range'] == null
          ? null
          : TimeRange.fromJson(
              Map<String, dynamic>.from(json['time_range'] as Map),
            ),
      layers: (json['layers'] as List<dynamic>? ?? const [])
          .map(
            (value) => PlotLayerData.fromJson(value as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  Iterable<LinePlotLayer> get lineLayers => layers.whereType<LinePlotLayer>();

  HeatmapPlotLayer? get firstHeatmapLayer {
    for (final layer in layers) {
      if (layer is HeatmapPlotLayer) {
        return layer;
      }
    }
    return null;
  }
}

class PlotFigure {
  const PlotFigure({required this.title, required this.scenes});

  final String title;
  final List<PlotSceneData> scenes;

  factory PlotFigure.fromJson(Map<String, dynamic> json) {
    return PlotFigure(
      title: json['title'] as String? ?? '',
      scenes: (json['scenes'] as List<dynamic>? ?? const [])
          .map((value) => PlotSceneData.fromJson(value as Map<String, dynamic>))
          .toList(),
    );
  }
}

List<double> _doubleListFromJson(Object? value) {
  return (value as List<dynamic>? ?? const [])
      .map((entry) => (entry as num).toDouble())
      .toList();
}
