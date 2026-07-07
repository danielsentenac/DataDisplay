/// One-way importer for the original dataDisplay `dy.cfg` format
/// (plain-text keyword sections written by DyConfig.c).
///
/// [parseDyConfig] is pure: it maps the config onto source URIs, a GPS
/// window, a pad grid and analysis-deck entries, collecting human-readable
/// warnings for everything that cannot be represented.
library;

/// Deck-entry shape produced by the importer (mirrors `AnalysisDeckEntry`
/// without depending on Flutter).
class DyImportedPlot {
  const DyImportedPlot({
    required this.label,
    required this.channels,
    required this.spec,
  });

  final String label;
  final List<String> channels;
  final Map<String, Object?> spec;
}

class DyConfigImportResult {
  const DyConfigImportResult({
    required this.sourceUris,
    required this.gpsStartSeconds,
    required this.durationSeconds,
    required this.gridColumns,
    required this.gridRows,
    required this.plots,
    required this.warnings,
    required this.importedCount,
    required this.skippedCount,
  });

  final List<String> sourceUris;
  final double? gpsStartSeconds;

  /// Null when the config uses `duration -1` (endless/online).
  final double? durationSeconds;

  /// Null when the config asks for automatic pads (`ncol 0` / `nrow 0`).
  final int? gridColumns;
  final int? gridRows;
  final List<DyImportedPlot> plots;
  final List<String> warnings;
  final int importedCount;
  final int skippedCount;
}

/// Grid shapes offered by the Analysis deck selector.
const _supportedGrids = [(1, 1), (2, 1), (2, 2), (3, 2), (3, 3)];

/// `ymin 2e+31` / `ymax -2e+31` mean "auto" in the original tool.
const _autoRangeSentinel = 1e30;

const _inputTypeNames = {
  0: 'GWF_FILE',
  1: 'ONLINE',
  2: 'DATASENDER',
  3: 'INVEGA',
  4: 'SHARED_MEMORY',
  6: 'AUDIO_FILE',
  7: 'ASCII_FILE',
  8: 'CHANNELS_OPERATION',
};

const _importableTypesByName = {
  'TIME': 'time',
  'FFT': 'fft',
  'TRFCT': 'transfer_function',
  'COHE': 'coherence',
  'FFTTIME': 'spectrogram',
  'BRMSTIME': 'brms',
};

const _importableTypesByNumber = {
  7: 'time',
  8: 'fft',
  9: 'transfer_function',
  10: 'coherence',
  14: 'spectrogram',
  31: 'brms',
};

class _DySection {
  _DySection(this.headerTokens);

  final List<String> headerTokens;
  final List<List<String>> lines = [];

  String get name => headerTokens.first;
}

class _DyPlot {
  _DyPlot({required this.name, required this.fileOrder, required this.keys});

  final String name;
  final int fileOrder;
  final Map<String, List<String>> keys;

  String? str(String key) => keys[key]?.first;

  double? num(String key) {
    final raw = str(key);
    return raw == null ? null : double.tryParse(raw);
  }

  int? intVal(String key) => num(key)?.round();
}

class _DyEntry {
  _DyEntry({
    required this.kind,
    required this.label,
    required this.channels,
    required this.spec,
    required this.numpad,
    required this.fileOrder,
  });

  final String kind;
  String label;
  final List<String> channels;
  final Map<String, Object?> spec;
  final int numpad;
  final int fileOrder;
}

DyConfigImportResult parseDyConfig(String text) {
  final warnings = <String>[];
  final sections = _splitSections(text);

  final sourceUris = <String>[];
  double? gpsStartSeconds;
  double? durationSeconds;
  int? gridColumns;
  int? gridRows;
  final plots = <_DyPlot>[];
  var plotOrder = 0;

  for (final section in sections) {
    switch (section.name) {
      case 'DY_TIMING':
        for (final tokens in section.lines) {
          if (tokens.first == 'starttime' && tokens.length > 1) {
            gpsStartSeconds = double.tryParse(tokens[1]);
          } else if (tokens.first == 'duration' && tokens.length > 1) {
            final value = double.tryParse(tokens[1]);
            if (value != null && value < 0) {
              warnings.add(
                'duration is -1 (endless/online) — duration left unchanged.',
              );
            } else {
              durationSeconds = value;
            }
          }
        }
      case 'DY_INPUT':
        _parseInputs(section, sourceUris, warnings);
      case 'DY_PADS':
        int? ncol;
        int? nrow;
        for (final tokens in section.lines) {
          if (tokens.first == 'ncol' && tokens.length > 1) {
            ncol = int.tryParse(tokens[1]);
          } else if (tokens.first == 'nrow' && tokens.length > 1) {
            nrow = int.tryParse(tokens[1]);
          }
        }
        if (ncol != null && nrow != null && (ncol > 0 || nrow > 0)) {
          final (columns, rows) = _clampGrid(ncol, nrow);
          if (columns != ncol || rows != nrow) {
            warnings.add(
              'pad grid ${ncol}x$nrow clamped to ${columns}x$rows.',
            );
          }
          gridColumns = columns;
          gridRows = rows;
        }
      case 'DY_PLOT':
        plotOrder += 1;
        final name = section.headerTokens.length > 2
            ? section.headerTokens[2]
            : 'plot ${section.headerTokens.elementAt(1)}';
        final keys = <String, List<String>>{};
        for (final tokens in section.lines) {
          keys.putIfAbsent(tokens.first, () => tokens.sublist(1));
        }
        plots.add(_DyPlot(name: name, fileOrder: plotOrder, keys: keys));
      case 'DY_OPTIONS':
      case 'DY_TAG':
        break;
      default:
        break;
    }
  }

  var skipped = 0;
  final entries = <_DyEntry>[];
  _DyEntry? lastAnchor;
  for (final plot in plots) {
    final mapped = _mapPlot(plot, warnings);
    if (mapped == null) {
      skipped += 1;
      continue;
    }

    final superposed = (plot.intVal('superposed') ?? 0) == 1;
    if (superposed && lastAnchor != null) {
      final mergeable =
          mapped.kind == lastAnchor.kind &&
          const {'time', 'fft', 'brms'}.contains(mapped.kind) &&
          mapped.channels.length == 1 &&
          _specEquals(mapped.spec, lastAnchor.spec);
      if (mergeable) {
        lastAnchor.channels.addAll(mapped.channels);
        lastAnchor.label = _entryLabel(lastAnchor.kind, lastAnchor.channels);
        continue;
      }
      warnings.add(
        'superposed plot `${plot.name}` kept on its own pad — parameters '
        'differ or the plot type does not support superposition.',
      );
    }

    entries.add(mapped);
    if (!superposed) {
      lastAnchor = mapped;
    }
  }

  final ordered = [...entries]
    ..sort((a, b) {
      final byPad = a.numpad.compareTo(b.numpad);
      return byPad != 0 ? byPad : a.fileOrder.compareTo(b.fileOrder);
    });

  return DyConfigImportResult(
    sourceUris: sourceUris,
    gpsStartSeconds: gpsStartSeconds,
    durationSeconds: durationSeconds,
    gridColumns: gridColumns,
    gridRows: gridRows,
    plots: [
      for (final entry in ordered)
        DyImportedPlot(
          label: entry.label,
          channels: entry.channels,
          spec: entry.spec,
        ),
    ],
    warnings: warnings,
    importedCount: ordered.length,
    skippedCount: skipped,
  );
}

List<_DySection> _splitSections(String text) {
  final sections = <_DySection>[];
  _DySection? current;
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trimRight();
    if (line.isEmpty) {
      continue;
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('/')) {
      continue;
    }
    final indented = line.startsWith(' ') || line.startsWith('\t');
    if (!indented && trimmed.startsWith('DY_')) {
      current = _DySection(trimmed.split(RegExp(r'\s+')));
      sections.add(current);
      continue;
    }
    if (current == null) {
      continue;
    }
    final tokens = trimmed.split(RegExp(r'\s+'));
    if (tokens.isEmpty || tokens.first.isEmpty) {
      continue;
    }
    // Skip parenthesized comments accidentally starting a line.
    if (tokens.first.startsWith('(')) {
      continue;
    }
    current.lines.add(tokens);
  }
  return sections;
}

void _parseInputs(
  _DySection section,
  List<String> sourceUris,
  List<String> warnings,
) {
  String? channelName;
  int? inputType;
  String? inputTypeName;
  for (final tokens in section.lines) {
    switch (tokens.first) {
      case 'chindex':
        channelName = tokens.length > 2 ? tokens[2] : null;
        inputType = null;
        inputTypeName = null;
      case 'inputtype':
        inputType = tokens.length > 1 ? int.tryParse(tokens[1]) : null;
        inputTypeName = tokens.length > 2 ? tokens[2] : null;
      case 'inputname':
        final inputName = tokens.length > 1
            ? tokens.sublist(1).join(' ')
            : '';
        final channel = channelName ?? inputName;
        if (inputType == 0) {
          final lower = inputName.toLowerCase();
          if (lower.endsWith('.ffl')) {
            _addUnique(sourceUris, 'ffl://$inputName');
          } else if (lower.endsWith('.gwf')) {
            _addUnique(sourceUris, 'gwf://$inputName');
          } else {
            warnings.add(
              'channel $channel uses a GWF_FILE input with unrecognized '
              'file `$inputName` — not imported.',
            );
          }
        } else if (inputType == 1) {
          warnings.add(
            'channel $channel uses ONLINE (Cm) input — connect a Tomcat '
            'backend instead.',
          );
        } else {
          final typeName =
              inputTypeName ?? _inputTypeNames[inputType] ?? '$inputType';
          warnings.add(
            'channel $channel uses $typeName input — not imported.',
          );
        }
    }
  }
}

void _addUnique(List<String> list, String value) {
  if (!list.contains(value)) {
    list.add(value);
  }
}

(int, int) _clampGrid(int requestedColumns, int requestedRows) {
  final columns = requestedColumns.clamp(1, 3);
  final rows = requestedRows.clamp(1, 3);
  var best = _supportedGrids.first;
  var bestDistance = 1 << 30;
  for (final option in _supportedGrids) {
    final distance =
        (option.$1 - columns).abs() + (option.$2 - rows).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = option;
    }
  }
  return best;
}

_DyEntry? _mapPlot(_DyPlot plot, List<String> warnings) {
  final typeTokens = plot.keys['type'];
  final typeName = typeTokens != null && typeTokens.length > 1
      ? typeTokens[1]
      : null;
  final typeNumber = typeTokens != null && typeTokens.isNotEmpty
      ? int.tryParse(typeTokens.first)
      : null;
  final kind =
      (typeName != null ? _importableTypesByName[typeName] : null) ??
      (typeNumber != null ? _importableTypesByNumber[typeNumber] : null);
  if (kind == null) {
    warnings.add(
      'plot type ${typeName ?? typeNumber ?? 'unknown'} not supported yet '
      '— plot `${plot.name}` skipped.',
    );
    return null;
  }

  if ((plot.intVal('hidden') ?? 0) == 1) {
    warnings.add('plot `${plot.name}` is hidden — skipped.');
    return null;
  }

  final channelX = plot.str('chx_name');
  if (channelX == null || channelX.isEmpty) {
    warnings.add('plot `${plot.name}` has no chx_name — skipped.');
    return null;
  }

  final spec = <String, Object?>{};
  final channels = <String>[channelX];
  final removeDc = (plot.intVal('nodc') ?? 0) == 1;
  final logX = (plot.intVal('logx') ?? 0) == 1;
  final logY = (plot.intVal('logy') ?? 0) == 1;
  final sampFreq = plot.num('chx_sampFreq');

  switch (kind) {
    case 'time':
      spec['kind'] = 'time';
      final filterMin = plot.num('filter_fmin') ?? 0;
      final filterMax = plot.num('filter_fmax') ?? 0;
      if (filterMin > 0 && filterMax > 0 && filterMin < filterMax) {
        spec['band_hz'] = [filterMin, filterMax];
      } else if (filterMin > 0 || filterMax > 0) {
        warnings.add(
          'plot `${plot.name}`: one-sided filter '
          '($filterMin/$filterMax Hz) not imported.',
        );
      }
      spec['remove_dc'] = removeDc;
      final resample = plot.num('chx_resampFreq');
      if (resample != null &&
          resample > 0 &&
          sampFreq != null &&
          resample < sampFreq) {
        spec['resample_hz'] = resample;
      }
      _applyYRange(plot, spec);
      spec['log_y'] = logY;
    case 'fft':
      spec['kind'] = 'fft';
      _applyFftParams(plot, spec, warnings);
      spec['amplitude'] = (plot.intVal('hertz') ?? 0) == 0;
      spec['db'] = (plot.intVal('ydb') ?? 0) == 1;
      spec['rms_curve'] = (plot.intVal('rmsfft') ?? 0) == 1;
      spec['remove_dc'] = removeDc;
      _applyFrequencyZoom(plot, spec, sampFreq);
      _applyYRange(plot, spec);
      spec['log_x'] = logX;
      spec['log_y'] = logY;
    case 'coherence':
    case 'transfer_function':
      final channelY = plot.str('chy_name');
      if (channelY == null || channelY.isEmpty) {
        warnings.add('plot `${plot.name}` has no chy_name — skipped.');
        return null;
      }
      channels.add(channelY);
      spec['kind'] = kind;
      _applyFftParams(plot, spec, warnings);
      spec['remove_dc'] = removeDc;
      _applyFrequencyZoom(plot, spec, sampFreq);
      _applyYRange(plot, spec);
      spec['log_x'] = logX;
      spec['log_y'] = logY;
    case 'spectrogram':
      spec['kind'] = 'spectrogram';
      final fftDuration = plot.num('fft_duration');
      if (fftDuration == null || fftDuration <= 0) {
        warnings.add('plot `${plot.name}` has no fft_duration — skipped.');
        return null;
      }
      spec['segment_duration_s'] = fftDuration;
      spec['step_duration_s'] = fftDuration;
      warnings.add(
        'plot `${plot.name}`: time resolution approximated '
        '(step = FFT length).',
      );
      spec['remove_dc'] = removeDc;
      if ((plot.intVal('medy') ?? 0) == 1) {
        spec['median_normalize'] = true;
      }
      _applyFrequencyZoom(plot, spec, sampFreq);
    case 'brms':
      final fmin = plot.num('fmin');
      final fmax = plot.num('fmax');
      if (fmin == null || fmax == null || fmax <= fmin) {
        warnings.add(
          'plot `${plot.name}`: BRMS needs fmin < fmax — skipped.',
        );
        return null;
      }
      spec['kind'] = 'brms';
      spec['fmin_hz'] = fmin;
      spec['fmax_hz'] = fmax;
      final fftDuration = plot.num('fft_duration');
      if (fftDuration == null || fftDuration <= 0) {
        warnings.add('plot `${plot.name}` has no fft_duration — skipped.');
        return null;
      }
      spec['segment_duration_s'] = fftDuration;
      spec['step_duration_s'] = fftDuration;
      spec['remove_dc'] = removeDc;
      _applyYRange(plot, spec);
      spec['log_y'] = logY;
  }

  if ((kind == 'fft' ||
          kind == 'coherence' ||
          kind == 'transfer_function') &&
      spec['segment_duration_s'] == null) {
    warnings.add('plot `${plot.name}` has no fft_duration — skipped.');
    return null;
  }

  return _DyEntry(
    kind: kind,
    label: _entryLabel(kind, channels),
    channels: channels,
    spec: spec,
    numpad: plot.intVal('numpad') ?? 1 << 20,
    fileOrder: plot.fileOrder,
  );
}

void _applyFftParams(
  _DyPlot plot,
  Map<String, Object?> spec,
  List<String> warnings,
) {
  spec['segment_duration_s'] = plot.num('fft_duration');
  final tstep = plot.num('tstep');
  spec['overlap'] = tstep == null
      ? 0.5
      : (1 - tstep / 100).clamp(0.0, 0.9).toDouble();
  final maxAverage = plot.num('max_average');
  if (maxAverage != null && maxAverage > 0) {
    spec['max_segments'] = maxAverage.round();
  }
  if ((plot.intVal('decayfft') ?? 0) == 1) {
    spec['averaging'] = 'decay';
    spec['decay_count'] =
        maxAverage != null && maxAverage > 0 ? maxAverage : 8.0;
  } else if ((plot.intVal('median') ?? 0) == 1) {
    spec['averaging'] = 'median';
  }
}

void _applyFrequencyZoom(
  _DyPlot plot,
  Map<String, Object?> spec,
  double? sampFreq,
) {
  final fmin = plot.num('fmin');
  final fmax = plot.num('fmax');
  if (fmin != null && fmin > 0) {
    spec['fmin_hz'] = fmin;
  }
  if (fmax != null &&
      fmax > 0 &&
      (sampFreq == null || fmax < sampFreq / 2)) {
    spec['fmax_hz'] = fmax;
  }
}

void _applyYRange(_DyPlot plot, Map<String, Object?> spec) {
  if ((plot.intVal('autoscale') ?? 0) == 1) {
    return;
  }
  final yMin = plot.num('ymin');
  final yMax = plot.num('ymax');
  if (yMin != null && yMin.abs() < _autoRangeSentinel) {
    spec['y_min'] = yMin;
  }
  if (yMax != null && yMax.abs() < _autoRangeSentinel) {
    spec['y_max'] = yMax;
  }
}

String _entryLabel(String kind, List<String> channels) {
  switch (kind) {
    case 'coherence':
      return 'Coherence ${channels.join(' / ')}';
    case 'transfer_function':
      return 'TF ${channels.join(' -> ')}';
    case 'time':
      return 'Time ${channels.join(', ')}';
    case 'fft':
      return 'FFT ${channels.join(', ')}';
    case 'spectrogram':
      return 'Spectrogram ${channels.join(', ')}';
    case 'brms':
      return 'BRMS ${channels.join(', ')}';
    default:
      return channels.join(', ');
  }
}

bool _specEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    final other = b[entry.key];
    final value = entry.value;
    if (value is List && other is List) {
      if (value.length != other.length) {
        return false;
      }
      for (var index = 0; index < value.length; index++) {
        if (value[index] != other[index]) {
          return false;
        }
      }
    } else if (value != other) {
      return false;
    }
  }
  return true;
}
