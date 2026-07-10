/// Builds `spec` maps for the `dd_engine_plot_json` request from raw form
/// input, and maps saved specs back into form values (deck "edit" action).
///
/// Text fields are kept as strings so the UI can bind them directly to
/// `TextEditingController`s; an empty string means "omit the key" (engine
/// default applies). Invalid input raises [AnalysisSpecException].
library;

enum AnalysisPlotKind {
  time('Time', 'time'),
  fft('FFT', 'fft'),
  spectrogram('Spectrogram', 'spectrogram'),
  coherence('Coherence', 'coherence'),
  transferFunction('Transfer function', 'transfer_function'),
  brms('BRMS', 'brms'),
  histogram('1D distribution', 'histogram'),
  histogram2d('2D distribution', 'histogram2d');

  const AnalysisPlotKind(this.label, this.wireKind);

  final String label;
  final String wireKind;

  bool get needsSecondChannel =>
      this == AnalysisPlotKind.coherence ||
      this == AnalysisPlotKind.transferFunction ||
      this == AnalysisPlotKind.histogram2d;

  bool get allowsSecondChannel =>
      needsSecondChannel ||
      this == AnalysisPlotKind.time ||
      this == AnalysisPlotKind.fft ||
      this == AnalysisPlotKind.brms ||
      this == AnalysisPlotKind.histogram;

  bool get usesWindow =>
      this != AnalysisPlotKind.time &&
      this != AnalysisPlotKind.histogram &&
      this != AnalysisPlotKind.histogram2d;

  bool get usesAveraging =>
      this == AnalysisPlotKind.fft ||
      this == AnalysisPlotKind.coherence ||
      this == AnalysisPlotKind.transferFunction;

  bool get usesFrequencyAxis =>
      this == AnalysisPlotKind.fft ||
      this == AnalysisPlotKind.coherence ||
      this == AnalysisPlotKind.transferFunction;

  bool get usesStep =>
      this == AnalysisPlotKind.spectrogram || this == AnalysisPlotKind.brms;

  /// Channel maths (`ch0 - 2*ch1` ...) combine the request channels into a
  /// single input series; the engine rejects it for two-channel plots.
  bool get supportsExpression =>
      this != AnalysisPlotKind.coherence &&
      this != AnalysisPlotKind.transferFunction &&
      this != AnalysisPlotKind.histogram2d;

  static AnalysisPlotKind fromWireKind(String value) {
    return values.firstWhere(
      (kind) => kind.wireKind == value,
      orElse: () => AnalysisPlotKind.fft,
    );
  }
}

class AnalysisSpecException implements Exception {
  AnalysisSpecException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AnalysisSpecForm {
  AnalysisSpecForm({
    required this.kind,
    this.segmentSeconds = '1',
    this.stepSeconds = '0.5',
    this.overlap = '0.5',
    this.window = 'hann',
    this.averaging = 'mean',
    this.maxSegments = '',
    this.decayCount = '8',
    this.bandLow = '',
    this.bandHigh = '',
    this.filterOrder = '4',
    this.resampleHz = '',
    this.maxPoints = '',
    this.fmin = '',
    this.fmax = '',
    this.brmsFmin = '1',
    this.brmsFmax = '100',
    this.yMin = '',
    this.yMax = '',
    this.zMin = '',
    this.zMax = '',
    this.averagesPerColumn = '',
    this.shiftB = '0',
    this.bins = '100',
    this.xBins = '100',
    this.yBins = '100',
    this.xMin = '',
    this.xMax = '',
    this.expression = '',
    this.removeDc = false,
    this.amplitude = true,
    this.db = false,
    this.rmsCurve = false,
    this.medianNormalize = false,
    this.sqrtCoherence = false,
    this.phaseAsDelay = false,
    this.logX = true,
    this.logY = true,
    this.logZ = true,
  });

  final AnalysisPlotKind kind;

  // Numeric text fields; empty means "use the engine default / omit".
  final String segmentSeconds;
  final String stepSeconds;
  final String overlap;
  final String window;
  final String averaging;
  final String maxSegments;
  final String decayCount;
  final String bandLow;
  final String bandHigh;
  final String filterOrder;
  final String resampleHz;
  final String maxPoints;

  /// Displayed frequency band (fmin/fmax zoom) for FFT / spectrogram / cross.
  final String fmin;
  final String fmax;

  /// Required integration band for BRMS.
  final String brmsFmin;
  final String brmsFmax;
  final String yMin;
  final String yMax;
  final String zMin;
  final String zMax;
  final String averagesPerColumn;
  final String shiftB;

  /// Distribution (histogram) parameters; empty ranges mean auto.
  final String bins;
  final String xBins;
  final String yBins;
  final String xMin;
  final String xMax;

  /// Optional request-level channel maths over `ch0`..`chN` ("Combine
  /// channels"). Not part of the `spec` map — see [requestExpression].
  final String expression;

  final bool removeDc;
  final bool amplitude;
  final bool db;
  final bool rmsCurve;
  final bool medianNormalize;
  final bool sqrtCoherence;
  final bool phaseAsDelay;
  final bool logX;
  final bool logY;
  final bool logZ;

  /// Builds the wire `spec` map. Throws [AnalysisSpecException] on invalid
  /// input; optional fields left empty are omitted from the map.
  Map<String, Object?> build() {
    switch (kind) {
      case AnalysisPlotKind.time:
        return {
          'kind': 'time',
          'band_hz': ?_bandPair(),
          'filter_order': _optionalInt(filterOrder, 'Filter order') ?? 4,
          'remove_dc': removeDc,
          'resample_hz': ?_optionalPositive(resampleHz, 'Resample rate'),
          'max_points': ?_optionalInt(maxPoints, 'Max points'),
          ..._yRangeFields(),
          'log_y': logY,
        };
      case AnalysisPlotKind.fft:
        return {
          'kind': 'fft',
          'segment_duration_s': _requiredPositive(
            segmentSeconds,
            'FFT length (s)',
          ),
          'overlap': _optionalDouble(overlap, 'Overlap') ?? 0.5,
          'window': window,
          'averaging': averaging,
          ..._averagingFields(),
          'remove_dc': removeDc,
          'amplitude': amplitude,
          'db': db,
          'rms_curve': rmsCurve,
          ..._frequencyBandFields(),
          ..._yRangeFields(),
          'log_x': logX,
          'log_y': logY,
        };
      case AnalysisPlotKind.spectrogram:
        return {
          'kind': 'spectrogram',
          'segment_duration_s': _requiredPositive(
            segmentSeconds,
            'FFT length (s)',
          ),
          'step_duration_s': _requiredPositive(stepSeconds, 'Step (s)'),
          'window': window,
          'remove_dc': removeDc,
          'amplitude': amplitude,
          'averages_per_column': ?_optionalInt(
            averagesPerColumn,
            'Averages per column',
          ),
          'median_normalize': medianNormalize,
          ..._frequencyBandFields(),
          ..._zRangeFields(),
          'log_z': logZ,
        };
      case AnalysisPlotKind.coherence:
      case AnalysisPlotKind.transferFunction:
        return {
          'kind': kind.wireKind,
          'segment_duration_s': _requiredPositive(
            segmentSeconds,
            'FFT length (s)',
          ),
          'overlap': _optionalDouble(overlap, 'Overlap') ?? 0.5,
          'window': window,
          'averaging': averaging,
          ..._averagingFields(),
          'remove_dc': removeDc,
          'shift_b_s': _optionalDouble(shiftB, 'Channel B shift') ?? 0.0,
          if (kind == AnalysisPlotKind.coherence) 'sqrt': sqrtCoherence,
          if (kind == AnalysisPlotKind.transferFunction)
            'phase_as_delay': phaseAsDelay,
          ..._frequencyBandFields(),
          ..._yRangeFields(),
          'log_x': logX,
          'log_y': logY,
        };
      case AnalysisPlotKind.brms:
        final low = _requiredNonNegative(brmsFmin, 'F min');
        final high = _requiredPositive(brmsFmax, 'F max');
        if (high <= low) {
          throw AnalysisSpecException(
            'BRMS needs 0 <= F min < F max (in Hz).',
          );
        }
        return {
          'kind': 'brms',
          'fmin_hz': low,
          'fmax_hz': high,
          'segment_duration_s': _requiredPositive(
            segmentSeconds,
            'FFT length (s)',
          ),
          'step_duration_s': _requiredPositive(stepSeconds, 'Step (s)'),
          'window': window,
          'remove_dc': removeDc,
          ..._yRangeFields(),
          'log_y': logY,
        };
      case AnalysisPlotKind.histogram:
        return {
          'kind': 'histogram',
          'bins': _optionalInt(bins, 'Bins') ?? 100,
          ..._xRangeFields(),
          'log_y': logY,
        };
      case AnalysisPlotKind.histogram2d:
        return {
          'kind': 'histogram2d',
          'x_bins': _optionalInt(xBins, 'X bins') ?? 100,
          'y_bins': _optionalInt(yBins, 'Y bins') ?? 100,
          ..._xRangeFields(),
          ..._yRangeFields(),
          'log_z': logZ,
        };
    }
  }

  /// The request-level `expression` value, or null when empty or when the
  /// plot kind does not accept channel maths.
  String? get requestExpression {
    final trimmed = expression.trim();
    if (trimmed.isEmpty || !kind.supportsExpression) {
      return null;
    }
    return trimmed;
  }

  /// Restores form values from a previously built spec map (deck editing).
  /// Unknown or absent keys fall back to the form defaults.
  factory AnalysisSpecForm.fromSpec(Map<String, Object?> spec) {
    final kind = AnalysisPlotKind.fromWireKind(spec['kind'] as String? ?? '');
    final band = spec['band_hz'] as List<dynamic>?;
    return AnalysisSpecForm(
      kind: kind,
      segmentSeconds: _text(spec['segment_duration_s'], fallback: '1'),
      stepSeconds: _text(spec['step_duration_s'], fallback: '0.5'),
      overlap: _text(spec['overlap'], fallback: '0.5'),
      window: spec['window'] as String? ?? 'hann',
      averaging: spec['averaging'] as String? ?? 'mean',
      maxSegments: _text(spec['max_segments']),
      decayCount: _text(spec['decay_count'], fallback: '8'),
      bandLow: band != null && band.isNotEmpty ? _text(band[0]) : '',
      bandHigh: band != null && band.length > 1 ? _text(band[1]) : '',
      filterOrder: _text(spec['filter_order'], fallback: '4'),
      resampleHz: _text(spec['resample_hz']),
      maxPoints: _text(spec['max_points']),
      fmin: kind == AnalysisPlotKind.brms ? '' : _text(spec['fmin_hz']),
      fmax: kind == AnalysisPlotKind.brms ? '' : _text(spec['fmax_hz']),
      brmsFmin: kind == AnalysisPlotKind.brms
          ? _text(spec['fmin_hz'], fallback: '1')
          : '1',
      brmsFmax: kind == AnalysisPlotKind.brms
          ? _text(spec['fmax_hz'], fallback: '100')
          : '100',
      yMin: _text(spec['y_min']),
      yMax: _text(spec['y_max']),
      zMin: _text(spec['z_min']),
      zMax: _text(spec['z_max']),
      averagesPerColumn: _text(spec['averages_per_column']),
      shiftB: _text(spec['shift_b_s'], fallback: '0'),
      bins: _text(spec['bins'], fallback: '100'),
      xBins: _text(spec['x_bins'], fallback: '100'),
      yBins: _text(spec['y_bins'], fallback: '100'),
      xMin: _text(spec['x_min']),
      xMax: _text(spec['x_max']),
      removeDc: spec['remove_dc'] as bool? ?? false,
      amplitude: spec['amplitude'] as bool? ?? true,
      db: spec['db'] as bool? ?? false,
      rmsCurve: spec['rms_curve'] as bool? ?? false,
      medianNormalize: spec['median_normalize'] as bool? ?? false,
      sqrtCoherence: spec['sqrt'] as bool? ?? false,
      phaseAsDelay: spec['phase_as_delay'] as bool? ?? false,
      logX: spec['log_x'] as bool? ?? kind.usesFrequencyAxis,
      logY: spec['log_y'] as bool? ??
          (kind == AnalysisPlotKind.fft ||
              kind == AnalysisPlotKind.transferFunction),
      logZ: spec['log_z'] as bool? ?? true,
    );
  }

  Map<String, Object?> _xRangeFields() {
    final low = _optionalDouble(xMin, 'X min');
    final high = _optionalDouble(xMax, 'X max');
    if (low != null && high != null && high <= low) {
      throw AnalysisSpecException('X range needs min < max.');
    }
    return {'x_min': ?low, 'x_max': ?high};
  }

  List<double>? _bandPair() {
    final low = _optionalDouble(bandLow, 'Band low');
    final high = _optionalDouble(bandHigh, 'Band high');
    if (low == null && high == null) {
      return null;
    }
    if (low == null || high == null || low <= 0 || high <= low) {
      throw AnalysisSpecException(
        'Band-pass needs both bounds with 0 < low < high (in Hz), or leave both empty.',
      );
    }
    return [low, high];
  }

  Map<String, Object?> _averagingFields() {
    return {
      'max_segments': ?_optionalInt(maxSegments, 'Max segments'),
      if (averaging == 'decay')
        'decay_count': ?_optionalPositive(decayCount, 'Decay count'),
    };
  }

  Map<String, Object?> _frequencyBandFields() {
    final low = _optionalDouble(fmin, 'F min');
    final high = _optionalDouble(fmax, 'F max');
    if (low != null && high != null && high <= low) {
      throw AnalysisSpecException(
        'Frequency band needs F min < F max (in Hz).',
      );
    }
    return {'fmin_hz': ?low, 'fmax_hz': ?high};
  }

  Map<String, Object?> _yRangeFields() {
    final low = _optionalDouble(yMin, 'Y min');
    final high = _optionalDouble(yMax, 'Y max');
    if (low != null && high != null && high <= low) {
      throw AnalysisSpecException('Y range needs min < max.');
    }
    return {'y_min': ?low, 'y_max': ?high};
  }

  Map<String, Object?> _zRangeFields() {
    final low = _optionalDouble(zMin, 'Z min');
    final high = _optionalDouble(zMax, 'Z max');
    if (low != null && high != null && high <= low) {
      throw AnalysisSpecException('Z range needs min < max.');
    }
    return {'z_min': ?low, 'z_max': ?high};
  }
}

String _text(Object? value, {String fallback = ''}) {
  if (value == null) {
    return fallback;
  }
  if (value is double && value == value.roundToDouble() && value.isFinite) {
    return value.round().toString();
  }
  return value.toString();
}

double? _optionalDouble(String text, String label) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final value = double.tryParse(trimmed);
  if (value == null || !value.isFinite) {
    throw AnalysisSpecException('$label must be a number.');
  }
  return value;
}

double? _optionalPositive(String text, String label) {
  final value = _optionalDouble(text, label);
  if (value != null && value <= 0) {
    throw AnalysisSpecException('$label must be positive.');
  }
  return value;
}

int? _optionalInt(String text, String label) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final value = int.tryParse(trimmed);
  if (value == null || value <= 0) {
    throw AnalysisSpecException('$label must be a positive integer.');
  }
  return value;
}

double _requiredPositive(String text, String label) {
  final value = _optionalDouble(text, label);
  if (value == null || value <= 0) {
    throw AnalysisSpecException('$label must be a positive number.');
  }
  return value;
}

double _requiredNonNegative(String text, String label) {
  final value = _optionalDouble(text, label);
  if (value == null || value < 0) {
    throw AnalysisSpecException('$label must be zero or a positive number.');
  }
  return value;
}
