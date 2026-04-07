import 'dart:math' as math;

class BackendException implements Exception {
  BackendException(this.kind, this.message);

  final String kind;
  final String message;

  @override
  String toString() => '$kind: $message';
}

enum StreamKind {
  series1d('series1d', '1D series'),
  sampled('sampled', 'Sampled'),
  grid2d('grid2d', '2D grid'),
  volume3d('volume3d', '3D volume'),
  eventSeries('event_series', 'Events');

  const StreamKind(this.wireName, this.label);

  final String wireName;
  final String label;

  static StreamKind fromWireName(String value) {
    return values.firstWhere(
      (kind) => kind.wireName == value,
      orElse: () => StreamKind.series1d,
    );
  }
}

enum ReadAggregation {
  raw('raw', 'Raw'),
  mean('mean', 'Mean'),
  rms('rms', 'RMS'),
  spectrogram('spectrogram', 'Spectrogram');

  const ReadAggregation(this.wireName, this.label);

  final String wireName;
  final String label;

  Map<String, Object> toWireJson() {
    switch (this) {
      case ReadAggregation.raw:
        return const {'kind': 'raw'};
      case ReadAggregation.mean:
        return const {'kind': 'mean'};
      case ReadAggregation.rms:
        return const {'kind': 'rms'};
      case ReadAggregation.spectrogram:
        return const {'kind': 'spectrogram', 'window_len': 32, 'step_len': 16};
    }
  }
}

class SourceCapabilities {
  const SourceCapabilities({
    required this.catalogSearch,
    required this.liveSubscriptions,
    required this.volume3d,
    required this.metadataWrite,
    required this.batchRead,
  });

  final bool catalogSearch;
  final bool liveSubscriptions;
  final bool volume3d;
  final bool metadataWrite;
  final bool batchRead;

  factory SourceCapabilities.fromJson(Map<String, dynamic> json) {
    return SourceCapabilities(
      catalogSearch: json['catalog_search'] as bool? ?? false,
      liveSubscriptions: json['live_subscriptions'] as bool? ?? false,
      volume3d: json['volume3d'] as bool? ?? false,
      metadataWrite: json['metadata_write'] as bool? ?? false,
      batchRead: json['batch_read'] as bool? ?? false,
    );
  }

  List<String> enabledLabels() {
    final labels = <String>[];
    if (catalogSearch) {
      labels.add('catalog_search');
    }
    if (liveSubscriptions) {
      labels.add('live_subscriptions');
    }
    if (volume3d) {
      labels.add('volume3d');
    }
    if (metadataWrite) {
      labels.add('metadata_write');
    }
    if (batchRead) {
      labels.add('batch_read');
    }
    return labels;
  }
}

class ChannelDescriptor {
  const ChannelDescriptor({
    required this.id,
    required this.displayName,
    required this.unit,
    required this.sampleRateHz,
    required this.metadata,
  });

  final String id;
  final String displayName;
  final String? unit;
  final double? sampleRateHz;
  final Map<String, String> metadata;

  factory ChannelDescriptor.fromJson(Map<String, dynamic> json) {
    return ChannelDescriptor(
      id: json['id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      unit: json['unit'] as String?,
      sampleRateHz: (json['sample_rate_hz'] as num?)?.toDouble(),
      metadata: _stringMapFromJson(json['metadata']),
    );
  }

  String get subtitleParts {
    final parts = <String>[];
    if (sampleRateHz != null) {
      parts.add(_formatSampleRate(sampleRateHz!));
    }
    if (unit != null && unit!.isNotEmpty) {
      parts.add(unit!);
    }
    return parts.join(' • ');
  }
}

class StreamDescriptor {
  const StreamDescriptor({
    required this.channel,
    required this.kind,
    required this.sampleShape,
    required this.tags,
    required this.extra,
  });

  final ChannelDescriptor channel;
  final StreamKind kind;
  final List<int> sampleShape;
  final List<String> tags;
  final Map<String, String> extra;

  bool get isScalarTimeseries =>
      kind == StreamKind.series1d ||
      (kind == StreamKind.sampled && sampleShape.isEmpty);

  bool get isGenericSampled => kind == StreamKind.sampled;

  factory StreamDescriptor.fromJson(Map<String, dynamic> json) {
    return StreamDescriptor(
      channel: ChannelDescriptor.fromJson(
        json['channel'] as Map<String, dynamic>? ?? const {},
      ),
      kind: StreamKind.fromWireName(json['kind'] as String? ?? 'series1d'),
      sampleShape: (json['sample_shape'] as List<dynamic>? ?? const [])
          .map((value) => (value as num).toInt())
          .toList(),
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      extra: _stringMapFromJson(json['extra']),
    );
  }
}

class CatalogPage {
  const CatalogPage({
    required this.totalCount,
    required this.offset,
    required this.streams,
  });

  final int totalCount;
  final int offset;
  final List<StreamDescriptor> streams;

  factory CatalogPage.fromJson(
    Map<String, dynamic> json, {
    required int fallbackOffset,
  }) {
    final streams = (json['streams'] as List<dynamic>? ?? const [])
        .map(
          (value) => StreamDescriptor.fromJson(value as Map<String, dynamic>),
        )
        .toList();
    return CatalogPage(
      totalCount: json['total_count'] as int? ?? streams.length,
      offset: json['offset'] as int? ?? fallbackOffset,
      streams: streams,
    );
  }
}

class OpenedSource {
  const OpenedSource({
    required this.sourceId,
    required this.uri,
    required this.sourceName,
    required this.capabilities,
  });

  final int sourceId;
  final String uri;
  final String sourceName;
  final SourceCapabilities capabilities;

  factory OpenedSource.fromJson(Map<String, dynamic> json) {
    return OpenedSource(
      sourceId: json['source_id'] as int? ?? 0,
      uri: json['uri'] as String? ?? '',
      sourceName: json['source_name'] as String? ?? '',
      capabilities: SourceCapabilities.fromJson(
        json['capabilities'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }
}

class TimeRange {
  const TimeRange({required this.startNs, required this.endNs});

  final int startNs;
  final int endNs;

  factory TimeRange.fromJson(Map<String, dynamic> json) {
    return TimeRange(
      startNs: json['start_ns'] as int? ?? 0,
      endNs: json['end_ns'] as int? ?? 0,
    );
  }

  Map<String, Object> toJson() => {'start_ns': startNs, 'end_ns': endNs};

  String get label {
    final start = _formatNanoseconds(startNs);
    final end = _formatNanoseconds(endNs);
    return '$start to $end';
  }
}

abstract class TimeAxis {
  const TimeAxis();

  int get length;

  String get label;

  factory TimeAxis.fromJson(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'regular':
        return RegularTimeAxis(
          startNs: json['start_ns'] as int? ?? 0,
          samplePeriodNs: json['sample_period_ns'] as int? ?? 1,
          len: json['len'] as int? ?? 0,
        );
      case 'irregular':
        return IrregularTimeAxis(
          timestampsNs: (json['timestamps_ns'] as List<dynamic>? ?? const [])
              .map((value) => (value as num).toInt())
              .toList(),
        );
      default:
        return const RegularTimeAxis(startNs: 0, samplePeriodNs: 1, len: 0);
    }
  }
}

class RegularTimeAxis extends TimeAxis {
  const RegularTimeAxis({
    required this.startNs,
    required this.samplePeriodNs,
    required this.len,
  });

  final int startNs;
  final int samplePeriodNs;
  final int len;

  @override
  int get length => len;

  int get endNs => startNs + (samplePeriodNs * len);

  @override
  String get label =>
      '${_formatNanoseconds(startNs)} • ${_formatNanoseconds(samplePeriodNs)} step';
}

class IrregularTimeAxis extends TimeAxis {
  const IrregularTimeAxis({required this.timestampsNs});

  final List<int> timestampsNs;

  @override
  int get length => timestampsNs.length;

  @override
  String get label {
    if (timestampsNs.isEmpty) {
      return 'No timestamps';
    }
    return '${_formatNanoseconds(timestampsNs.first)} • irregular';
  }
}

class SampleAxisInfo {
  const SampleAxisInfo({
    required this.label,
    required this.unit,
    required this.len,
    required this.origin,
    required this.spacing,
  });

  final String label;
  final String? unit;
  final int len;
  final double? origin;
  final double? spacing;

  factory SampleAxisInfo.fromJson(Map<String, dynamic> json) {
    return SampleAxisInfo(
      label: json['label'] as String? ?? '',
      unit: json['unit'] as String?,
      len: json['len'] as int? ?? 0,
      origin: (json['origin'] as num?)?.toDouble(),
      spacing: (json['spacing'] as num?)?.toDouble(),
    );
  }
}

abstract class DataBlock {
  const DataBlock({required this.channel, required this.metadata});

  final ChannelDescriptor channel;
  final Map<String, String> metadata;

  StreamKind get kind;

  factory DataBlock.fromJson(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'series1d':
        return SeriesBlock(
          channel: ChannelDescriptor.fromJson(
            json['channel'] as Map<String, dynamic>? ?? const {},
          ),
          axis: TimeAxis.fromJson(
            json['axis'] as Map<String, dynamic>? ?? const {},
          ),
          values: (json['values'] as List<dynamic>? ?? const [])
              .map((value) => (value as num).toDouble())
              .toList(),
          metadata: _stringMapFromJson(json['metadata']),
        );
      case 'sampled':
        return SampledBlock(
          channel: ChannelDescriptor.fromJson(
            json['channel'] as Map<String, dynamic>? ?? const {},
          ),
          axis: TimeAxis.fromJson(
            json['axis'] as Map<String, dynamic>? ?? const {},
          ),
          sampleShape: (json['sample_shape'] as List<dynamic>? ?? const [])
              .map((value) => (value as num).toInt())
              .toList(),
          sampleAxes: (json['sample_axes'] as List<dynamic>? ?? const [])
              .map(
                (value) => SampleAxisInfo.fromJson(
                  value as Map<String, dynamic>? ?? const {},
                ),
              )
              .toList(),
          values: (json['values'] as List<dynamic>? ?? const [])
              .map((value) => (value as num).toDouble())
              .toList(),
          metadata: _stringMapFromJson(json['metadata']),
        );
      case 'grid2d':
        return GridBlock(
          channel: ChannelDescriptor.fromJson(
            json['channel'] as Map<String, dynamic>? ?? const {},
          ),
          xRange: TimeRange.fromJson(
            json['x_range'] as Map<String, dynamic>? ?? const {},
          ),
          yLabel: json['y_label'] as String? ?? 'Y',
          yUnit: json['y_unit'] as String?,
          width: json['width'] as int? ?? 0,
          height: json['height'] as int? ?? 0,
          values: (json['values'] as List<dynamic>? ?? const [])
              .map((value) => (value as num).toDouble())
              .toList(),
          metadata: _stringMapFromJson(json['metadata']),
        );
      case 'volume3d':
        return VolumeBlock(
          channel: ChannelDescriptor.fromJson(
            json['channel'] as Map<String, dynamic>? ?? const {},
          ),
          xLen: json['x_len'] as int? ?? 0,
          yLen: json['y_len'] as int? ?? 0,
          zLen: json['z_len'] as int? ?? 0,
          values: (json['values'] as List<dynamic>? ?? const [])
              .map((value) => (value as num).toDouble())
              .toList(),
          metadata: _stringMapFromJson(json['metadata']),
        );
      case 'event_series':
        return EventSeriesBlock(
          channel: ChannelDescriptor.fromJson(
            json['channel'] as Map<String, dynamic>? ?? const {},
          ),
          timeRange: TimeRange.fromJson(
            json['time_range'] as Map<String, dynamic>? ?? const {},
          ),
          events: (json['events'] as List<dynamic>? ?? const [])
              .map(
                (value) => EventPoint.fromJson(
                  value as Map<String, dynamic>? ?? const {},
                ),
              )
              .toList(),
          metadata: _stringMapFromJson(json['metadata']),
        );
      default:
        throw BackendException(
          'invalid_response',
          'Unknown data block kind `${json['kind']}`.',
        );
    }
  }
}

class SeriesBlock extends DataBlock {
  const SeriesBlock({
    required super.channel,
    required this.axis,
    required this.values,
    required super.metadata,
  });

  final TimeAxis axis;
  final List<double> values;

  @override
  StreamKind get kind => StreamKind.series1d;
}

class SampledBlock extends DataBlock {
  const SampledBlock({
    required super.channel,
    required this.axis,
    required this.sampleShape,
    required this.sampleAxes,
    required this.values,
    required super.metadata,
  });

  final TimeAxis axis;
  final List<int> sampleShape;
  final List<SampleAxisInfo> sampleAxes;
  final List<double> values;

  bool get isScalar => sampleShape.isEmpty;

  int get sampleSize => sampleShape.isEmpty
      ? 1
      : sampleShape.fold(1, (value, element) => value * element);

  int get sampleCount => axis.length;

  SeriesBlock? get asScalarSeries => isScalar
      ? SeriesBlock(
          channel: channel,
          axis: axis,
          values: values,
          metadata: metadata,
        )
      : null;

  @override
  StreamKind get kind => StreamKind.sampled;
}

class GridBlock extends DataBlock {
  const GridBlock({
    required super.channel,
    required this.xRange,
    required this.yLabel,
    required this.yUnit,
    required this.width,
    required this.height,
    required this.values,
    required super.metadata,
  });

  final TimeRange xRange;
  final String yLabel;
  final String? yUnit;
  final int width;
  final int height;
  final List<double> values;

  @override
  StreamKind get kind => StreamKind.grid2d;
}

class VolumeBlock extends DataBlock {
  const VolumeBlock({
    required super.channel,
    required this.xLen,
    required this.yLen,
    required this.zLen,
    required this.values,
    required super.metadata,
  });

  final int xLen;
  final int yLen;
  final int zLen;
  final List<double> values;

  @override
  StreamKind get kind => StreamKind.volume3d;
}

class EventPoint {
  const EventPoint({
    required this.timestampNs,
    required this.label,
    required this.metadata,
  });

  final int timestampNs;
  final String label;
  final Map<String, String> metadata;

  factory EventPoint.fromJson(Map<String, dynamic> json) {
    return EventPoint(
      timestampNs: json['timestamp_ns'] as int? ?? 0,
      label: json['label'] as String? ?? '',
      metadata: _stringMapFromJson(json['metadata']),
    );
  }
}

class EventSeriesBlock extends DataBlock {
  const EventSeriesBlock({
    required super.channel,
    required this.timeRange,
    required this.events,
    required super.metadata,
  });

  final TimeRange timeRange;
  final List<EventPoint> events;

  @override
  StreamKind get kind => StreamKind.eventSeries;
}

abstract class DatadisplayBackendClient {
  Future<OpenedSource> openSource(String uri);

  Future<void> closeSource(int sourceId);

  Future<CatalogPage> catalog({
    required int sourceId,
    String? text,
    List<String> tags = const [],
    int offset = 0,
    int? limit,
  });

  Future<DataBlock> read({
    required int sourceId,
    required String channelId,
    required TimeRange timeRange,
    required ReadAggregation aggregation,
    int? maxPoints,
    bool allowGaps = false,
  });

  void dispose() {}
}

class DemoDatadisplayBackend implements DatadisplayBackendClient {
  DemoDatadisplayBackend() {
    _seriesBlock = _buildSeriesBlock();
    _gridBlock = _buildGridBlock();
    _volumeBlock = _buildVolumeBlock();
    _eventBlock = _buildEventBlock();
    _streams = [
      StreamDescriptor(
        channel: _seriesBlock.channel,
        kind: StreamKind.series1d,
        sampleShape: const [],
        tags: const ['demo', 'control'],
        extra: const {
          'preview.len': '512',
          'preview.start_ns': '1000000000',
          'preview.sample_period_ns': '7812500',
        },
      ),
      StreamDescriptor(
        channel: _gridBlock.channel,
        kind: StreamKind.grid2d,
        sampleShape: const [],
        tags: const ['demo', 'analysis'],
        extra: const {
          'preview.width': '48',
          'preview.height': '32',
          'preview.start_ns': '1000000000',
          'preview.sample_period_ns': '250000000',
        },
      ),
      StreamDescriptor(
        channel: _volumeBlock.channel,
        kind: StreamKind.volume3d,
        sampleShape: const [],
        tags: const ['demo', 'volume'],
        extra: const {
          'preview.x_len': '12',
          'preview.y_len': '8',
          'preview.z_len': '6',
        },
      ),
      StreamDescriptor(
        channel: _eventBlock.channel,
        kind: StreamKind.eventSeries,
        sampleShape: const [],
        tags: const ['demo', 'events'],
        extra: const {
          'preview.start_ns': '1000000000',
          'preview.end_ns': '5000000000',
        },
      ),
    ];
  }

  static const int _sourceId = 1;

  late final SeriesBlock _seriesBlock;
  late final GridBlock _gridBlock;
  late final VolumeBlock _volumeBlock;
  late final EventSeriesBlock _eventBlock;
  late final List<StreamDescriptor> _streams;

  @override
  Future<OpenedSource> openSource(String uri) async {
    if (!uri.startsWith('demo://')) {
      throw BackendException(
        'unsupported',
        'The demo backend only accepts demo:// URIs.',
      );
    }

    return OpenedSource(
      sourceId: _sourceId,
      uri: uri,
      sourceName: 'Demo session',
      capabilities: const SourceCapabilities(
        catalogSearch: true,
        liveSubscriptions: false,
        volume3d: true,
        metadataWrite: false,
        batchRead: true,
      ),
    );
  }

  @override
  Future<void> closeSource(int sourceId) async {}

  @override
  Future<CatalogPage> catalog({
    required int sourceId,
    String? text,
    List<String> tags = const [],
    int offset = 0,
    int? limit,
  }) async {
    _assertSourceId(sourceId);
    final needle = text?.trim().toLowerCase();
    final normalizedTags = tags.map((tag) => tag.toLowerCase()).toList();
    var matches = _streams.where((stream) {
      final haystack = [
        stream.channel.id,
        stream.channel.displayName,
        stream.channel.unit ?? '',
        ...stream.tags,
        ...stream.channel.metadata.values,
      ].join(' ').toLowerCase();

      final textMatches =
          needle == null || needle.isEmpty || haystack.contains(needle);
      final tagMatches = normalizedTags.every(
        (tag) => stream.tags.any((candidate) => candidate.toLowerCase() == tag),
      );
      return textMatches && tagMatches;
    }).toList();

    final totalCount = matches.length;
    if (offset > 0) {
      matches = offset >= matches.length
          ? <StreamDescriptor>[]
          : matches.sublist(offset);
    }
    if (limit != null && matches.length > limit) {
      matches = matches.take(limit).toList();
    }
    return CatalogPage(
      totalCount: totalCount,
      offset: offset,
      streams: matches,
    );
  }

  @override
  Future<DataBlock> read({
    required int sourceId,
    required String channelId,
    required TimeRange timeRange,
    required ReadAggregation aggregation,
    int? maxPoints,
    bool allowGaps = false,
  }) async {
    _assertSourceId(sourceId);

    switch (channelId) {
      case 'DEMO.SINE':
        return _readSeriesBlock(
          _seriesBlock,
          timeRange: timeRange,
          aggregation: aggregation,
          maxPoints: maxPoints,
        );
      case '/derived/demo_spectrogram':
        return _gridBlock;
      case '/volumes/demo_cube':
        return _volumeBlock;
      case 'DEMO.EVENTS':
        return _eventBlock;
      default:
        throw BackendException(
          'not_found',
          'Unknown demo channel `$channelId`.',
        );
    }
  }

  @override
  void dispose() {}

  void _assertSourceId(int sourceId) {
    if (sourceId != _sourceId) {
      throw BackendException(
        'not_found',
        'Demo source `$sourceId` is not open.',
      );
    }
  }

  SeriesBlock _buildSeriesBlock() {
    const startNs = 1000000000;
    const samplePeriodNs = 7812500;
    const sampleRateHz = 128.0;
    final values = List<double>.generate(512, (index) {
      final t = index / 32.0;
      return math.sin(t) * 0.7 +
          math.cos(t / 3.0) * 0.22 +
          math.sin(t / 7.0) * 0.14;
    });

    return SeriesBlock(
      channel: const ChannelDescriptor(
        id: 'DEMO.SINE',
        displayName: 'Demo sine blend',
        unit: 'arb',
        sampleRateHz: sampleRateHz,
        metadata: {
          'preview.start_ns': '$startNs',
          'preview.sample_period_ns': '$samplePeriodNs',
        },
      ),
      axis: const RegularTimeAxis(
        startNs: startNs,
        samplePeriodNs: samplePeriodNs,
        len: 512,
      ),
      values: values,
      metadata: const {'demo.origin': 'synthetic', 'demo.family': 'series'},
    );
  }

  GridBlock _buildGridBlock() {
    const width = 48;
    const height = 32;
    final values = <double>[];
    for (var x = 0; x < width; x++) {
      for (var y = 0; y < height; y++) {
        final fx = x / width;
        final fy = y / height;
        final ridge = math.exp(-math.pow((fy - (0.2 + fx * 0.55)) * 7.0, 2));
        final bands = (math.sin(fx * 18.0) + 1.0) * 0.15;
        values.add((ridge + bands).clamp(0.0, 1.2));
      }
    }

    return GridBlock(
      channel: const ChannelDescriptor(
        id: '/derived/demo_spectrogram',
        displayName: 'Demo spectrogram',
        unit: null,
        sampleRateHz: null,
        metadata: {
          'preview.start_ns': '1000000000',
          'preview.sample_period_ns': '250000000',
        },
      ),
      xRange: const TimeRange(startNs: 1000000000, endNs: 13000000000),
      yLabel: 'Frequency',
      yUnit: 'Hz',
      width: width,
      height: height,
      values: values,
      metadata: const {'demo.origin': 'synthetic', 'demo.family': 'grid'},
    );
  }

  VolumeBlock _buildVolumeBlock() {
    const xLen = 12;
    const yLen = 8;
    const zLen = 6;
    final values = <double>[];
    for (var x = 0; x < xLen; x++) {
      for (var y = 0; y < yLen; y++) {
        for (var z = 0; z < zLen; z++) {
          final dx = (x - xLen / 2) / xLen;
          final dy = (y - yLen / 2) / yLen;
          final dz = (z - zLen / 2) / zLen;
          final distance = math.sqrt(dx * dx + dy * dy + dz * dz);
          values.add((1.0 - distance * 2.2).clamp(0.0, 1.0));
        }
      }
    }

    return VolumeBlock(
      channel: const ChannelDescriptor(
        id: '/volumes/demo_cube',
        displayName: 'Demo volume cube',
        unit: null,
        sampleRateHz: null,
        metadata: {
          'preview.x_len': '$xLen',
          'preview.y_len': '$yLen',
          'preview.z_len': '$zLen',
        },
      ),
      xLen: xLen,
      yLen: yLen,
      zLen: zLen,
      values: values,
      metadata: const {'demo.origin': 'synthetic', 'demo.family': 'volume'},
    );
  }

  EventSeriesBlock _buildEventBlock() {
    return EventSeriesBlock(
      channel: const ChannelDescriptor(
        id: 'DEMO.EVENTS',
        displayName: 'Demo events',
        unit: null,
        sampleRateHz: null,
        metadata: {
          'preview.start_ns': '1000000000',
          'preview.end_ns': '5000000000',
        },
      ),
      timeRange: const TimeRange(startNs: 1000000000, endNs: 5000000000),
      events: const [
        EventPoint(
          timestampNs: 1400000000,
          label: 'Acquisition start',
          metadata: {'severity': 'info'},
        ),
        EventPoint(
          timestampNs: 2200000000,
          label: 'Calibration step',
          metadata: {'severity': 'notice'},
        ),
        EventPoint(
          timestampNs: 3100000000,
          label: 'Threshold crossing',
          metadata: {'severity': 'warning'},
        ),
        EventPoint(
          timestampNs: 4600000000,
          label: 'Capture end',
          metadata: {'severity': 'info'},
        ),
      ],
      metadata: const {'demo.origin': 'synthetic', 'demo.family': 'events'},
    );
  }

  DataBlock _readSeriesBlock(
    SeriesBlock base, {
    required TimeRange timeRange,
    required ReadAggregation aggregation,
    required int? maxPoints,
  }) {
    final regularAxis = base.axis as RegularTimeAxis;
    final slice = _clipSeries(
      base.values,
      startNs: regularAxis.startNs,
      samplePeriodNs: regularAxis.samplePeriodNs,
      timeRange: timeRange,
    );

    switch (aggregation) {
      case ReadAggregation.raw:
        return slice;
      case ReadAggregation.mean:
        return _downsample(slice, maxPoints ?? 256, rms: false);
      case ReadAggregation.rms:
        return _downsample(slice, maxPoints ?? 256, rms: true);
      case ReadAggregation.spectrogram:
        return _syntheticSpectrogram(slice);
    }
  }

  SeriesBlock _clipSeries(
    List<double> values, {
    required int startNs,
    required int samplePeriodNs,
    required TimeRange timeRange,
  }) {
    final startIndex = math.max(
      0,
      (timeRange.startNs - startNs) ~/ samplePeriodNs,
    );
    final endIndexExclusive = math.min(
      values.length,
      math.max(
        startIndex + 1,
        (timeRange.endNs - startNs + samplePeriodNs - 1) ~/ samplePeriodNs,
      ),
    );
    final clippedValues = values.sublist(startIndex, endIndexExclusive);

    return SeriesBlock(
      channel: _seriesBlock.channel,
      axis: RegularTimeAxis(
        startNs: startNs + (startIndex * samplePeriodNs),
        samplePeriodNs: samplePeriodNs,
        len: clippedValues.length,
      ),
      values: clippedValues,
      metadata: _seriesBlock.metadata,
    );
  }

  SeriesBlock _downsample(
    SeriesBlock block,
    int maxPoints, {
    required bool rms,
  }) {
    if (block.values.length <= maxPoints || maxPoints <= 0) {
      return block;
    }

    final bucketSize = (block.values.length / maxPoints).ceil();
    final downsampled = <double>[];
    for (var index = 0; index < block.values.length; index += bucketSize) {
      final end = math.min(index + bucketSize, block.values.length);
      final bucket = block.values.sublist(index, end);
      if (rms) {
        final squared = bucket
            .map((value) => value * value)
            .reduce((a, b) => a + b);
        downsampled.add(math.sqrt(squared / bucket.length));
      } else {
        final sum = bucket.reduce((a, b) => a + b);
        downsampled.add(sum / bucket.length);
      }
    }

    final axis = block.axis as RegularTimeAxis;
    return SeriesBlock(
      channel: block.channel,
      axis: RegularTimeAxis(
        startNs: axis.startNs,
        samplePeriodNs: axis.samplePeriodNs * bucketSize,
        len: downsampled.length,
      ),
      values: downsampled,
      metadata: {...block.metadata, 'demo.aggregation': rms ? 'rms' : 'mean'},
    );
  }

  GridBlock _syntheticSpectrogram(SeriesBlock block) {
    const height = 24;
    final window = math.max(16, block.values.length ~/ 12);
    final step = math.max(8, window ~/ 2);
    final width = math.max(
      1,
      ((block.values.length - window) / step).floor() + 1,
    );

    final values = <double>[];
    for (var x = 0; x < width; x++) {
      final start = x * step;
      final slice = block.values.sublist(
        start,
        math.min(start + window, block.values.length),
      );
      for (var y = 0; y < height; y++) {
        final harmonic = (y + 1) / height;
        final weighted = slice.asMap().entries.fold<double>(0.0, (sum, entry) {
          return sum +
              entry.value.abs() *
                  math.sin((entry.key / slice.length) * math.pi * harmonic);
        });
        values.add(weighted / slice.length);
      }
    }

    final axis = block.axis as RegularTimeAxis;
    return GridBlock(
      channel: ChannelDescriptor(
        id: '${block.channel.id}:spectrogram',
        displayName: '${block.channel.displayName} spectrogram',
        unit: null,
        sampleRateHz: null,
        metadata: block.channel.metadata,
      ),
      xRange: TimeRange(
        startNs: axis.startNs,
        endNs: axis.startNs + axis.samplePeriodNs * block.values.length,
      ),
      yLabel: 'Frequency',
      yUnit: 'Hz',
      width: width,
      height: height,
      values: values,
      metadata: {...block.metadata, 'demo.aggregation': 'spectrogram'},
    );
  }
}

Map<String, String> _stringMapFromJson(Object? value) {
  final map = value as Map<dynamic, dynamic>? ?? const {};
  return {
    for (final entry in map.entries)
      entry.key.toString(): entry.value?.toString() ?? '',
  };
}

String _formatSampleRate(double value) {
  if (value >= 1000) {
    final khz = value / 1000;
    if ((khz - khz.round()).abs() < 0.05) {
      return '${khz.round()} kHz';
    }
    return '${khz.toStringAsFixed(1)} kHz';
  }
  if ((value - value.round()).abs() < 0.05) {
    return '${value.round()} Hz';
  }
  return '${value.toStringAsFixed(1)} Hz';
}

String _formatNanoseconds(int value) {
  final absValue = value.abs();
  if (absValue >= 1000000000) {
    return '${(value / 1000000000).toStringAsFixed(2)} s';
  }
  if (absValue >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)} ms';
  }
  if (absValue >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)} us';
  }
  return '$value ns';
}
