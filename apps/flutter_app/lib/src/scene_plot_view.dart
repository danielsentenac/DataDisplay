import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'plot_scene.dart';

/// Renders one [PlotSceneData] returned by the engine plot pipeline.
///
/// Supports `line1d` scenes (multi-trace polylines with linear/log axes) and
/// `heatmap2d` scenes (positioned cells with a colorbar). Other kinds render
/// a placeholder message.
class ScenePlotView extends StatelessWidget {
  const ScenePlotView({super.key, required this.scene});

  final PlotSceneData scene;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ScenePlotPainter(scene: scene),
      child: const SizedBox.expand(),
    );
  }
}

const _sceneTitleStyle = TextStyle(
  color: Color(0xFF1F2925),
  fontSize: 13,
  fontWeight: FontWeight.w800,
);
const _sceneTickStyle = TextStyle(
  color: Color(0xFF57655E),
  fontSize: 11,
  fontWeight: FontWeight.w600,
);
const _sceneAxisTitleStyle = TextStyle(
  color: Color(0xFF57655E),
  fontSize: 11,
  fontWeight: FontWeight.w700,
);
const _sceneLegendStyle = TextStyle(
  color: Color(0xFF3C4944),
  fontSize: 11,
  fontWeight: FontWeight.w600,
);
const _sceneMessageStyle = TextStyle(
  color: Color(0xFF5C6963),
  fontSize: 12,
  fontWeight: FontWeight.w600,
);

/// Maps a data value to a 0..1 fraction along a linear or log10 axis.
class _AxisScale {
  factory _AxisScale({
    required bool log,
    required double min,
    required double max,
  }) {
    if (log) {
      final safeMin = min > 0 ? min : (max > 0 ? max / 1e6 : 1e-12);
      final safeMax = max > safeMin ? max : safeMin * 10.0;
      return _AxisScale._(log: true, min: safeMin, max: safeMax);
    }
    var safeMin = min.isFinite ? min : 0.0;
    var safeMax = max.isFinite ? max : 1.0;
    if (safeMax <= safeMin) {
      final pad = safeMin.abs() > 0 ? safeMin.abs() * 0.5 : 1.0;
      safeMin -= pad;
      safeMax += pad;
    }
    return _AxisScale._(log: false, min: safeMin, max: safeMax);
  }

  const _AxisScale._({required this.log, required this.min, required this.max});

  final bool log;
  final double min;
  final double max;

  double get _logMin => math.log(min) / math.ln10;
  double get _logMax => math.log(max) / math.ln10;

  /// Returns NaN for values that cannot be projected (non-finite, or
  /// non-positive on a log axis).
  double fraction(double value) {
    if (!value.isFinite) {
      return double.nan;
    }
    if (log) {
      if (value <= 0) {
        return double.nan;
      }
      final logValue = math.log(value) / math.ln10;
      return (logValue - _logMin) / math.max(1e-12, _logMax - _logMin);
    }
    return (value - min) / math.max(1e-300, max - min);
  }
}

class _AxisTick {
  const _AxisTick(this.value, this.label);

  final double value;
  final String label;
}

class _ScenePlotPainter extends CustomPainter {
  _ScenePlotPainter({required this.scene});

  final PlotSceneData scene;

  static const _colorbarGap = 14.0;
  static const _colorbarWidth = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)),
      background,
    );

    _paintText(
      canvas,
      scene.title,
      _sceneTitleStyle,
      const Offset(20, 12),
      maxWidth: math.max(10.0, size.width - 40),
    );

    final isHeatmap =
        scene.plotKind == 'heatmap2d' && scene.firstHeatmapLayer != null;
    final rightInset = isHeatmap
        ? _colorbarGap + _colorbarWidth + 58.0
        : 22.0;
    final plotRect = Rect.fromLTRB(
      78,
      40,
      size.width - rightInset,
      size.height - 46,
    );
    if (plotRect.width <= 8 || plotRect.height <= 8) {
      return;
    }

    if (isHeatmap) {
      _paintHeatmapScene(canvas, size, plotRect, scene.firstHeatmapLayer!);
      return;
    }
    if (scene.plotKind == 'line1d') {
      _paintLineScene(canvas, size, plotRect);
      return;
    }
    _paintText(
      canvas,
      'Plot kind `${scene.plotKind}` is not supported yet.',
      _sceneMessageStyle,
      Offset(plotRect.left, plotRect.center.dy),
    );
  }

  @override
  bool shouldRepaint(covariant _ScenePlotPainter oldDelegate) {
    return oldDelegate.scene != scene;
  }

  // ── line1d ────────────────────────────────────────────────────────────────

  void _paintLineScene(Canvas canvas, Size size, Rect plotRect) {
    final lines = scene.lineLayers.toList();
    if (lines.isEmpty || lines.every((layer) => layer.xs.isEmpty)) {
      _paintPlotFrame(canvas, plotRect);
      _paintText(
        canvas,
        'No data points returned.',
        _sceneMessageStyle,
        Offset(plotRect.left + 12, plotRect.center.dy),
      );
      return;
    }

    final xScale = _scaleForAxis(
      scene.xAxis,
      () => _lineExtent(lines, (layer) => layer.xs, positiveOnly: false),
      () => _lineExtent(lines, (layer) => layer.xs, positiveOnly: true),
    );
    final yScale = _scaleForAxis(
      scene.yAxis,
      () => _lineExtent(lines, (layer) => layer.ys, positiveOnly: false),
      () => _lineExtent(lines, (layer) => layer.ys, positiveOnly: true),
    );

    _paintPlotFrame(canvas, plotRect);
    _paintGridAndTicks(canvas, plotRect, xScale, yScale);
    _paintAxisTitles(canvas, size, plotRect);

    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(plotRect, const Radius.circular(16)),
    );
    for (final layer in lines) {
      final linePaint = Paint()
        ..color = _layerColor(layer)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      final path = Path();
      var open = false;
      final count = math.min(layer.xs.length, layer.ys.length);
      for (var index = 0; index < count; index++) {
        final fx = xScale.fraction(layer.xs[index]);
        final fy = yScale.fraction(layer.ys[index]);
        if (fx.isNaN || fy.isNaN) {
          open = false;
          continue;
        }
        final point = Offset(
          plotRect.left + fx * plotRect.width,
          plotRect.bottom - fy * plotRect.height,
        );
        if (open) {
          path.lineTo(point.dx, point.dy);
        } else {
          path.moveTo(point.dx, point.dy);
          open = true;
        }
      }
      canvas.drawPath(path, linePaint);
    }
    canvas.restore();

    if (lines.length > 1) {
      _paintLegend(canvas, plotRect, lines);
    }
  }

  (double, double) _lineExtent(
    List<LinePlotLayer> lines,
    List<double> Function(LinePlotLayer layer) select, {
    required bool positiveOnly,
  }) {
    var min = double.infinity;
    var max = double.negativeInfinity;
    for (final layer in lines) {
      for (final value in select(layer)) {
        if (!value.isFinite || (positiveOnly && value <= 0)) {
          continue;
        }
        min = math.min(min, value);
        max = math.max(max, value);
      }
    }
    if (min > max) {
      return positiveOnly ? (1e-12, 1.0) : (0.0, 1.0);
    }
    return (min, max);
  }

  _AxisScale _scaleForAxis(
    PlotAxis axis,
    (double, double) Function() extent,
    (double, double) Function() positiveExtent,
  ) {
    if (axis.hasRange && !(axis.logScale && axis.rangeMin! <= 0)) {
      return _AxisScale(
        log: axis.logScale,
        min: axis.rangeMin!,
        max: axis.rangeMax!,
      );
    }
    final (min, max) = axis.logScale ? positiveExtent() : extent();
    return _AxisScale(log: axis.logScale, min: min, max: max);
  }

  void _paintLegend(Canvas canvas, Rect plotRect, List<LinePlotLayer> lines) {
    const swatchWidth = 16.0;
    const rowHeight = 16.0;
    const padding = 8.0;

    final painters = <TextPainter>[];
    var maxLabelWidth = 0.0;
    for (final layer in lines) {
      final painter = TextPainter(
        text: TextSpan(text: layer.label, style: _sceneLegendStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(20.0, plotRect.width * 0.5));
      painters.add(painter);
      maxLabelWidth = math.max(maxLabelWidth, painter.width);
    }

    final boxWidth = padding * 2 + swatchWidth + 6 + maxLabelWidth;
    final boxHeight = padding * 2 + rowHeight * lines.length - 4;
    final box = Rect.fromLTWH(
      plotRect.right - boxWidth - 10,
      plotRect.top + 10,
      boxWidth,
      boxHeight,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(10)),
      Paint()..color = const Color(0xEBFFFFFF),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(10)),
      Paint()
        ..color = const Color(0xFFE0E6E1)
        ..style = PaintingStyle.stroke,
    );

    for (var index = 0; index < lines.length; index++) {
      final rowTop = box.top + padding + index * rowHeight;
      canvas.drawLine(
        Offset(box.left + padding, rowTop + 5),
        Offset(box.left + padding + swatchWidth, rowTop + 5),
        Paint()
          ..color = _layerColor(lines[index])
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
      painters[index].paint(
        canvas,
        Offset(box.left + padding + swatchWidth + 6, rowTop - 2),
      );
    }
  }

  // ── heatmap2d ─────────────────────────────────────────────────────────────

  void _paintHeatmapScene(
    Canvas canvas,
    Size size,
    Rect plotRect,
    HeatmapPlotLayer layer,
  ) {
    if (layer.width <= 0 ||
        layer.height <= 0 ||
        layer.values.length < layer.width * layer.height) {
      _paintPlotFrame(canvas, plotRect);
      _paintText(
        canvas,
        'Heatmap layer is empty.',
        _sceneMessageStyle,
        Offset(plotRect.left + 12, plotRect.center.dy),
      );
      return;
    }

    final xScale = _scaleForAxis(
      scene.xAxis,
      () => (layer.x0, layer.x0 + layer.dx * layer.width),
      () => (
        math.max(layer.x0, layer.dx * 0.5),
        layer.x0 + layer.dx * layer.width,
      ),
    );
    final yScale = _scaleForAxis(
      scene.yAxis,
      () => (layer.y0, layer.y0 + layer.dy * layer.height),
      () => (
        math.max(layer.y0, layer.dy * 0.5),
        layer.y0 + layer.dy * layer.height,
      ),
    );

    final logZ = scene.zAxis?.logScale ?? false;
    var smallestPositive = double.infinity;
    for (final value in layer.values) {
      if (value.isFinite && value > 0) {
        smallestPositive = math.min(smallestPositive, value);
      }
    }
    if (!smallestPositive.isFinite) {
      smallestPositive = 1e-12;
    }

    double transform(double value) {
      if (!value.isFinite) {
        return double.nan;
      }
      if (!logZ) {
        return value;
      }
      return math.log(math.max(value, smallestPositive)) / math.ln10;
    }

    var zMin = double.infinity;
    var zMax = double.negativeInfinity;
    for (final value in layer.values) {
      final z = transform(value);
      if (z.isNaN) {
        continue;
      }
      zMin = math.min(zMin, z);
      zMax = math.max(zMax, z);
    }
    // A manual z range (engine `z_min`/`z_max`, raw units) replaces the
    // data-driven color scale; cell colors outside it are clamped.
    final zAxis = scene.zAxis;
    if (zAxis != null && zAxis.hasRange) {
      final manualMin = transform(zAxis.rangeMin!);
      final manualMax = transform(zAxis.rangeMax!);
      if (!manualMin.isNaN && !manualMax.isNaN && manualMax > manualMin) {
        zMin = manualMin;
        zMax = manualMax;
      }
    }
    if (zMin > zMax) {
      zMin = 0;
      zMax = 1;
    }
    if (zMax - zMin < 1e-12) {
      zMax = zMin + 1;
    }

    _paintPlotFrame(canvas, plotRect);

    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(plotRect, const Radius.circular(16)),
    );
    final cellPaint = Paint()..style = PaintingStyle.fill;
    for (var column = 0; column < layer.width; column++) {
      final xLowFrac = xScale.fraction(layer.x0 + layer.dx * column);
      final xHighFrac = xScale.fraction(layer.x0 + layer.dx * (column + 1));
      if (xLowFrac.isNaN && xHighFrac.isNaN) {
        continue;
      }
      final left = plotRect.left +
          (xLowFrac.isNaN ? 0.0 : xLowFrac) * plotRect.width;
      final right = plotRect.left +
          (xHighFrac.isNaN ? 0.0 : xHighFrac) * plotRect.width;
      for (var row = 0; row < layer.height; row++) {
        final yLowFrac = yScale.fraction(layer.y0 + layer.dy * row);
        final yHighFrac = yScale.fraction(layer.y0 + layer.dy * (row + 1));
        if (yLowFrac.isNaN && yHighFrac.isNaN) {
          continue;
        }
        final bottom = plotRect.bottom -
            (yLowFrac.isNaN ? 0.0 : yLowFrac) * plotRect.height;
        final top = plotRect.bottom -
            (yHighFrac.isNaN ? 0.0 : yHighFrac) * plotRect.height;
        final z = transform(layer.valueAt(column, row));
        if (z.isNaN) {
          continue;
        }
        cellPaint.color = _heatmapColor((z - zMin) / (zMax - zMin));
        canvas.drawRect(
          Rect.fromLTRB(left - 0.4, top - 0.4, right + 0.4, bottom + 0.4),
          cellPaint,
        );
      }
    }
    canvas.restore();

    _paintGridAndTicks(canvas, plotRect, xScale, yScale, gridLines: false);
    _paintAxisTitles(canvas, size, plotRect, rightLimit: plotRect.right);
    _paintColorbar(canvas, plotRect, zMin: zMin, zMax: zMax, logZ: logZ);
  }

  void _paintColorbar(
    Canvas canvas,
    Rect plotRect, {
    required double zMin,
    required double zMax,
    required bool logZ,
  }) {
    final bar = Rect.fromLTWH(
      plotRect.right + _colorbarGap,
      plotRect.top,
      _colorbarWidth,
      plotRect.height,
    );
    const steps = 64;
    final stripPaint = Paint()..style = PaintingStyle.fill;
    for (var step = 0; step < steps; step++) {
      final t0 = step / steps;
      final t1 = (step + 1) / steps;
      stripPaint.color = _heatmapColor(1 - (t0 + t1) / 2);
      canvas.drawRect(
        Rect.fromLTRB(
          bar.left,
          bar.top + t0 * bar.height - 0.4,
          bar.right,
          bar.top + t1 * bar.height + 0.4,
        ),
        stripPaint,
      );
    }
    canvas.drawRect(
      bar,
      Paint()
        ..color = const Color(0xFF92A29B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    String zLabel(double z) {
      final value = logZ ? math.pow(10.0, z).toDouble() : z;
      return _formatTickValue(value);
    }

    _paintText(
      canvas,
      zLabel(zMax),
      _sceneTickStyle,
      Offset(bar.right + 6, bar.top - 2),
    );
    _paintText(
      canvas,
      zLabel(zMin),
      _sceneTickStyle,
      Offset(bar.right + 6, bar.bottom - 12),
    );
  }

  // ── shared chrome ─────────────────────────────────────────────────────────

  void _paintPlotFrame(Canvas canvas, Rect plotRect) {
    final plotBackground = Paint()
      ..color = const Color(0xFFF8FBF9)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(plotRect, const Radius.circular(16)),
      plotBackground,
    );
  }

  void _paintGridAndTicks(
    Canvas canvas,
    Rect plotRect,
    _AxisScale xScale,
    _AxisScale yScale, {
    bool gridLines = true,
  }) {
    final gridPaint = Paint()
      ..color = const Color(0xFFE2E8E3)
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = const Color(0xFF92A29B)
      ..strokeWidth = 1.4;

    final xTicks = _ticksFor(xScale);
    final yTicks = _ticksFor(yScale);

    for (final tick in xTicks) {
      final fraction = xScale.fraction(tick.value);
      if (fraction.isNaN || fraction < -0.001 || fraction > 1.001) {
        continue;
      }
      final dx = plotRect.left + fraction * plotRect.width;
      if (gridLines) {
        canvas.drawLine(
          Offset(dx, plotRect.top),
          Offset(dx, plotRect.bottom),
          gridPaint,
        );
      }
      canvas.drawLine(
        Offset(dx, plotRect.bottom),
        Offset(dx, plotRect.bottom + 4),
        axisPaint,
      );
      _paintText(
        canvas,
        tick.label,
        _sceneTickStyle,
        Offset(dx, plotRect.bottom + 7),
        anchorCenterX: true,
      );
    }

    for (final tick in yTicks) {
      final fraction = yScale.fraction(tick.value);
      if (fraction.isNaN || fraction < -0.001 || fraction > 1.001) {
        continue;
      }
      final dy = plotRect.bottom - fraction * plotRect.height;
      if (gridLines) {
        canvas.drawLine(
          Offset(plotRect.left, dy),
          Offset(plotRect.right, dy),
          gridPaint,
        );
      }
      canvas.drawLine(
        Offset(plotRect.left - 4, dy),
        Offset(plotRect.left, dy),
        axisPaint,
      );
      _paintText(
        canvas,
        tick.label,
        _sceneTickStyle,
        Offset(plotRect.left - 8, dy - 6),
        anchorRightX: true,
      );
    }

    canvas.drawLine(
      Offset(plotRect.left, plotRect.top),
      Offset(plotRect.left, plotRect.bottom),
      axisPaint,
    );
    canvas.drawLine(
      Offset(plotRect.left, plotRect.bottom),
      Offset(plotRect.right, plotRect.bottom),
      axisPaint,
    );
  }

  void _paintAxisTitles(
    Canvas canvas,
    Size size,
    Rect plotRect, {
    double? rightLimit,
  }) {
    final xTitle = scene.xAxis.titleLabel;
    if (xTitle.isNotEmpty) {
      final centerX = (plotRect.left + (rightLimit ?? plotRect.right)) / 2;
      _paintText(
        canvas,
        xTitle,
        _sceneAxisTitleStyle,
        Offset(centerX, plotRect.bottom + 24),
        anchorCenterX: true,
      );
    }

    final yTitle = scene.yAxis.titleLabel;
    if (yTitle.isNotEmpty) {
      final painter = TextPainter(
        text: TextSpan(text: yTitle, style: _sceneAxisTitleStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: plotRect.height);
      canvas.save();
      canvas.translate(14, plotRect.center.dy + painter.width / 2);
      canvas.rotate(-math.pi / 2);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  List<_AxisTick> _ticksFor(_AxisScale scale) {
    if (scale.log) {
      final startDecade = (math.log(scale.min) / math.ln10).ceil();
      final endDecade = (math.log(scale.max) / math.ln10).floor();
      if (endDecade - startDecade >= 1) {
        var stride = 1;
        while ((endDecade - startDecade) ~/ stride > 8) {
          stride *= 2;
        }
        return [
          for (var decade = startDecade; decade <= endDecade; decade += stride)
            _AxisTick(
              math.pow(10.0, decade).toDouble(),
              _decadeLabel(decade),
            ),
        ];
      }
      // Less than one decade of span: fall back to a few labeled positions.
      final logMin = math.log(scale.min) / math.ln10;
      final logMax = math.log(scale.max) / math.ln10;
      return [
        for (var index = 0; index <= 3; index++)
          _AxisTick(
            math
                .pow(10.0, logMin + (logMax - logMin) * index / 3)
                .toDouble(),
            _formatTickValue(
              math.pow(10.0, logMin + (logMax - logMin) * index / 3)
                  .toDouble(),
            ),
          ),
      ];
    }

    final span = scale.max - scale.min;
    final rawStep = span / 5;
    final magnitude = math
        .pow(10.0, (math.log(rawStep) / math.ln10).floorToDouble())
        .toDouble();
    final normalized = rawStep / magnitude;
    final double step;
    if (normalized < 1.5) {
      step = magnitude;
    } else if (normalized < 3.5) {
      step = 2 * magnitude;
    } else if (normalized < 7.5) {
      step = 5 * magnitude;
    } else {
      step = 10 * magnitude;
    }
    final first = (scale.min / step).ceilToDouble() * step;
    final ticks = <_AxisTick>[];
    for (var value = first; value <= scale.max + step * 1e-6; value += step) {
      final snapped = value.abs() < step * 1e-6 ? 0.0 : value;
      ticks.add(_AxisTick(snapped, _formatTickValue(snapped)));
    }
    return ticks;
  }

  Color _layerColor(LinePlotLayer layer) {
    if (layer.colorRgba.length < 4) {
      return const Color(0xFF0A7B6C);
    }
    return Color.fromARGB(
      (layer.colorRgba[3].clamp(0.0, 1.0) * 255).round(),
      (layer.colorRgba[0].clamp(0.0, 1.0) * 255).round(),
      (layer.colorRgba[1].clamp(0.0, 1.0) * 255).round(),
      (layer.colorRgba[2].clamp(0.0, 1.0) * 255).round(),
    );
  }

  void _paintText(
    Canvas canvas,
    String text,
    TextStyle style,
    Offset offset, {
    double? maxWidth,
    bool anchorCenterX = false,
    bool anchorRightX = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? double.infinity);
    var target = offset;
    if (anchorCenterX) {
      target = Offset(offset.dx - painter.width / 2, offset.dy);
    } else if (anchorRightX) {
      target = Offset(offset.dx - painter.width, offset.dy);
    }
    painter.paint(canvas, target);
  }
}

/// Dark blue → cyan → yellow → red ramp used for heatmap cells.
Color _heatmapColor(double t) {
  const stops = [
    Color(0xFF102A5C),
    Color(0xFF1AA7C4),
    Color(0xFFF2D13F),
    Color(0xFFC0392B),
  ];
  final clamped = t.isFinite ? t.clamp(0.0, 1.0) : 0.0;
  final scaled = clamped * (stops.length - 1);
  final index = math.min(stops.length - 2, scaled.floor());
  final local = scaled - index;
  return Color.lerp(stops[index], stops[index + 1], local)!;
}

String _decadeLabel(int exponent) {
  if (exponent == 0) {
    return '1';
  }
  const superscripts = {
    '-': '⁻',
    '0': '⁰',
    '1': '¹',
    '2': '²',
    '3': '³',
    '4': '⁴',
    '5': '⁵',
    '6': '⁶',
    '7': '⁷',
    '8': '⁸',
    '9': '⁹',
  };
  final digits = exponent
      .toString()
      .split('')
      .map((char) => superscripts[char] ?? char)
      .join();
  return '10$digits';
}

String _formatTickValue(double value) {
  if (value == 0) {
    return '0';
  }
  final absValue = value.abs();
  if (absValue >= 100000 || absValue < 0.001) {
    final text = value.toStringAsExponential(1);
    return text.replaceFirst('.0e', 'e');
  }
  if (absValue >= 100) {
    return value.toStringAsFixed(0);
  }
  if (absValue >= 10) {
    final rounded = value.toStringAsFixed(1);
    return rounded.endsWith('.0')
        ? rounded.substring(0, rounded.length - 2)
        : rounded;
  }
  if (absValue >= 1) {
    final rounded = value.toStringAsFixed(2);
    return rounded.endsWith('.00')
        ? rounded.substring(0, rounded.length - 3)
        : rounded;
  }
  return value.toStringAsFixed(3);
}
