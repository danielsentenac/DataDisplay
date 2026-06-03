import 'dart:async';
import 'dart:convert' as dart_convert;
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' as pdf_core;
import 'package:pdf/widgets.dart' as pw;

import 'src/datadisplay_backend.dart';
import 'src/native_datadisplay_backend.dart';
import 'src/tomcat_live_poller.dart';

const _defaultSourceUri =
    'gwf:///home/sentenac/DATADISPLAY/data/V-raw-1446446000-100.gwf?series=raw';

void main() {
  runApp(const DatadisplayApp());
}

class DatadisplayApp extends StatelessWidget {
  const DatadisplayApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0A7B6C);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      primary: seed,
      secondary: const Color(0xFFDAA520),
      surface: const Color(0xFFF5F7F4),
    );

    return MaterialApp(
      title: 'DATADISPLAY',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF3F5F2),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: const Color(0xFF18211D),
          displayColor: const Color(0xFF18211D),
        ),
      ),
      home: const WorkspaceShell(),
    );
  }
}

enum WorkspaceSection {
  session('Session', Icons.space_dashboard_rounded),
  catalog('Catalog', Icons.view_list_rounded),
  plots('Plots', Icons.insights_rounded),
  backends('Backends', Icons.storage_rounded);

  const WorkspaceSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

class SeriesViewport {
  const SeriesViewport({
    required this.autoX,
    required this.autoY,
    required this.xMinNs,
    required this.xMaxNs,
    required this.yMin,
    required this.yMax,
  });

  final bool autoX;
  final bool autoY;
  final double xMinNs;
  final double xMaxNs;
  final double yMin;
  final double yMax;

  SeriesViewport copyWith({
    bool? autoX,
    bool? autoY,
    double? xMinNs,
    double? xMaxNs,
    double? yMin,
    double? yMax,
  }) {
    return SeriesViewport(
      autoX: autoX ?? this.autoX,
      autoY: autoY ?? this.autoY,
      xMinNs: xMinNs ?? this.xMinNs,
      xMaxNs: xMaxNs ?? this.xMaxNs,
      yMin: yMin ?? this.yMin,
      yMax: yMax ?? this.yMax,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SeriesViewport &&
        other.autoX == autoX &&
        other.autoY == autoY &&
        other.xMinNs == xMinNs &&
        other.xMaxNs == xMaxNs &&
        other.yMin == yMin &&
        other.yMax == yMax;
  }

  @override
  int get hashCode => Object.hash(autoX, autoY, xMinNs, xMaxNs, yMin, yMax);
}

enum SeriesDeckLayout {
  overlay('Overlay'),
  stacked('Stacked');

  const SeriesDeckLayout(this.label);

  final String label;
}

class SeriesDeckEntry {
  const SeriesDeckEntry({
    required this.stream,
    required this.series,
    this.windowRange,
  });

  final StreamDescriptor stream;
  final SeriesBlock series;
  final TimeRange? windowRange;
}

class SeriesDeckViewport {
  const SeriesDeckViewport({
    required this.autoX,
    required this.autoY,
    required this.xMinNs,
    required this.xMaxNs,
    required this.yMin,
    required this.yMax,
  });

  final bool autoX;
  final bool autoY;
  final double xMinNs;
  final double xMaxNs;
  final double yMin;
  final double yMax;

  SeriesDeckViewport copyWith({
    bool? autoX,
    bool? autoY,
    double? xMinNs,
    double? xMaxNs,
    double? yMin,
    double? yMax,
  }) {
    return SeriesDeckViewport(
      autoX: autoX ?? this.autoX,
      autoY: autoY ?? this.autoY,
      xMinNs: xMinNs ?? this.xMinNs,
      xMaxNs: xMaxNs ?? this.xMaxNs,
      yMin: yMin ?? this.yMin,
      yMax: yMax ?? this.yMax,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SeriesDeckViewport &&
        other.autoX == autoX &&
        other.autoY == autoY &&
        other.xMinNs == xMinNs &&
        other.xMaxNs == xMaxNs &&
        other.yMin == yMin &&
        other.yMax == yMax;
  }

  @override
  int get hashCode => Object.hash(autoX, autoY, xMinNs, xMaxNs, yMin, yMax);
}

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({NativeBackendLoadResult? nativeLoadResult})
    : nativeLoadResult = nativeLoadResult ?? NativeDatadisplayBackend.tryLoad();

  final NativeBackendLoadResult nativeLoadResult;

  static const int _catalogPageSize = 64;

  DatadisplayBackendClient? _activeBackend;
  OpenedSource? _source;
  final Map<int, List<StreamDescriptor>> _catalogPages =
      <int, List<StreamDescriptor>>{};
  final Set<int> _catalogPagesInFlight = <int>{};
  int _catalogTotalCount = 0;
  int _catalogGeneration = 0;
  StreamDescriptor? _selectedStream;
  DataBlock? _selectedBlock;
  SeriesViewport? _seriesViewport;
  List<SeriesDeckEntry> _seriesDeck = const [];
  SeriesDeckLayout _seriesDeckLayout = SeriesDeckLayout.overlay;
  bool _seriesDeckLogY = false;
  Set<String> _selectedSeriesForDeck = const <String>{};
  SeriesDeckViewport? _seriesDeckViewport;
  Map<String, SeriesDeckViewport> _stackedSeriesDeckViewports = const {};
  int? _seriesDeckSelectionAnchorIndex;
  String _catalogSearch = '';
  ReadAggregation _aggregation = ReadAggregation.raw;
  int _maxPoints = 2048;
  TimeRange? _sourceTimeRange;
  TimeRange? _readTimeRange;
  double _dynamicChunkPercent = 10.0;
  Timer? _dynamicPlaybackTimer;
  int? _playbackStartNs;
  int? _playbackWindowNs;
  int? _playbackVisibleDurationNs;
  bool _dynamicReadInFlight = false;
  bool _busy = false;
  bool _initialized = false;
  String? _errorMessage;
  String? _infoMessage;
  bool _disposed = false;

  bool get isBusy => _busy;
  bool get isInitialized => _initialized;
  String? get errorMessage => _errorMessage;
  String? get infoMessage => _infoMessage;
  OpenedSource? get source => _source;
  List<StreamDescriptor> get streams => _loadedCatalogStreams();
  int get loadedCatalogCount => _loadedCatalogStreams().length;
  int get catalogTotalCount => _catalogTotalCount;
  int get catalogPageSize => _catalogPageSize;
  StreamDescriptor? get selectedStream => _selectedStream;
  DataBlock? get selectedBlock => _selectedBlock;
  SeriesViewport? get seriesViewport => _seriesViewport;
  List<SeriesDeckEntry> get seriesDeck => _seriesDeck;
  SeriesDeckLayout get seriesDeckLayout => _seriesDeckLayout;
  bool get seriesDeckLogY => _seriesDeckLogY;
  Set<String> get selectedSeriesForDeck => _selectedSeriesForDeck;
  SeriesDeckViewport? get seriesDeckViewport => _seriesDeckViewport;
  bool get seriesDeckAutoXEnabled {
    if (_seriesDeck.isEmpty) {
      return true;
    }
    if (_seriesDeckLayout == SeriesDeckLayout.stacked) {
      return _seriesDeck.every(
        (entry) =>
            (stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                    _autoSeriesDeckViewportForEntry(
                      entry,
                      logY: _seriesDeckLogY,
                    ))
                .autoX,
      );
    }
    return (_seriesDeckViewport ??
            _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY))
        .autoX;
  }

  bool get seriesDeckAutoYEnabled {
    if (_seriesDeck.isEmpty) {
      return true;
    }
    if (_seriesDeckLayout == SeriesDeckLayout.stacked) {
      return _seriesDeck.every(
        (entry) =>
            (stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                    _autoSeriesDeckViewportForEntry(
                      entry,
                      logY: _seriesDeckLogY,
                    ))
                .autoY,
      );
    }
    return (_seriesDeckViewport ??
            _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY))
        .autoY;
  }

  String get catalogSearch => _catalogSearch;
  ReadAggregation get aggregation => _aggregation;
  int get maxPoints => _maxPoints;
  TimeRange? get sourceTimeRange => _sourceTimeRange;
  TimeRange? get readTimeRange => _readTimeRange;
  TimeRange? get configuredReadWindowRange {
    final playbackStartNs = _playbackStartNs;
    final playbackWindowNs = _playbackWindowNs;
    if (playbackStartNs != null && playbackWindowNs != null) {
      return TimeRange(
        startNs: playbackStartNs,
        endNs: playbackStartNs + playbackWindowNs,
      );
    }
    return _readTimeRange;
  }

  double get dynamicChunkPercent => _dynamicChunkPercent;
  bool get dynamicPlaybackActive => _dynamicPlaybackTimer != null;

  String get runtimeLabel => nativeLoadResult.statusLabel;
  String get runtimeDetail => nativeLoadResult.statusDetail;
  List<String> get searchedPaths => nativeLoadResult.searchedPaths;
  bool get nativeAvailable => nativeLoadResult.available;

  String get activeBackendLabel {
    final backend = _activeBackend;
    if (backend == null) {
      return 'No backend';
    }
    return 'Native dd-ffi';
  }

  List<StreamDescriptor> _loadedCatalogStreams() {
    final entries = _catalogPages.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return entries.expand((entry) => entry.value).toList(growable: false);
  }

  StreamDescriptor? _preferredStreamFrom(Iterable<StreamDescriptor> streams) {
    for (final stream in streams) {
      if (stream.isScalarTimeseries) {
        return stream;
      }
    }
    for (final stream in streams) {
      return stream;
    }
    return null;
  }

  StreamDescriptor? cachedCatalogStreamById(String channelId) {
    for (final stream in _loadedCatalogStreams()) {
      if (stream.channel.id == channelId) {
        return stream;
      }
    }
    return null;
  }

  StreamDescriptor? catalogStreamAt(int index) {
    if (index < 0 || index >= _catalogTotalCount) {
      return null;
    }
    final pageStart = (index ~/ _catalogPageSize) * _catalogPageSize;
    final page = _catalogPages[pageStart];
    if (page == null) {
      return null;
    }
    final localIndex = index - pageStart;
    if (localIndex < 0 || localIndex >= page.length) {
      return null;
    }
    return page[localIndex];
  }

  bool isCatalogIndexLoaded(int index) => catalogStreamAt(index) != null;

  Future<void> ensureCatalogRange(int firstIndex, int lastIndex) async {
    if (_source == null || _activeBackend == null || _catalogTotalCount == 0) {
      return;
    }
    final clampedFirst = math.max(0, firstIndex);
    final clampedLast = math.min(_catalogTotalCount - 1, lastIndex);
    if (clampedLast < clampedFirst) {
      return;
    }

    final futures = <Future<void>>[];
    var offset = (clampedFirst ~/ _catalogPageSize) * _catalogPageSize;
    final lastOffset = (clampedLast ~/ _catalogPageSize) * _catalogPageSize;
    while (offset <= lastOffset) {
      futures.add(_ensureCatalogPage(offset));
      offset += _catalogPageSize;
    }
    await Future.wait(futures);
  }

  Future<void> _ensureCatalogPage(int offset) async {
    final source = _source;
    final backend = _activeBackend;
    if (source == null || backend == null) {
      return;
    }
    if (_catalogPages.containsKey(offset) ||
        _catalogPagesInFlight.contains(offset)) {
      return;
    }

    final generation = _catalogGeneration;
    _catalogPagesInFlight.add(offset);
    if (!_disposed) {
      notifyListeners();
    }

    try {
      final page = await backend.catalog(
        sourceId: source.sourceId,
        text: _catalogSearch.isEmpty ? null : _catalogSearch,
        offset: offset,
        limit: _catalogPageSize,
      );
      if (_disposed || generation != _catalogGeneration) {
        return;
      }
      _catalogTotalCount = page.totalCount;
      _catalogPages[offset] = page.streams;
      final selectedId = _selectedStream?.channel.id;
      if (selectedId != null) {
        final refreshed = page.streams.cast<StreamDescriptor?>().firstWhere(
          (candidate) => candidate?.channel.id == selectedId,
          orElse: () => null,
        );
        if (refreshed != null) {
          _selectedStream = refreshed;
        }
      }
      _clearError();
    } on BackendException catch (error) {
      if (_disposed || generation != _catalogGeneration) {
        return;
      }
      _setError(error.message);
    } catch (error) {
      if (_disposed || generation != _catalogGeneration) {
        return;
      }
      _setError('Catalog page query failed: $error');
    } finally {
      _catalogPagesInFlight.remove(offset);
      if (!_disposed && generation == _catalogGeneration) {
        notifyListeners();
      }
    }
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await openSource(_defaultSourceUri);
  }

  Future<void> openSource(String uri) async {
    final trimmedUri = uri.trim();
    if (trimmedUri.isEmpty) {
      _setError('Source URI must not be empty.');
      return;
    }

    await _runBusy(() async {
      final backend = _backendForUri(trimmedUri);
      final previousBackend = _activeBackend;
      final previousSource = _source;

      try {
        final opened = await backend.openSource(trimmedUri);
        _activeBackend = backend;
        _source = opened;
        _stopDynamicPlayback(notify: false);
        _sourceTimeRange = _sourceTimeRangeFromUri(trimmedUri);
        _catalogGeneration += 1;
        _catalogPages.clear();
        _catalogPagesInFlight.clear();
        _catalogTotalCount = 0;
        _selectedStream = null;
        _selectedBlock = null;
        _seriesViewport = null;
        _seriesDeck = const [];
        _selectedSeriesForDeck = const <String>{};
        _seriesDeckViewport = null;
        _stackedSeriesDeckViewports = const {};
        _seriesDeckSelectionAnchorIndex = null;
        _readTimeRange = null;
        _clearError();
        _infoMessage = 'Native source opened through dd-ffi.';
        notifyListeners();

        if (previousSource != null && previousBackend != null) {
          try {
            await previousBackend.closeSource(previousSource.sourceId);
          } catch (_) {}
        }

        await _refreshCatalog(autoSelectFirst: true);
      } on BackendException catch (error) {
        _setError(error.message);
      } catch (error) {
        _setError('Failed to open source: $error');
      }
    });
  }

  Future<void> applyCatalogSearch(String value) async {
    _catalogSearch = value.trim();
    notifyListeners();
    if (_source == null || _activeBackend == null) {
      return;
    }
    await _runBusy(() => _refreshCatalog(autoSelectFirst: false));
  }

  Future<void> selectStream(StreamDescriptor stream) async {
    _stopDynamicPlayback(notify: false);
    _selectedStream = stream;
    _selectedBlock = null;
    _seriesViewport = null;
    _readTimeRange ??= _initialReadTimeRangeForStream(stream);
    _clearError();
    notifyListeners();
  }

  Future<void> setAggregation(ReadAggregation aggregation) async {
    _aggregation = aggregation;
    notifyListeners();
    if (dynamicPlaybackActive && _readTimeRange != null) {
      await _refreshSeriesDeckForReadRange(_readTimeRange!);
    }
  }

  Future<void> setMaxPoints(int maxPoints) async {
    _maxPoints = math.max(16, maxPoints);
    notifyListeners();
    if (dynamicPlaybackActive && _readTimeRange != null) {
      await _refreshSeriesDeckForReadRange(_readTimeRange!);
    }
  }

  Future<void> refreshReadPreview() async {
    final source = _source;
    final backend = _activeBackend;
    final stream = _selectedStream;
    if (source == null || backend == null || stream == null) {
      return;
    }

    await _runBusy(() async {
      try {
        final block = await _readBlockForStream(
          backend: backend,
          sourceId: source.sourceId,
          stream: stream,
          timeRange: _readTimeRange,
        );
        _selectedBlock = block;
        final scalarSeries = _asScalarSeriesBlock(block);
        if (scalarSeries != null) {
          _replaceSeriesInDeckIfPresent(
            stream,
            scalarSeries,
            windowRange: configuredReadWindowRange,
          );
        }
        _seriesViewport = scalarSeries != null
            ? _viewportForReadResult(scalarSeries)
            : null;
        _clearError();
        notifyListeners();
      } on BackendException catch (error) {
        _setError(error.message);
      } catch (error) {
        _setError('Read failed: $error');
      }
    });
  }

  void _replaceSeriesInDeckIfPresent(
    StreamDescriptor stream,
    SeriesBlock scalarSeries, {
    TimeRange? windowRange,
  }) {
    final index = _seriesDeck.indexWhere(
      (entry) => entry.stream.channel.id == stream.channel.id,
    );
    if (index < 0) {
      return;
    }
    final nextDeck = [..._seriesDeck];
    nextDeck[index] = SeriesDeckEntry(
      stream: stream,
      series: scalarSeries,
      windowRange: windowRange == null
          ? null
          : _clampReadTimeRange(windowRange),
    );
    _seriesDeck = nextDeck;
    _syncSeriesDeckViewport();
  }

  void _syncSeriesDeckViewport() {
    if (_seriesDeck.isEmpty) {
      _seriesDeckViewport = null;
      _stackedSeriesDeckViewports = const {};
      return;
    }
    final currentViewport = _seriesDeckViewport;
    _seriesDeckViewport = currentViewport == null
        ? _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY)
        : _normalizeSeriesDeckViewport(
            _seriesDeck,
            currentViewport,
            logY: _seriesDeckLogY,
          );
    final nextStackedViewports = <String, SeriesDeckViewport>{};
    for (final entry in _seriesDeck) {
      final current = _stackedSeriesDeckViewports[entry.stream.channel.id];
      nextStackedViewports[entry.stream.channel.id] = current == null
          ? _autoSeriesDeckViewportForEntry(entry, logY: _seriesDeckLogY)
          : _normalizeSeriesDeckViewportForEntry(
              entry,
              current,
              logY: _seriesDeckLogY,
            );
    }
    _stackedSeriesDeckViewports = nextStackedViewports;
  }

  SeriesDeckViewport? stackedSeriesDeckViewportFor(String channelId) {
    final entry = _seriesDeckEntryByChannelId(channelId);
    if (entry == null) {
      return null;
    }
    return _stackedSeriesDeckViewports[channelId] ??
        _autoSeriesDeckViewportForEntry(entry, logY: _seriesDeckLogY);
  }

  SeriesDeckEntry? _seriesDeckEntryByChannelId(String channelId) {
    for (final entry in _seriesDeck) {
      if (entry.stream.channel.id == channelId) {
        return entry;
      }
    }
    return null;
  }

  SeriesDeckEntry _placeholderSeriesDeckEntry(
    StreamDescriptor stream, {
    TimeRange? windowRange,
    SeriesBlock? series,
  }) {
    final effectiveRange = _clampReadTimeRange(
      windowRange ?? _readTimeRange ?? _initialReadTimeRangeForStream(stream),
    );
    return SeriesDeckEntry(
      stream: stream,
      series: series ?? _emptySeriesForStream(stream, effectiveRange),
      windowRange: effectiveRange,
    );
  }

  SeriesBlock _emptySeriesForStream(StreamDescriptor stream, TimeRange range) {
    final samplePeriodNs =
        _samplePeriodFromRate(stream.channel.sampleRateHz) ?? 1;
    final effectiveStepNs = math.max(1, samplePeriodNs);
    return SeriesBlock(
      channel: stream.channel,
      axis: RegularTimeAxis(
        startNs: range.startNs,
        samplePeriodNs: effectiveStepNs,
        len: 0,
      ),
      values: const [],
      metadata: {
        'preview.start_ns': range.startNs.toString(),
        'preview.end_ns': range.endNs.toString(),
        'preview.sample_period_ns': effectiveStepNs.toString(),
      },
    );
  }

  void _applyConfiguredWindowToDeck({required bool clearSeries}) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    final configuredRange = configuredReadWindowRange;
    _seriesDeck = [
      for (final entry in _seriesDeck)
        _placeholderSeriesDeckEntry(
          entry.stream,
          windowRange: configuredRange ?? entry.windowRange,
          series: clearSeries ? null : entry.series,
        ),
    ];
    _syncSeriesDeckViewport();
  }

  Future<void> addSelectedSeriesToDeck() async {
    final stream = _selectedStream;
    if (stream == null) {
      return;
    }
    if (!stream.isScalarTimeseries) {
      _setError('Only 1D series channels can be added to the plot deck.');
      return;
    }

    final nextDeck = [..._seriesDeck];
    final index = nextDeck.indexWhere(
      (entry) => entry.stream.channel.id == stream.channel.id,
    );
    final previous = index >= 0 ? nextDeck[index] : null;
    final entry = _placeholderSeriesDeckEntry(
      stream,
      windowRange: configuredReadWindowRange ?? previous?.windowRange,
      series: previous?.series,
    );
    if (index >= 0) {
      nextDeck[index] = entry;
    } else {
      nextDeck.add(entry);
    }

    _seriesDeck = nextDeck;
    _syncSeriesDeckViewport();
    _clearError();
    _infoMessage =
        'Added ${stream.channel.displayName} to the plot deck. Start dynamic playback to load data.';
    notifyListeners();
  }

  void toggleSeriesDeckSelection(String channelId) {
    final next = {..._selectedSeriesForDeck};
    if (next.contains(channelId)) {
      next.remove(channelId);
    } else {
      next.add(channelId);
    }
    _selectedSeriesForDeck = next;
    notifyListeners();
  }

  void applyCatalogSeriesDeckSelection({
    required String channelId,
    required int index,
    required bool additive,
    required bool rangeSelect,
  }) {
    final next = additive ? {..._selectedSeriesForDeck} : <String>{};
    final anchorIndex = _seriesDeckSelectionAnchorIndex ?? index;

    if (rangeSelect) {
      final start = math.min(anchorIndex, index);
      final end = math.max(anchorIndex, index);
      for (var current = start; current <= end; current++) {
        final stream = catalogStreamAt(current);
        if (stream?.isScalarTimeseries ?? false) {
          next.add(stream!.channel.id);
        }
      }
    } else if (additive) {
      if (next.contains(channelId)) {
        next.remove(channelId);
      } else {
        next.add(channelId);
      }
    } else {
      final wasOnlySelected =
          _selectedSeriesForDeck.length == 1 &&
          _selectedSeriesForDeck.contains(channelId);
      next.clear();
      if (!wasOnlySelected) {
        next.add(channelId);
      }
    }

    _selectedSeriesForDeck = next;
    _seriesDeckSelectionAnchorIndex = index;
    notifyListeners();
  }

  void clearSeriesDeckSelection() {
    if (_selectedSeriesForDeck.isEmpty) {
      return;
    }
    _selectedSeriesForDeck = const <String>{};
    _seriesDeckSelectionAnchorIndex = null;
    notifyListeners();
  }

  void selectCachedSeriesForDeck() {
    _selectedSeriesForDeck = _loadedCatalogStreams()
        .where((stream) => stream.isScalarTimeseries)
        .map((stream) => stream.channel.id)
        .toSet();
    _seriesDeckSelectionAnchorIndex = null;
    notifyListeners();
  }

  Future<void> addSelectedCatalogSeriesToDeck() async {
    if (_selectedSeriesForDeck.isEmpty) {
      return;
    }

    final selectedStreams = _selectedSeriesForDeck
        .map(cachedCatalogStreamById)
        .whereType<StreamDescriptor>()
        .where((stream) => stream.isScalarTimeseries)
        .toList(growable: false);
    if (selectedStreams.isEmpty) {
      _setError('No selected 1D series channels are available in the catalog.');
      return;
    }

    final nextDeck = [..._seriesDeck];
    for (final stream in selectedStreams) {
      final index = nextDeck.indexWhere(
        (candidate) => candidate.stream.channel.id == stream.channel.id,
      );
      final previous = index >= 0 ? nextDeck[index] : null;
      final entry = _placeholderSeriesDeckEntry(
        stream,
        windowRange: configuredReadWindowRange ?? previous?.windowRange,
        series: previous?.series,
      );
      if (index >= 0) {
        nextDeck[index] = entry;
      } else {
        nextDeck.add(entry);
      }
    }

    _seriesDeck = nextDeck;
    _syncSeriesDeckViewport();
    _clearError();
    _infoMessage =
        'Added ${selectedStreams.length} selected series channel${selectedStreams.length == 1 ? '' : 's'} to the plot deck. Start dynamic playback to load data.';
    notifyListeners();
  }

  void removeSeriesFromDeck(String channelId) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    _seriesDeck = _seriesDeck
        .where((entry) => entry.stream.channel.id != channelId)
        .toList(growable: false);
    if (_seriesDeck.isEmpty) {
      _stopDynamicPlayback(notify: false);
    }
    _syncSeriesDeckViewport();
    _clearError();
    notifyListeners();
  }

  void clearSeriesDeck() {
    if (_seriesDeck.isEmpty) {
      return;
    }
    _stopDynamicPlayback(notify: false);
    _seriesDeck = const [];
    _seriesDeckViewport = null;
    _stackedSeriesDeckViewports = const {};
    _clearError();
    notifyListeners();
  }

  /// Exports the current deck to an ASCII file with one block per channel.
  /// Each block has a header comment then `<gps_seconds>\t<value>` lines.
  /// Returns the absolute path of the written file, or null on failure.
  Future<String?> exportDeckAsAscii() async {
    if (_seriesDeck.isEmpty) {
      _setError('Plot deck is empty — add channels before exporting.');
      return null;
    }
    try {
      final dir = _resolveExportDirectory();
      final stamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .split('.')
          .first;
      final file = io.File('${dir.path}/datadisplay-$stamp.txt');
      final buffer = StringBuffer();
      buffer.writeln(
        '# DATADISPLAY ASCII export ${DateTime.now().toUtc().toIso8601String()}',
      );
      buffer.writeln('# source: ${_source?.uri ?? "unknown"}');
      buffer.writeln('# channels: ${_seriesDeck.length}');
      buffer.writeln('# format: blocks of <gps_seconds>\\t<value> per channel');
      buffer.writeln('#');
      for (final entry in _seriesDeck) {
        final ch = entry.stream.channel;
        final series = entry.series;
        final unit = ch.unit == null || ch.unit!.isEmpty ? '-' : ch.unit!;
        final rate = ch.sampleRateHz?.toString() ?? '-';
        buffer.writeln('# channel: ${ch.id}');
        buffer.writeln('# display_name: ${ch.displayName}');
        buffer.writeln('# unit: $unit');
        buffer.writeln('# sample_rate_hz: $rate');
        buffer.writeln('# samples: ${series.values.length}');
        for (var i = 0; i < series.values.length; i++) {
          final tNs = _seriesTimestampNs(series, i);
          final tSec = tNs / 1.0e9;
          final v = series.values[i];
          final vStr = v.isFinite ? v.toString() : 'NaN';
          buffer.writeln('${tSec.toStringAsFixed(9)}\t$vStr');
        }
        buffer.writeln();
      }
      await file.writeAsString(buffer.toString());
      _infoMessage = 'Exported deck to ${file.path}';
      _clearError();
      notifyListeners();
      return file.path;
    } catch (error) {
      _setError('ASCII export failed: $error');
      return null;
    }
  }

  io.Directory _resolveExportDirectory() {
    final env = io.Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final downloads = io.Directory('$home/Downloads');
      if (downloads.existsSync()) {
        return downloads;
      }
      return io.Directory(home);
    }
    return io.Directory.systemTemp;
  }

  void setSeriesDeckLayout(SeriesDeckLayout layout) {
    if (_seriesDeckLayout == layout) {
      return;
    }
    _seriesDeckLayout = layout;
    notifyListeners();
  }

  void setSeriesDeckLogY(bool enabled) {
    if (_seriesDeckLogY == enabled) {
      return;
    }
    _seriesDeckLogY = enabled;
    if (_seriesDeck.isNotEmpty) {
      _seriesDeckViewport = _autoSeriesDeckViewport(_seriesDeck, logY: enabled);
      _stackedSeriesDeckViewports = {
        for (final entry in _seriesDeck)
          entry.stream.channel.id: _autoSeriesDeckViewportForEntry(
            entry,
            logY: enabled,
          ),
      };
    }
    notifyListeners();
  }

  void autoScaleSeriesDeck() {
    if (_seriesDeck.isEmpty) {
      return;
    }
    if (_seriesDeckLayout == SeriesDeckLayout.stacked) {
      _stackedSeriesDeckViewports = {
        for (final entry in _seriesDeck)
          entry.stream.channel.id: _autoSeriesDeckViewportForEntry(
            entry,
            logY: _seriesDeckLogY,
          ),
      };
    }
    _seriesDeckViewport = _autoSeriesDeckViewport(
      _seriesDeck,
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void setSeriesDeckAutoX(bool enabled) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    if (_seriesDeckLayout == SeriesDeckLayout.stacked) {
      _stackedSeriesDeckViewports = {
        for (final entry in _seriesDeck)
          entry.stream.channel.id: _normalizeSeriesDeckViewportForEntry(
            entry,
            (stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                    _autoSeriesDeckViewportForEntry(
                      entry,
                      logY: _seriesDeckLogY,
                    ))
                .copyWith(autoX: enabled),
            logY: _seriesDeckLogY,
          ),
      };
      notifyListeners();
      return;
    }
    final base = _seriesDeckViewport ??
        _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY);
    _seriesDeckViewport = _normalizeSeriesDeckViewport(
      _seriesDeck,
      base.copyWith(autoX: enabled),
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void setSeriesDeckAutoY(bool enabled) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    if (_seriesDeckLayout == SeriesDeckLayout.stacked) {
      _stackedSeriesDeckViewports = {
        for (final entry in _seriesDeck)
          entry.stream.channel.id: _normalizeSeriesDeckViewportForEntry(
            entry,
            (stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                    _autoSeriesDeckViewportForEntry(
                      entry,
                      logY: _seriesDeckLogY,
                    ))
                .copyWith(autoY: enabled),
            logY: _seriesDeckLogY,
          ),
      };
      notifyListeners();
      return;
    }
    final base = _seriesDeckViewport ??
        _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY);
    _seriesDeckViewport = _normalizeSeriesDeckViewport(
      _seriesDeck,
      base.copyWith(autoY: enabled),
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void zoomSeriesDeckX(double factor) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    final base = _seriesDeckViewport ??
        _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY);
    final span = base.xMaxNs - base.xMinNs;
    final center = (base.xMinNs + base.xMaxNs) / 2;
    final nextSpan = span * factor;
    _seriesDeckViewport = _normalizeSeriesDeckViewport(
      _seriesDeck,
      base.copyWith(
        autoX: false,
        xMinNs: center - nextSpan / 2,
        xMaxNs: center + nextSpan / 2,
      ),
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void panSeriesDeckX(double fraction) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    if (_seriesDeckLayout == SeriesDeckLayout.stacked) {
      _stackedSeriesDeckViewports = {
        for (final entry in _seriesDeck)
          entry.stream.channel.id: _panSeriesDeckViewportX(
            entry,
            stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                _autoSeriesDeckViewportForEntry(
                  entry,
                  logY: _seriesDeckLogY,
                ),
            fraction,
            logY: _seriesDeckLogY,
          ),
      };
      notifyListeners();
      return;
    }
    final base = _seriesDeckViewport ??
        _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY);
    final span = base.xMaxNs - base.xMinNs;
    final delta = span * fraction;
    _seriesDeckViewport = _normalizeSeriesDeckViewport(
      _seriesDeck,
      base.copyWith(
        autoX: false,
        xMinNs: base.xMinNs + delta,
        xMaxNs: base.xMaxNs + delta,
      ),
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void zoomSeriesDeckY(double factor) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    final base = _seriesDeckViewport ??
        _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY);
    double newYMin;
    double newYMax;
    if (_seriesDeckLogY) {
      final bounds = _logScaledYBounds(
        base.yMin,
        base.yMax,
        zoomFactor: factor,
      );
      newYMin = bounds.$1;
      newYMax = bounds.$2;
    } else {
      final span = base.yMax - base.yMin;
      final center = (base.yMin + base.yMax) / 2;
      final nextSpan = span * factor;
      newYMin = center - nextSpan / 2;
      newYMax = center + nextSpan / 2;
    }
    _seriesDeckViewport = _normalizeSeriesDeckViewport(
      _seriesDeck,
      base.copyWith(autoY: false, yMin: newYMin, yMax: newYMax),
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void panSeriesDeckY(double fraction) {
    if (_seriesDeck.isEmpty) {
      return;
    }
    if (_seriesDeckLayout == SeriesDeckLayout.stacked) {
      _stackedSeriesDeckViewports = {
        for (final entry in _seriesDeck)
          entry.stream.channel.id: _panSeriesDeckViewportY(
            entry,
            stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                _autoSeriesDeckViewportForEntry(
                  entry,
                  logY: _seriesDeckLogY,
                ),
            fraction,
            logY: _seriesDeckLogY,
          ),
      };
      notifyListeners();
      return;
    }
    final base = _seriesDeckViewport ??
        _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY);
    double newYMin;
    double newYMax;
    if (_seriesDeckLogY) {
      final bounds = _logScaledYBounds(
        base.yMin,
        base.yMax,
        panFraction: fraction,
      );
      newYMin = bounds.$1;
      newYMax = bounds.$2;
    } else {
      final span = base.yMax - base.yMin;
      final delta = span * fraction;
      newYMin = base.yMin + delta;
      newYMax = base.yMax + delta;
    }
    _seriesDeckViewport = _normalizeSeriesDeckViewport(
      _seriesDeck,
      base.copyWith(autoY: false, yMin: newYMin, yMax: newYMax),
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void applySeriesDeckManualBounds({
    double? xMinNs,
    double? xMaxNs,
    double? yMin,
    double? yMax,
  }) {
    if (_seriesDeck.isEmpty) {
      return;
    }

    final base = _seriesDeckViewport ??
        _autoSeriesDeckViewport(_seriesDeck, logY: _seriesDeckLogY);
    final useX = xMinNs != null || xMaxNs != null;
    final useY = yMin != null || yMax != null;
    final nextXMin = xMinNs ?? base.xMinNs;
    final nextXMax = xMaxNs ?? base.xMaxNs;
    final nextYMin = yMin ?? base.yMin;
    final nextYMax = yMax ?? base.yMax;

    if (useX && nextXMax <= nextXMin) {
      return;
    }
    if (useY && nextYMax <= nextYMin) {
      return;
    }

    _seriesDeckViewport = _normalizeSeriesDeckViewport(
      _seriesDeck,
      base.copyWith(
        autoX: useX ? false : base.autoX,
        autoY: useY ? false : base.autoY,
        xMinNs: nextXMin,
        xMaxNs: nextXMax,
        yMin: nextYMin,
        yMax: nextYMax,
      ),
      logY: _seriesDeckLogY,
    );
    notifyListeners();
  }

  void autoScaleStackedSeries(String channelId) {
    final entry = _seriesDeckEntryByChannelId(channelId);
    if (entry == null) {
      return;
    }
    final next = {..._stackedSeriesDeckViewports};
    next[channelId] = _autoSeriesDeckViewportForEntry(
      entry,
      logY: _seriesDeckLogY,
    );
    _stackedSeriesDeckViewports = next;
    notifyListeners();
  }

  void setStackedSeriesAutoX(String channelId, bool enabled) {
    final entry = _seriesDeckEntryByChannelId(channelId);
    if (entry == null) {
      return;
    }
    final base =
        stackedSeriesDeckViewportFor(channelId) ??
        _autoSeriesDeckViewportForEntry(entry, logY: _seriesDeckLogY);
    final next = {..._stackedSeriesDeckViewports};
    next[channelId] = _normalizeSeriesDeckViewportForEntry(
      entry,
      base.copyWith(autoX: enabled),
      logY: _seriesDeckLogY,
    );
    _stackedSeriesDeckViewports = next;
    notifyListeners();
  }

  void setStackedSeriesAutoY(String channelId, bool enabled) {
    final entry = _seriesDeckEntryByChannelId(channelId);
    if (entry == null) {
      return;
    }
    final base =
        stackedSeriesDeckViewportFor(channelId) ??
        _autoSeriesDeckViewportForEntry(entry, logY: _seriesDeckLogY);
    final next = {..._stackedSeriesDeckViewports};
    next[channelId] = _normalizeSeriesDeckViewportForEntry(
      entry,
      base.copyWith(autoY: enabled),
      logY: _seriesDeckLogY,
    );
    _stackedSeriesDeckViewports = next;
    notifyListeners();
  }

  void applyStackedSeriesViewport(
    String channelId,
    SeriesDeckViewport viewport,
  ) {
    final entry = _seriesDeckEntryByChannelId(channelId);
    if (entry == null) {
      return;
    }
    final next = {..._stackedSeriesDeckViewports};
    next[channelId] = _normalizeSeriesDeckViewportForEntry(
      entry,
      viewport,
      logY: _seriesDeckLogY,
    );
    _stackedSeriesDeckViewports = next;
    notifyListeners();
  }

  void copyStackedSeriesXToAll(String channelId) {
    final sourceViewport = stackedSeriesDeckViewportFor(channelId);
    if (sourceViewport == null) {
      return;
    }
    _stackedSeriesDeckViewports = {
      for (final entry in _seriesDeck)
        entry.stream.channel.id: _normalizeSeriesDeckViewportForEntry(
          entry,
          (stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                  _autoSeriesDeckViewportForEntry(
                    entry,
                    logY: _seriesDeckLogY,
                  ))
              .copyWith(
                autoX: false,
                xMinNs: sourceViewport.xMinNs,
                xMaxNs: sourceViewport.xMaxNs,
              ),
          logY: _seriesDeckLogY,
        ),
    };
    notifyListeners();
  }

  void copyStackedSeriesYToAll(String channelId) {
    final sourceViewport = stackedSeriesDeckViewportFor(channelId);
    if (sourceViewport == null) {
      return;
    }
    _stackedSeriesDeckViewports = {
      for (final entry in _seriesDeck)
        entry.stream.channel.id: _normalizeSeriesDeckViewportForEntry(
          entry,
          (stackedSeriesDeckViewportFor(entry.stream.channel.id) ??
                  _autoSeriesDeckViewportForEntry(
                    entry,
                    logY: _seriesDeckLogY,
                  ))
              .copyWith(
                autoY: false,
                yMin: sourceViewport.yMin,
                yMax: sourceViewport.yMax,
              ),
          logY: _seriesDeckLogY,
        ),
    };
    notifyListeners();
  }

  void autoScaleSeriesViewport() {
    final series = _currentSeriesBlock();
    if (series == null) {
      return;
    }
    _seriesViewport = _autoSeriesViewportFor(series);
    _clearError();
    notifyListeners();
  }

  void resetSeriesViewport() {
    autoScaleSeriesViewport();
  }

  void setSeriesAutoX(bool enabled) {
    final series = _currentSeriesBlock();
    if (series == null) {
      return;
    }
    final base = _seriesViewport ?? _autoSeriesViewportFor(series);
    _seriesViewport = _normalizeSeriesViewport(
      series,
      base.copyWith(autoX: enabled),
    );
    _clearError();
    notifyListeners();
  }

  void setSeriesAutoY(bool enabled) {
    final series = _currentSeriesBlock();
    if (series == null) {
      return;
    }
    final base = _seriesViewport ?? _autoSeriesViewportFor(series);
    _seriesViewport = _normalizeSeriesViewport(
      series,
      base.copyWith(autoY: enabled),
    );
    _clearError();
    notifyListeners();
  }

  void zoomSeriesX(double factor) {
    final series = _currentSeriesBlock();
    if (series == null) {
      return;
    }
    final base = _seriesViewport ?? _autoSeriesViewportFor(series);
    final span = base.xMaxNs - base.xMinNs;
    final center = (base.xMinNs + base.xMaxNs) / 2;
    final nextSpan = span * factor;
    _seriesViewport = _normalizeSeriesViewport(
      series,
      base.copyWith(
        autoX: false,
        xMinNs: center - nextSpan / 2,
        xMaxNs: center + nextSpan / 2,
      ),
    );
    _clearError();
    notifyListeners();
  }

  void zoomSeriesY(double factor) {
    final series = _currentSeriesBlock();
    if (series == null) {
      return;
    }
    final base = _seriesViewport ?? _autoSeriesViewportFor(series);
    final span = base.yMax - base.yMin;
    final center = (base.yMin + base.yMax) / 2;
    final nextSpan = span * factor;
    _seriesViewport = _normalizeSeriesViewport(
      series,
      base.copyWith(
        autoY: false,
        yMin: center - nextSpan / 2,
        yMax: center + nextSpan / 2,
      ),
    );
    _clearError();
    notifyListeners();
  }

  void panSeriesX(double fraction) {
    final series = _currentSeriesBlock();
    if (series == null) {
      return;
    }
    final base = _seriesViewport ?? _autoSeriesViewportFor(series);
    final span = base.xMaxNs - base.xMinNs;
    final delta = span * fraction;
    _seriesViewport = _normalizeSeriesViewport(
      series,
      base.copyWith(
        autoX: false,
        xMinNs: base.xMinNs + delta,
        xMaxNs: base.xMaxNs + delta,
      ),
    );
    _clearError();
    notifyListeners();
  }

  void applySeriesManualBounds({
    double? xMinNs,
    double? xMaxNs,
    double? yMin,
    double? yMax,
  }) {
    final series = _currentSeriesBlock();
    if (series == null) {
      return;
    }

    final base = _seriesViewport ?? _autoSeriesViewportFor(series);
    final useX = xMinNs != null || xMaxNs != null;
    final useY = yMin != null || yMax != null;
    final nextXMin = xMinNs ?? base.xMinNs;
    final nextXMax = xMaxNs ?? base.xMaxNs;
    final nextYMin = yMin ?? base.yMin;
    final nextYMax = yMax ?? base.yMax;

    if (useX && nextXMax <= nextXMin) {
      _setError('Plot X maximum must be greater than the minimum.');
      return;
    }
    if (useY && nextYMax <= nextYMin) {
      _setError('Plot Y maximum must be greater than the minimum.');
      return;
    }

    _seriesViewport = _normalizeSeriesViewport(
      series,
      base.copyWith(
        autoX: useX ? false : base.autoX,
        autoY: useY ? false : base.autoY,
        xMinNs: nextXMin,
        xMaxNs: nextXMax,
        yMin: nextYMin,
        yMax: nextYMax,
      ),
    );
    _clearError();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _dynamicPlaybackTimer?.cancel();
    nativeLoadResult.backend?.dispose();
    super.dispose();
  }

  TimeRange _initialReadTimeRangeForStream(StreamDescriptor stream) {
    final sourceRange = _sourceTimeRange;
    if (sourceRange != null) {
      const defaultWindowSec = 10.0;
      final durationNs = sourceRange.endNs - sourceRange.startNs;
      final windowNs = math.min(durationNs, (defaultWindowSec * 1.0e9).round());
      return TimeRange(
        startNs: sourceRange.startNs,
        endNs: sourceRange.startNs + math.max(1, windowNs),
      );
    }
    return _previewRangeForStream(stream);
  }

  TimeRange? _sourceTimeRangeFromUri(String uri) {
    final parsed = Uri.tryParse(uri);
    final fileName = parsed?.pathSegments.isNotEmpty == true
        ? parsed!.pathSegments.last
        : uri.split('/').last.split('?').first;
    final match = RegExp(
      r'-(\d+)-(\d+)\.gwf$',
      caseSensitive: false,
    ).firstMatch(fileName);
    if (match == null) {
      return null;
    }
    final startSec = int.tryParse(match.group(1) ?? '');
    final durationSec = int.tryParse(match.group(2) ?? '');
    if (startSec == null || durationSec == null || durationSec <= 0) {
      return null;
    }
    final startNs = startSec * 1000000000;
    final endNs = startNs + durationSec * 1000000000;
    return TimeRange(startNs: startNs, endNs: endNs);
  }

  TimeRange _clampReadTimeRange(TimeRange range) {
    final sourceRange = _sourceTimeRange;
    if (sourceRange == null) {
      return range;
    }
    final maxDurationNs = math.max(1, sourceRange.endNs - sourceRange.startNs);
    final requestedDurationNs = math.max(1, range.endNs - range.startNs);
    final effectiveDurationNs = math.min(requestedDurationNs, maxDurationNs);
    final maxStartNs = sourceRange.endNs - effectiveDurationNs;
    final clampedStartNs = range.startNs.clamp(sourceRange.startNs, maxStartNs);
    return TimeRange(
      startNs: clampedStartNs,
      endNs: clampedStartNs + effectiveDurationNs,
    );
  }

  SeriesViewport _viewportForReadResult(SeriesBlock series) {
    final range = configuredReadWindowRange;
    if (range == null) {
      return _autoSeriesViewportFor(series);
    }
    final (yMin, yMax) = _seriesYExtent(series);
    return SeriesViewport(
      autoX: false,
      autoY: true,
      xMinNs: range.startNs.toDouble(),
      xMaxNs: range.endNs.toDouble(),
      yMin: yMin,
      yMax: yMax,
    );
  }

  void _stopDynamicPlayback({bool notify = true}) {
    _dynamicPlaybackTimer?.cancel();
    _dynamicPlaybackTimer = null;
    _playbackStartNs = null;
    _playbackWindowNs = null;
    _playbackVisibleDurationNs = null;
    if (notify && !_disposed) {
      notifyListeners();
    }
  }

  Future<void> _advanceDynamicReadPreview() async {
    if (_dynamicReadInFlight || _dynamicPlaybackTimer == null) {
      return;
    }
    final fileRange = _sourceTimeRange;
    final playbackStartNs = _playbackStartNs;
    final playbackWindowNs = _playbackWindowNs;
    final playbackVisibleDurationNs = _playbackVisibleDurationNs;
    if (fileRange == null ||
        playbackStartNs == null ||
        playbackWindowNs == null ||
        playbackVisibleDurationNs == null) {
      _stopDynamicPlayback();
      return;
    }

    final chunkNs = math.max(
      1,
      (playbackWindowNs * (_dynamicChunkPercent / 100.0)).round(),
    );
    final lastStartNs = fileRange.endNs - playbackWindowNs;

    int nextStartNs = playbackStartNs;
    int nextVisibleDurationNs = playbackVisibleDurationNs;
    if (playbackVisibleDurationNs < playbackWindowNs) {
      nextVisibleDurationNs = math.min(
        playbackWindowNs,
        playbackVisibleDurationNs + chunkNs,
      );
    } else if (playbackStartNs < lastStartNs) {
      nextStartNs = math.min(lastStartNs, playbackStartNs + chunkNs);
      nextVisibleDurationNs = math.min(
        playbackWindowNs,
        fileRange.endNs - nextStartNs,
      );
    } else {
      _stopDynamicPlayback();
      return;
    }

    _playbackStartNs = nextStartNs;
    _playbackVisibleDurationNs = nextVisibleDurationNs;
    _readTimeRange = TimeRange(
      startNs: nextStartNs,
      endNs: nextStartNs + nextVisibleDurationNs,
    );
    _applyConfiguredWindowToDeck(clearSeries: false);
    await _refreshSeriesDeckForReadRange(_readTimeRange!);

    if (nextStartNs >= lastStartNs &&
        nextVisibleDurationNs >= playbackWindowNs) {
      _stopDynamicPlayback();
    }
  }

  DatadisplayBackendClient _backendForUri(String uri) {
    final native = nativeLoadResult.backend;
    if (native == null) {
      throw BackendException(
        'unavailable',
        'The native dd-ffi library is not available. ${nativeLoadResult.statusDetail}',
      );
    }

    return native;
  }

  Future<void> _refreshCatalog({required bool autoSelectFirst}) async {
    final source = _source;
    final backend = _activeBackend;
    if (source == null || backend == null) {
      return;
    }

    final generation = _catalogGeneration + 1;
    _catalogGeneration = generation;
    _catalogPages.clear();
    _catalogPagesInFlight.clear();
    _catalogTotalCount = 0;

    try {
      final page = await backend.catalog(
        sourceId: source.sourceId,
        text: _catalogSearch.isEmpty ? null : _catalogSearch,
        offset: 0,
        limit: _catalogPageSize,
      );
      if (_disposed || generation != _catalogGeneration) {
        return;
      }

      final previousId = _selectedStream?.channel.id;
      _catalogTotalCount = page.totalCount;
      _catalogPages[0] = page.streams;
      _selectedSeriesForDeck = _selectedSeriesForDeck
          .where((id) => page.streams.any((stream) => stream.channel.id == id))
          .toSet();
      _selectedStream = page.streams.cast<StreamDescriptor?>().firstWhere(
        (candidate) => candidate?.channel.id == previousId,
        orElse: () => _preferredStreamFrom(page.streams),
      );
      _selectedBlock = null;
      _seriesViewport = null;
      if (_selectedStream == null) {
        _readTimeRange = null;
      } else {
        _readTimeRange ??= _initialReadTimeRangeForStream(_selectedStream!);
      }
      _clearError();
      notifyListeners();
    } on BackendException catch (error) {
      if (_disposed || generation != _catalogGeneration) {
        return;
      }
      _setError(error.message);
    } catch (error) {
      if (_disposed || generation != _catalogGeneration) {
        return;
      }
      _setError('Catalog query failed: $error');
    }
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    _busy = true;
    notifyListeners();
    try {
      await action();
    } finally {
      _busy = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _setError(String message) {
    _errorMessage = message;
    _infoMessage = null;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _clearError() {
    _errorMessage = null;
  }

  TimeRange _previewRangeForStream(StreamDescriptor stream) {
    final metadata = stream.channel.metadata;
    final extra = stream.extra;
    final startNs =
        _parseInt(metadata['preview.start_ns']) ??
        _parseInt(metadata['hdf5.attr.start_ns']) ??
        _parseInt(extra['preview.start_ns']) ??
        0;
    final previewEndNs =
        _parseInt(metadata['preview.end_ns']) ??
        _parseInt(extra['preview.end_ns']) ??
        _parseInt(metadata['hdf5.attr.end_ns']);

    switch (stream.kind) {
      case StreamKind.series1d:
      case StreamKind.sampled:
        final samplePeriodNs =
            _parseInt(metadata['preview.sample_period_ns']) ??
            _parseInt(metadata['hdf5.attr.sample_period_ns']) ??
            _parseInt(extra['preview.sample_period_ns']) ??
            _samplePeriodFromRate(stream.channel.sampleRateHz);
        final len =
            _parseInt(extra['preview.len']) ?? _parseInt(extra['hdf5.len']);
        final sampleCount = len == null || len < 1 ? 1 : len;
        final fallbackStepNs = samplePeriodNs == null || samplePeriodNs < 1
            ? 1000000
            : samplePeriodNs;
        final endNs = previewEndNs != null && previewEndNs > startNs
            ? previewEndNs
            : startNs + fallbackStepNs * sampleCount;
        return TimeRange(startNs: startNs, endNs: endNs);
      case StreamKind.grid2d:
        final samplePeriodNs =
            _parseInt(metadata['preview.sample_period_ns']) ??
            _parseInt(metadata['hdf5.attr.sample_period_ns']) ??
            _parseInt(extra['preview.sample_period_ns']) ??
            _samplePeriodFromRate(stream.channel.sampleRateHz);
        final width =
            _parseInt(extra['preview.width']) ?? _parseInt(extra['hdf5.width']);
        final sampleWidth = width == null || width < 1 ? 1 : width;
        final fallbackStepNs = samplePeriodNs == null || samplePeriodNs < 1
            ? 1000000
            : samplePeriodNs;
        final endNs = previewEndNs != null && previewEndNs > startNs
            ? previewEndNs
            : startNs + fallbackStepNs * sampleWidth;
        return TimeRange(startNs: startNs, endNs: endNs);
      case StreamKind.volume3d:
        return TimeRange(startNs: startNs, endNs: startNs + 1);
      case StreamKind.eventSeries:
        final endNs = previewEndNs ?? startNs + 1;
        return TimeRange(startNs: startNs, endNs: endNs);
    }
  }

  SeriesBlock? _currentSeriesBlock() {
    final block = _selectedBlock;
    return _asScalarSeriesBlock(block);
  }

  Future<DataBlock> _readBlockForStream({
    required DatadisplayBackendClient backend,
    required int sourceId,
    required StreamDescriptor stream,
    TimeRange? timeRange,
  }) {
    return backend.read(
      sourceId: sourceId,
      channelId: stream.channel.id,
      timeRange: timeRange ?? _previewRangeForStream(stream),
      aggregation: stream.isScalarTimeseries
          ? _aggregation
          : ReadAggregation.raw,
      maxPoints: stream.isScalarTimeseries ? _maxPoints : null,
      allowGaps: !stream.isScalarTimeseries,
    );
  }

  Future<void> setDynamicChunkPercent(double percent) async {
    _dynamicChunkPercent = percent.clamp(1.0, 100.0);
    notifyListeners();
  }

  Future<void> applySelectedReadWindow({
    required double gpsStartSeconds,
    required double windowSeconds,
  }) async {
    if (_source == null) {
      return;
    }
    _stopDynamicPlayback(notify: false);
    _selectedBlock = null;
    _seriesViewport = null;
    final requestedStartNs = (gpsStartSeconds * 1.0e9).round();
    final requestedDurationNs = math.max(1, (windowSeconds * 1.0e9).round());
    _readTimeRange = _clampReadTimeRange(
      TimeRange(
        startNs: requestedStartNs,
        endNs: requestedStartNs + requestedDurationNs,
      ),
    );
    _applyConfiguredWindowToDeck(clearSeries: true);
    notifyListeners();
  }

  Future<void> resetSelectedReadWindow() async {
    if (_source == null) {
      return;
    }
    _stopDynamicPlayback(notify: false);
    _selectedBlock = null;
    _seriesViewport = null;
    final sourceRange = _sourceTimeRange;
    if (sourceRange != null) {
      const defaultWindowSec = 10.0;
      final durationNs = sourceRange.endNs - sourceRange.startNs;
      final windowNs = math.min(durationNs, (defaultWindowSec * 1.0e9).round());
      _readTimeRange = TimeRange(
        startNs: sourceRange.startNs,
        endNs: sourceRange.startNs + math.max(1, windowNs),
      );
    } else {
      final stream = _selectedStream;
      if (stream == null) {
        return;
      }
      _readTimeRange = _initialReadTimeRangeForStream(stream);
    }
    _applyConfiguredWindowToDeck(clearSeries: true);
    notifyListeners();
  }

  Future<void> startDynamicReadPreview() async {
    final fileRange = _sourceTimeRange;
    final configuredRange = _readTimeRange;
    if (fileRange == null || configuredRange == null || _seriesDeck.isEmpty) {
      return;
    }

    _stopDynamicPlayback(notify: false);
    final effectiveRange = _clampReadTimeRange(configuredRange);
    final effectiveWindowNs = math.max(
      1,
      effectiveRange.endNs - effectiveRange.startNs,
    );
    final chunkNs = math.max(
      1,
      (effectiveWindowNs * (_dynamicChunkPercent / 100.0)).round(),
    );

    _playbackStartNs = effectiveRange.startNs;
    _playbackWindowNs = effectiveWindowNs;
    _playbackVisibleDurationNs = math.min(chunkNs, effectiveWindowNs);
    _readTimeRange = TimeRange(
      startNs: effectiveRange.startNs,
      endNs: math.min(
        effectiveRange.startNs + _playbackVisibleDurationNs!,
        fileRange.endNs,
      ),
    );
    _applyConfiguredWindowToDeck(clearSeries: false);
    _dynamicPlaybackTimer = Timer.periodic(const Duration(milliseconds: 350), (
      _,
    ) {
      _advanceDynamicReadPreview();
    });
    notifyListeners();
    await _refreshSeriesDeckForReadRange(_readTimeRange!);
  }

  Future<void> stopDynamicReadPreview() async {
    final configuredRange = configuredReadWindowRange;
    _stopDynamicPlayback(notify: false);
    if (configuredRange != null) {
      _readTimeRange = configuredRange;
      _applyConfiguredWindowToDeck(clearSeries: false);
    }
    notifyListeners();
  }

  Future<void> _refreshSeriesDeckForReadRange(TimeRange readRange) async {
    final source = _source;
    final backend = _activeBackend;
    if (source == null ||
        backend == null ||
        _seriesDeck.isEmpty ||
        _dynamicReadInFlight) {
      return;
    }

    _dynamicReadInFlight = true;
    try {
      final currentWindowRange = configuredReadWindowRange;
      final nextDeck = [..._seriesDeck];
      for (var index = 0; index < nextDeck.length; index++) {
        final entry = nextDeck[index];
        final block = await _readBlockForStream(
          backend: backend,
          sourceId: source.sourceId,
          stream: entry.stream,
          timeRange: readRange,
        );
        final scalarSeries = _asScalarSeriesBlock(block);
        if (scalarSeries == null) {
          continue;
        }
        nextDeck[index] = _placeholderSeriesDeckEntry(
          entry.stream,
          windowRange: currentWindowRange ?? entry.windowRange,
          series: scalarSeries,
        );
        if (_selectedStream?.channel.id == entry.stream.channel.id) {
          _selectedBlock = block;
          _seriesViewport = _viewportForReadResult(scalarSeries);
        }
      }

      _seriesDeck = nextDeck;
      _syncSeriesDeckViewport();
      _clearError();
      notifyListeners();
    } on BackendException catch (error) {
      _setError(error.message);
    } catch (error) {
      _setError('Dynamic read failed: $error');
    } finally {
      _dynamicReadInFlight = false;
    }
  }
}

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({super.key});

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  final WorkspaceController _controller = WorkspaceController();
  final TextEditingController _sourceUriController = TextEditingController(
    text: _defaultSourceUri,
  );
  final TextEditingController _searchController = TextEditingController();

  WorkspaceSection _selectedSection = WorkspaceSection.plots;

  @override
  void initState() {
    super.initState();
    _controller.initialize();
  }

  @override
  void dispose() {
    _sourceUriController.dispose();
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 980;

            return Scaffold(
              body: SafeArea(
                child: Row(
                  children: [
                    if (wide)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: _Sidebar(
                          selectedSection: _selectedSection,
                          onSelected: _onSelected,
                        ),
                      ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 4 : 16,
                          wide ? 20 : 16,
                          20,
                          wide ? 20 : 96,
                        ),
                        child: _WorkspaceContent(
                          selectedSection: _selectedSection,
                          controller: _controller,
                          sourceUriController: _sourceUriController,
                          searchController: _searchController,
                          onOpenSource: _handleOpenSource,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      selectedIndex: WorkspaceSection.values.indexOf(
                        _selectedSection,
                      ),
                      destinations: WorkspaceSection.values
                          .map(
                            (section) => NavigationDestination(
                              icon: Icon(section.icon),
                              label: section.label,
                            ),
                          )
                          .toList(),
                      onDestinationSelected: (index) {
                        _onSelected(WorkspaceSection.values[index]);
                      },
                    ),
            );
          },
        );
      },
    );
  }

  void _onSelected(WorkspaceSection section) {
    setState(() {
      _selectedSection = section;
    });
  }

  Future<void> _handleOpenSource() async {
    await _controller.openSource(_sourceUriController.text);
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selectedSection, required this.onSelected});

  final WorkspaceSection selectedSection;
  final ValueChanged<WorkspaceSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 248,
      decoration: BoxDecoration(
        color: const Color(0xFF102720),
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 24,
            offset: Offset(0, 18),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'DATADISPLAY',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Universal timeseries workstation',
            style: TextStyle(
              color: Colors.white.withAlpha(184),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 28),
          ...WorkspaceSection.values.map(
            (section) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _SidebarButton(
                section: section,
                selected: section == selectedSection,
                onTap: () => onSelected(section),
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  const _SidebarButton({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final WorkspaceSection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selectedColor = Theme.of(context).colorScheme.secondary;

    return Material(
      color: selected ? selectedColor : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                section.icon,
                color: selected ? const Color(0xFF1B1B1B) : Colors.white70,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.label,
                  style: TextStyle(
                    color: selected ? const Color(0xFF1B1B1B) : Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceContent extends StatelessWidget {
  const _WorkspaceContent({
    required this.selectedSection,
    required this.controller,
    required this.sourceUriController,
    required this.searchController,
    required this.onOpenSource,
  });

  final WorkspaceSection selectedSection;
  final WorkspaceController controller;
  final TextEditingController sourceUriController;
  final TextEditingController searchController;
  final Future<void> Function() onOpenSource;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _TopBar(section: selectedSection, controller: controller),
        const SizedBox(height: 12),
        if (controller.errorMessage != null) ...[
          _MessageBanner(
            color: const Color(0xFFFBE5E2),
            borderColor: const Color(0xFFE9B2AC),
            textColor: const Color(0xFF6A241E),
            message: controller.errorMessage!,
          ),
          const SizedBox(height: 18),
        ],
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                switch (selectedSection) {
                  WorkspaceSection.session => _SessionSection(
                    controller: controller,
                  ),
                  WorkspaceSection.catalog => _CatalogSection(
                    controller: controller,
                    searchController: searchController,
                  ),
                  WorkspaceSection.plots => _PlotsSection(
                    controller: controller,
                  ),
                  WorkspaceSection.backends => _BackendsSection(
                    controller: controller,
                    sourceUriController: sourceUriController,
                    onOpenSource: onOpenSource,
                  ),
                },
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.section, required this.controller});

  final WorkspaceSection section;
  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sourceLabel = _sourceStatusLabel(controller.source);
    final chips = Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.start,
      children: [
        _StatusChip(
          label: controller.runtimeLabel,
          color: controller.nativeAvailable
              ? colorScheme.primary
              : const Color(0xFF8E6B12),
        ),
        _StatusChip(label: sourceLabel, color: colorScheme.secondary),
      ],
    );

    final headline = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          section.label,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          switch (section) {
            WorkspaceSection.session => 'Runtime status and source state.',
            WorkspaceSection.catalog =>
              'Browse channels and manage deck selection.',
            WorkspaceSection.plots => 'Dynamic multi-series deck.',
            WorkspaceSection.backends =>
              'Open local sources and inspect runtime status.',
          },
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xFF4E5D56)),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 900) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [headline, const SizedBox(height: 10), chips],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: headline),
            const SizedBox(width: 16),
            Flexible(
              child: Align(alignment: Alignment.topRight, child: chips),
            ),
          ],
        );
      },
    );
  }
}

String _sourceStatusLabel(OpenedSource? source) {
  if (source == null) {
    return 'No source';
  }
  final sourceName = source.sourceName.trim();
  if (sourceName.isNotEmpty && sourceName.length <= 36) {
    return sourceName;
  }
  final withoutQuery = source.uri.split('?').first.trim();
  final slashIndex = withoutQuery.lastIndexOf('/');
  if (slashIndex >= 0 && slashIndex + 1 < withoutQuery.length) {
    return withoutQuery.substring(slashIndex + 1);
  }
  if (sourceName.isNotEmpty) {
    return sourceName;
  }
  return 'Source open';
}

class _SessionSection extends StatelessWidget {
  const _SessionSection({required this.controller});

  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    final block = controller.selectedBlock;
    final metrics = [
      _MetricSpec(
        title: 'Engine mode',
        value: controller.nativeAvailable
            ? 'Native ready'
            : 'Native unavailable',
        caption: controller.runtimeDetail,
        icon: Icons.memory_rounded,
      ),
      _MetricSpec(
        title: 'Connected source',
        value: controller.source?.sourceName ?? 'Idle',
        caption:
            controller.source?.uri ??
            'No source is open yet. Start with $_defaultSourceUri.',
        icon: Icons.link_rounded,
      ),
      _MetricSpec(
        title: 'Catalog size',
        value: '${controller.catalogTotalCount} streams',
        caption:
            'The browser keeps a compact cached window in memory while the backend exposes the full catalog size.',
        icon: Icons.dataset_rounded,
      ),
      _MetricSpec(
        title: 'Last preview',
        value: block?.kind.label ?? 'No block',
        caption: block == null
            ? 'Select a stream to run the first preview read.'
            : 'The plots pane renders the last block returned by the active backend.',
        icon: Icons.auto_graph_rounded,
      ),
    ];

    return Column(
      children: [
        _SectionGrid(
          children: [
            for (final metric in metrics)
              _MetricCard(
                title: metric.title,
                value: metric.value,
                caption: metric.caption,
                icon: metric.icon,
              ),
          ],
        ),
        const SizedBox(height: 18),
        const _RoadmapPanel(),
      ],
    );
  }
}

class _PlotsSection extends StatelessWidget {
  const _PlotsSection({required this.controller});

  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PlotWindowPanel(controller: controller),
        const SizedBox(height: 18),
        _SeriesDeckPanel(controller: controller),
      ],
    );
  }
}

class _PlotWindowPanel extends StatefulWidget {
  const _PlotWindowPanel({required this.controller});

  final WorkspaceController controller;

  @override
  State<_PlotWindowPanel> createState() => _PlotWindowPanelState();
}

class _PlotWindowPanelState extends State<_PlotWindowPanel> {
  final TextEditingController _gpsStartController = TextEditingController();
  final TextEditingController _windowController = TextEditingController();
  final TextEditingController _chunkPercentController = TextEditingController();
  final FocusNode _gpsStartFocusNode = FocusNode();
  final FocusNode _windowFocusNode = FocusNode();
  final FocusNode _chunkPercentFocusNode = FocusNode();

  @override
  void dispose() {
    _gpsStartController.dispose();
    _windowController.dispose();
    _chunkPercentController.dispose();
    _gpsStartFocusNode.dispose();
    _windowFocusNode.dispose();
    _chunkPercentFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final sourceRange = controller.sourceTimeRange;
    final readRange = controller.configuredReadWindowRange;
    final latestAllowedStartNs = sourceRange == null || readRange == null
        ? null
        : sourceRange.endNs - (readRange.endNs - readRange.startNs);
    final deckCount = controller.seriesDeck.length;
    final hasDeck = deckCount > 0;
    _syncReadWindowFields(readRange);
    _syncChunkPercentField(controller.dynamicChunkPercent);

    return _Panel(
      title: 'Plot window',
      subtitle:
          'Configure the global GPS window for the plot deck, then start dynamic playback.',
      expandChild: false,
      child: sourceRange == null
          ? const Text(
              'Open a source to configure the plot window.',
              style: TextStyle(
                color: Color(0xFF5C6963),
                fontWeight: FontWeight.w600,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TagChip(label: 'File ${sourceRange.label}'),
                    if (readRange != null)
                      _TagChip(label: 'Window ${readRange.label}'),
                    _TagChip(label: controller.activeBackendLabel),
                    _TagChip(label: '$deckCount in deck'),
                  ],
                ),
                if (latestAllowedStartNs != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'GPS start can be chosen from ${_formatNsLabel(sourceRange.startNs)} to ${_formatNsLabel(latestAllowedStartNs)} for the current window.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF53605A),
                    ),
                  ),
                ],
                if (!hasDeck) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Add one or more 1D channels from Catalog to the deck, then start dynamic playback here.',
                    style: TextStyle(
                      color: Color(0xFF5C6963),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _gpsStartController,
                        focusNode: _gpsStartFocusNode,
                        enabled: !controller.isBusy,
                        decoration: _readInputDecoration('GPS start (s)'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onSubmitted: (_) => _applyReadWindow(),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _windowController,
                        focusNode: _windowFocusNode,
                        enabled: !controller.isBusy,
                        decoration: _readInputDecoration('Time window (s)'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onSubmitted: (_) => _applyReadWindow(),
                      ),
                    ),
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _chunkPercentController,
                        focusNode: _chunkPercentFocusNode,
                        enabled: !controller.isBusy,
                        decoration: _readInputDecoration('Chunk of window (%)'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onSubmitted: (_) => _applyChunkPercent(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: controller.isBusy || readRange == null
                          ? null
                          : controller.resetSelectedReadWindow,
                      icon: const Icon(Icons.replay_rounded),
                      label: const Text('Reset window'),
                    ),
                    FilledButton.icon(
                      onPressed: controller.isBusy || !hasDeck
                          ? null
                          : _handleDynamicAction,
                      icon: Icon(
                        controller.dynamicPlaybackActive
                            ? Icons.stop_rounded
                            : Icons.play_circle_fill_rounded,
                      ),
                      label: Text(
                        controller.dynamicPlaybackActive
                            ? 'Stop dynamic'
                            : 'Start dynamic',
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  void _syncReadWindowFields(TimeRange? range) {
    if (range == null) {
      return;
    }
    _syncReadField(
      controller: _gpsStartController,
      focusNode: _gpsStartFocusNode,
      text: _formatGpsSecondsInputFromNs(range.startNs.toDouble()),
    );
    _syncReadField(
      controller: _windowController,
      focusNode: _windowFocusNode,
      text: _formatDurationSecondsInput(range.endNs - range.startNs),
    );
  }

  void _syncChunkPercentField(double value) {
    _syncReadField(
      controller: _chunkPercentController,
      focusNode: _chunkPercentFocusNode,
      text: value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1),
    );
  }

  void _syncReadField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String text,
  }) {
    if (focusNode.hasFocus || controller.text == text) {
      return;
    }
    controller.text = text;
    controller.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<bool> _applyReadWindow() async {
    final gpsStart = double.tryParse(_gpsStartController.text.trim());
    final window = double.tryParse(_windowController.text.trim());
    if (gpsStart == null) {
      _showReadWindowError('GPS start must be a valid number in seconds.');
      return false;
    }
    if (window == null || !window.isFinite || window <= 0) {
      _showReadWindowError('Time window must be a positive number in seconds.');
      return false;
    }
    await widget.controller.applySelectedReadWindow(
      gpsStartSeconds: gpsStart,
      windowSeconds: window,
    );
    return true;
  }

  Future<bool> _applyChunkPercent() async {
    final value = double.tryParse(_chunkPercentController.text.trim());
    if (value == null || !value.isFinite || value <= 0 || value > 100) {
      _showReadWindowError(
        'Chunk percentage must be in the range 0 < p <= 100.',
      );
      return false;
    }
    await widget.controller.setDynamicChunkPercent(value);
    return true;
  }

  Future<void> _handleDynamicAction() async {
    final controller = widget.controller;
    if (controller.dynamicPlaybackActive) {
      await controller.stopDynamicReadPreview();
      return;
    }
    final chunkApplied = await _applyChunkPercent();
    if (!chunkApplied) {
      return;
    }
    final windowApplied = await _applyReadWindow();
    if (!windowApplied) {
      return;
    }
    await controller.startDynamicReadPreview();
  }

  void _showReadWindowError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  InputDecoration _readInputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: const Color(0xFFF2F5F1),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _BackendsSection extends StatelessWidget {
  const _BackendsSection({
    required this.controller,
    required this.sourceUriController,
    required this.onOpenSource,
  });

  final WorkspaceController controller;
  final TextEditingController sourceUriController;
  final Future<void> Function() onOpenSource;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SourceLauncherPanel(
          controller: controller,
          sourceUriController: sourceUriController,
          onOpenSource: onOpenSource,
        ),
        const SizedBox(height: 18),
        _NativeEnginePanel(controller: controller),
        const SizedBox(height: 18),
        _TomcatPanel(controller: controller),
      ],
    );
  }
}

class _SectionGrid extends StatelessWidget {
  const _SectionGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1080;
        final crossAxisCount = wide ? 2 : 1;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: children.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 18,
            mainAxisSpacing: 18,
            mainAxisExtent: wide ? 332 : 372,
          ),
          itemBuilder: (context, index) => children[index],
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.subtitle,
    required this.child,
    this.expandChild = true,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final bool expandChild;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFE0E6E1)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 22,
            offset: Offset(0, 14),
          ),
        ],
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF5E6A64),
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 16), trailing!],
            ],
          ),
          const SizedBox(height: 18),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

class _MetricSpec {
  const _MetricSpec({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String title;
  final String value;
  final String caption;
  final IconData icon;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String title;
  final String value;
  final String caption;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return _Panel(
      title: title,
      subtitle: 'Workspace state',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: colorScheme.primary.withAlpha(26),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: colorScheme.primary),
          ),
          const Spacer(),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            caption,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: const Color(0xFF43504A),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoadmapPanel extends StatelessWidget {
  const _RoadmapPanel();

  @override
  Widget build(BuildContext context) {
    const steps = [
      (
        '1',
        'Flutter binds to dd-ffi',
        'Source open, catalog browse, and preview reads now cross the real ABI boundary.',
      ),
      (
        '2',
        'Plot scene bridge',
        'Expose the Rust render crate and replace the ad-hoc preview canvases with formal plot scenes.',
      ),
      (
        '3',
        'Session model',
        'Persist layouts, ranges, selected sources, and open plots in one workspace file.',
      ),
      (
        '4',
        'GWF adapter',
        'Add the first domain-specific backend without changing the shell contract.',
      ),
    ];

    return _Panel(
      title: 'Execution roadmap',
      subtitle:
          'The shell now talks to a backend. The next phases are about turning preview reads into a full workstation.',
      expandChild: false,
      child: Column(
        children: List.generate(steps.length, (index) {
          final step = steps[index];

          return Padding(
            padding: EdgeInsets.only(
              bottom: index == steps.length - 1 ? 0 : 18,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A7B6C),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    step.$1,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        step.$2,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        step.$3,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF53605A),
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _SourceLauncherPanel extends StatelessWidget {
  const _SourceLauncherPanel({
    required this.controller,
    required this.sourceUriController,
    required this.onOpenSource,
  });

  final WorkspaceController controller;
  final TextEditingController sourceUriController;
  final Future<void> Function() onOpenSource;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Source launcher',
      subtitle:
          'Open the active local source here. This launcher is intentionally kept in one place.',
      expandChild: false,
      trailing: controller.source == null
          ? null
          : _TagChip(label: controller.activeBackendLabel),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: sourceUriController,
            decoration: InputDecoration(
              labelText: 'Source URI',
              hintText: 'gwf:///data/run01.gwf?series=raw',
              filled: true,
              fillColor: const Color(0xFFF2F5F1),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => onOpenSource(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: controller.isBusy ? null : onOpenSource,
                icon: const Icon(Icons.link_rounded),
                label: const Text('Open source'),
              ),
            ],
          ),
          if (controller.source != null) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TagChip(label: controller.source!.sourceName),
                for (final capability
                    in controller.source!.capabilities.enabledLabels())
                  _TagChip(label: capability),
              ],
            ),
          ],
          if (controller.isBusy) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

class _CatalogSection extends StatelessWidget {
  const _CatalogSection({
    required this.controller,
    required this.searchController,
  });

  final WorkspaceController controller;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1180;
        final queryWidth = math.min(
          320.0,
          math.max(280.0, constraints.maxWidth * 0.28),
        );
        const browserHeight = 760.0;

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: queryWidth,
                child: _CatalogControlPanel(
                  controller: controller,
                  searchController: searchController,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: SizedBox(
                  height: browserHeight,
                  child: _CatalogBrowserPanel(controller: controller),
                ),
              ),
            ],
          );
        }

        return Column(
          children: [
            _CatalogControlPanel(
              controller: controller,
              searchController: searchController,
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: browserHeight,
              child: _CatalogBrowserPanel(controller: controller),
            ),
          ],
        );
      },
    );
  }
}

class _CatalogControlPanel extends StatelessWidget {
  const _CatalogControlPanel({
    required this.controller,
    required this.searchController,
  });

  final WorkspaceController controller;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    if (searchController.text != controller.catalogSearch) {
      searchController.text = controller.catalogSearch;
      searchController.selection = TextSelection.collapsed(
        offset: searchController.text.length,
      );
    }

    return _Panel(
      title: 'Catalog query',
      subtitle:
          'Filter the active source. The browser fetches compact cached windows of 64 channels while you scroll.',
      expandChild: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (controller.source != null)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TagChip(label: controller.activeBackendLabel),
                for (final capability
                    in controller.source!.capabilities.enabledLabels())
                  _TagChip(label: capability),
              ],
            ),
          const SizedBox(height: 14),
          TextField(
            controller: searchController,
            decoration: InputDecoration(
              labelText: 'Catalog filter',
              hintText: 'Search channels, tags, or units',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: const Color(0xFFF2F5F1),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: controller.source == null
                ? null
                : controller.applyCatalogSearch,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: controller.isBusy || controller.source == null
                    ? null
                    : () =>
                          controller.applyCatalogSearch(searchController.text),
                icon: const Icon(Icons.filter_alt_rounded),
                label: const Text('Apply filter'),
              ),
              if (controller.catalogSearch.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: controller.isBusy || controller.source == null
                      ? null
                      : () {
                          searchController.clear();
                          controller.applyCatalogSearch('');
                        },
                  icon: const Icon(Icons.clear_rounded),
                  label: const Text('Clear filter'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'The browser keeps fetched rows in memory, so scrolling back does not re-query the file for channels already seen.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF5E6A64),
              height: 1.45,
            ),
          ),
          if (controller.isBusy) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

class _CatalogBrowserPanel extends StatelessWidget {
  const _CatalogBrowserPanel({required this.controller});

  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    final totalCount = controller.catalogTotalCount;
    final loadedCount = controller.loadedCatalogCount;
    final selectedCount = controller.selectedSeriesForDeck.length;

    return _Panel(
      title: 'Catalog browser',
      subtitle:
          'Scroll through the full catalog in a compact viewport. The shell caches fetched channel windows and reuses them when you move back.',
      child: controller.source == null
          ? const Center(
              child: Text(
                'Open a source to browse its channels.',
                style: TextStyle(
                  color: Color(0xFF5C6963),
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CatalogInfoChip(
                      label: 'Cached $loadedCount / $totalCount',
                    ),
                    _CatalogInfoChip(label: '$selectedCount selected for deck'),
                    OutlinedButton.icon(
                      onPressed: controller.isBusy || loadedCount == 0
                          ? null
                          : controller.selectCachedSeriesForDeck,
                      icon: const Icon(Icons.done_all_rounded),
                      label: const Text('Select cached'),
                    ),
                    OutlinedButton.icon(
                      onPressed: controller.isBusy || selectedCount == 0
                          ? null
                          : controller.clearSeriesDeckSelection,
                      icon: const Icon(Icons.deselect_rounded),
                      label: const Text('Clear selection'),
                    ),
                    FilledButton.icon(
                      onPressed: controller.isBusy || selectedCount == 0
                          ? null
                          : controller.addSelectedCatalogSeriesToDeck,
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('Add selected to deck'),
                    ),
                  ],
                ),
                if (controller.isBusy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                const SizedBox(height: 12),
                Expanded(child: _CatalogVirtualList(controller: controller)),
              ],
            ),
    );
  }
}

class _CatalogVirtualList extends StatefulWidget {
  const _CatalogVirtualList({required this.controller});

  final WorkspaceController controller;

  @override
  State<_CatalogVirtualList> createState() => _CatalogVirtualListState();
}

class _CatalogVirtualListState extends State<_CatalogVirtualList> {
  static const double _rowExtent = 58;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_ensureVisibleRange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisibleRange());
  }

  @override
  void didUpdateWidget(covariant _CatalogVirtualList oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisibleRange());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_ensureVisibleRange);
    _scrollController.dispose();
    super.dispose();
  }

  void _ensureVisibleRange() {
    final totalCount = widget.controller.catalogTotalCount;
    if (totalCount == 0) {
      return;
    }

    if (!_scrollController.hasClients) {
      widget.controller.ensureCatalogRange(
        0,
        math.min(totalCount - 1, widget.controller.catalogPageSize - 1),
      );
      return;
    }

    final position = _scrollController.position;
    final firstIndex = math.max(0, (position.pixels / _rowExtent).floor());
    final lastIndex = math.min(
      totalCount - 1,
      ((position.pixels + position.viewportDimension) / _rowExtent).ceil() + 24,
    );
    widget.controller.ensureCatalogRange(firstIndex, lastIndex);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.catalogTotalCount == 0) {
      return Center(
        child: Text(
          controller.catalogSearch.isEmpty
              ? 'No channels available yet.'
              : 'No channels match the current filter.',
          style: const TextStyle(
            color: Color(0xFF5C6963),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _scrollController,
        itemCount: controller.catalogTotalCount,
        itemExtent: _rowExtent,
        itemBuilder: (context, index) {
          final stream = controller.catalogStreamAt(index);
          if (stream == null) {
            controller.ensureCatalogRange(
              index,
              index + controller.catalogPageSize,
            );
            return const _CatalogPlaceholderTile();
          }
          return _CatalogStreamTile(
            stream: stream,
            controller: controller,
            index: index,
          );
        },
      ),
    );
  }
}

class _CatalogPlaceholderTile extends StatelessWidget {
  const _CatalogPlaceholderTile();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F8F5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Loading catalog rows...',
              style: TextStyle(
                color: Color(0xFF72817A),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogStreamTile extends StatelessWidget {
  const _CatalogStreamTile({
    required this.stream,
    required this.controller,
    required this.index,
  });

  final StreamDescriptor stream;
  final WorkspaceController controller;
  final int index;

  void _applyDeckSelection() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final rangeSelect =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    controller.applyCatalogSeriesDeckSelection(
      channelId: stream.channel.id,
      index: index,
      additive: !rangeSelect,
      rangeSelect: rangeSelect,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = stream.channel.id == controller.selectedStream?.channel.id;
    final selectedForDeck = controller.selectedSeriesForDeck.contains(
      stream.channel.id,
    );
    final inDeck = controller.seriesDeck.any(
      (entry) => entry.stream.channel.id == stream.channel.id,
    );
    final metaParts = <String>[];
    if (stream.channel.subtitleParts.isNotEmpty) {
      metaParts.add(stream.channel.subtitleParts);
    }
    if (stream.sampleShape.isNotEmpty) {
      metaParts.add(stream.sampleShape.join('x'));
    }
    if (inDeck) {
      metaParts.add('deck');
    }
    final metaLabel = metaParts.join(' • ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? const Color(0xFFE6F4F0)
            : (index.isEven
                  ? const Color(0xFFF8FAF8)
                  : const Color(0xFFF4F7F4)),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: controller.isBusy
              ? null
              : () => controller.selectStream(stream),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                SizedBox(
                  width: 32,
                  child: stream.isScalarTimeseries
                      ? Checkbox(
                          value: selectedForDeck,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: controller.isBusy
                              ? null
                              : (_) => _applyDeckSelection(),
                        )
                      : const SizedBox.shrink(),
                ),
                Container(
                  width: 4,
                  height: 30,
                  decoration: BoxDecoration(
                    color: _kindColor(stream.kind),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: controller.isBusy
                        ? null
                        : () {
                            controller.selectStream(stream);
                            if (stream.isScalarTimeseries) {
                              _applyDeckSelection();
                            }
                          },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: stream.channel.displayName,
                          child: Text(
                            stream.channel.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Tooltip(
                          message: stream.channel.id,
                          child: Text(
                            stream.channel.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFF5F6D67),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        stream.kind.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: _kindColor(stream.kind),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (metaLabel.isNotEmpty)
                        Text(
                          metaLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF5F6D67),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SeriesDeckPanel extends StatefulWidget {
  const _SeriesDeckPanel({
    required this.controller,
    this.showDetachButton = true,
  });

  final WorkspaceController controller;
  final bool showDetachButton;

  @override
  State<_SeriesDeckPanel> createState() => _SeriesDeckPanelState();
}

class _SeriesDeckPanelState extends State<_SeriesDeckPanel> {
  final GlobalKey _chartBoundaryKey = GlobalKey();

  Future<ui.Image?> _captureChartImage(ScaffoldMessengerState messenger) async {
    final boundary = _chartBoundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Plot is not ready to capture yet.')),
      );
      return null;
    }
    return boundary.toImage(pixelRatio: 2.0);
  }

  String _exportFileStamp() {
    return DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
  }

  Future<void> _exportPng() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final image = await _captureChartImage(messenger);
      if (image == null) return;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Failed to encode PNG.')),
        );
        return;
      }
      final dir = widget.controller._resolveExportDirectory();
      final file = io.File('${dir.path}/datadisplay-${_exportFileStamp()}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      messenger.showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('PNG export failed: $error')));
    }
  }

  Future<void> _exportJpeg() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final image = await _captureChartImage(messenger);
      if (image == null) return;
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Failed to read raw pixels.')),
        );
        return;
      }
      final encoded = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: rgba.buffer,
        order: img.ChannelOrder.rgba,
      );
      final jpegBytes = img.encodeJpg(encoded, quality: 92);
      final dir = widget.controller._resolveExportDirectory();
      final file = io.File('${dir.path}/datadisplay-${_exportFileStamp()}.jpg');
      await file.writeAsBytes(jpegBytes);
      messenger.showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('JPEG export failed: $error')),
      );
    }
  }

  Future<void> _exportPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final image = await _captureChartImage(messenger);
      if (image == null) return;
      final pngData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (pngData == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Failed to encode chart for PDF.')),
        );
        return;
      }
      final pdfImage = pw.MemoryImage(pngData.buffer.asUint8List());
      final document = pw.Document();
      document.addPage(
        pw.Page(
          pageFormat: pdf_core.PdfPageFormat.a4.landscape,
          build: (context) {
            return pw.Center(
              child: pw.FittedBox(
                fit: pw.BoxFit.contain,
                child: pw.Image(pdfImage),
              ),
            );
          },
        ),
      );
      final bytes = await document.save();
      final dir = widget.controller._resolveExportDirectory();
      final file = io.File('${dir.path}/datadisplay-${_exportFileStamp()}.pdf');
      await file.writeAsBytes(bytes);
      messenger.showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('PDF export failed: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final deck = controller.seriesDeck;
    final mixedUnits = _seriesDeckHasMixedUnits(deck);
    final viewport =
        controller.seriesDeckViewport ??
        (deck.isEmpty
            ? null
            : _autoSeriesDeckViewport(deck, logY: controller.seriesDeckLogY));

    return _Panel(
      title: 'Series deck',
      subtitle:
          'Keep multiple 1D channels open from the same source and render them overlaid or stacked.',
      expandChild: false,
      trailing: _TagChip(label: '${deck.length} series'),
      child: deck.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No 1D series are in the deck yet. Select a channel and use `Add to deck`.',
                style: TextStyle(
                  color: Color(0xFF5C6963),
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<SeriesDeckLayout>(
                      segments: [
                        for (final layout in SeriesDeckLayout.values)
                          ButtonSegment<SeriesDeckLayout>(
                            value: layout,
                            label: Text(layout.label),
                            icon: Icon(
                              layout == SeriesDeckLayout.overlay
                                  ? Icons.layers_rounded
                                  : Icons.view_day_rounded,
                            ),
                          ),
                      ],
                      selected: {controller.seriesDeckLayout},
                      onSelectionChanged: (selection) {
                        if (selection.isNotEmpty) {
                          controller.setSeriesDeckLayout(selection.first);
                        }
                      },
                    ),
                    FilledButton.tonalIcon(
                      onPressed: controller.clearSeriesDeck,
                      icon: const Icon(Icons.delete_sweep_rounded),
                      label: const Text('Clear deck'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final path = await controller.exportDeckAsAscii();
                        if (path != null) {
                          messenger.showSnackBar(
                            SnackBar(content: Text('Exported to $path')),
                          );
                        }
                      },
                      icon: const Icon(Icons.file_download_rounded),
                      label: const Text('Export ASCII'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _exportPng,
                      icon: const Icon(Icons.image_rounded),
                      label: const Text('Export PNG'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _exportJpeg,
                      icon: const Icon(Icons.photo_camera_back_rounded),
                      label: const Text('Export JPEG'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _exportPdf,
                      icon: const Icon(Icons.picture_as_pdf_rounded),
                      label: const Text('Export PDF'),
                    ),
                    if (widget.showDetachButton)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => _DetachedDeckPage(
                              controller: controller,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Detach plot'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (viewport != null)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (controller.seriesDeckLayout ==
                          SeriesDeckLayout.overlay)
                        _TagChip(
                          label:
                              'X ${_formatNsLabel(viewport.xMinNs.round())} to ${_formatNsLabel(viewport.xMaxNs.round())}',
                        ),
                      if (controller.seriesDeckLayout ==
                          SeriesDeckLayout.overlay)
                        _TagChip(
                          label:
                              'Y ${_formatPlotNumber(viewport.yMin)} to ${_formatPlotNumber(viewport.yMax)}',
                        ),
                      if (controller.seriesDeckLayout ==
                          SeriesDeckLayout.stacked)
                        const _TagChip(label: 'Independent X/Y per plot'),
                    ],
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilterChip(
                      label: const Text('Auto X'),
                      selected: controller.seriesDeckAutoXEnabled,
                      onSelected: controller.setSeriesDeckAutoX,
                    ),
                    FilterChip(
                      label: const Text('Auto Y'),
                      selected: controller.seriesDeckAutoYEnabled,
                      onSelected: controller.setSeriesDeckAutoY,
                    ),
                    FilterChip(
                      label: const Text('Log Y'),
                      selected: controller.seriesDeckLogY,
                      onSelected: controller.setSeriesDeckLogY,
                    ),
                    OutlinedButton.icon(
                      onPressed: () => controller.panSeriesDeckX(-0.2),
                      icon: const Icon(Icons.chevron_left_rounded),
                      label: const Text('Pan left'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => controller.panSeriesDeckX(0.2),
                      icon: const Icon(Icons.chevron_right_rounded),
                      label: const Text('Pan right'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: controller.autoScaleSeriesDeck,
                      icon: const Icon(Icons.fit_screen_rounded),
                      label: const Text('Auto scale'),
                    ),
                  ],
                ),
                if (mixedUnits) ...[
                  const SizedBox(height: 12),
                  const _FeatureBullet(
                    title: 'Mixed units',
                    text:
                        'The current deck mixes channels with different units. Stacked mode is usually clearer than overlay in that case.',
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var index = 0; index < deck.length; index++)
                      _SeriesDeckChip(
                        label: deck[index].stream.channel.displayName,
                        subtitle: deck[index].stream.channel.unit,
                        color: _seriesDeckColor(index),
                        onRemove: () => controller.removeSeriesFromDeck(
                          deck[index].stream.channel.id,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                RepaintBoundary(
                  key: _chartBoundaryKey,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F7F4),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child:
                          controller.seriesDeckLayout ==
                              SeriesDeckLayout.overlay
                          ? SizedBox(
                              height: 420,
                              child: _BrushZoomableSeriesDeckChart(
                                viewport: viewport!,
                                allowYZoom: true,
                                logY: controller.seriesDeckLogY,
                                onZoomSelection: (selection) {
                                  controller.applySeriesDeckManualBounds(
                                    xMinNs: selection.xMinNs,
                                    xMaxNs: selection.xMaxNs,
                                    yMin: selection.yMin,
                                    yMax: selection.yMax,
                                  );
                                },
                                child: _SeriesDeckOverlayChart(
                                  deck: deck,
                                  viewport: viewport,
                                  logY: controller.seriesDeckLogY,
                                ),
                              ),
                            )
                          : _SeriesDeckStackedCharts(
                              controller: controller,
                              deck: deck,
                            ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _DetachedDeckPage extends StatelessWidget {
  const _DetachedDeckPage({required this.controller});

  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5F2),
      appBar: AppBar(
        title: const Text('Detached plot deck'),
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: SingleChildScrollView(
                child: _SeriesDeckPanel(
                  controller: controller,
                  showDetachButton: false,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SeriesDeckChip extends StatelessWidget {
  const _SeriesDeckChip({
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onRemove,
  });

  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD9E4DE)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: Color(0xFF60706A),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Remove from deck',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _BrushZoomableSeriesDeckChart extends StatefulWidget {
  const _BrushZoomableSeriesDeckChart({
    required this.viewport,
    required this.allowYZoom,
    required this.onZoomSelection,
    required this.child,
    this.logY = false,
  });

  final SeriesDeckViewport viewport;
  final bool allowYZoom;
  final ValueChanged<SeriesDeckViewport> onZoomSelection;
  final Widget child;
  final bool logY;

  @override
  State<_BrushZoomableSeriesDeckChart> createState() =>
      _BrushZoomableSeriesDeckChartState();
}

class _BrushZoomableSeriesDeckChartState
    extends State<_BrushZoomableSeriesDeckChart> {
  Offset? _dragStart;
  Offset? _dragCurrent;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? math.max(1.0, constraints.maxWidth)
            : 1.0;
        final height = constraints.maxHeight.isFinite
            ? math.max(1.0, constraints.maxHeight)
            : 1.0;
        final plotRect = _seriesChartPlotRect(Size(width, height));
        final selectionRect = _selectionRect(plotRect);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            if (!plotRect.contains(details.localPosition)) {
              return;
            }
            setState(() {
              _dragStart = _clampPointToRect(details.localPosition, plotRect);
              _dragCurrent = _dragStart;
            });
          },
          onPanUpdate: (details) {
            if (_dragStart == null) {
              return;
            }
            setState(() {
              _dragCurrent = _clampPointToRect(details.localPosition, plotRect);
            });
          },
          onPanCancel: _clearSelection,
          onPanEnd: (_) => _commitSelection(plotRect),
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (selectionRect != null)
                IgnorePointer(
                  child: CustomPaint(
                    painter: _SeriesDeckZoomSelectionPainter(
                      selectionRect: selectionRect,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Rect? _selectionRect(Rect plotRect) {
    final start = _dragStart;
    final current = _dragCurrent;
    if (start == null || current == null) {
      return null;
    }
    if (widget.allowYZoom) {
      return Rect.fromPoints(start, current);
    }
    return Rect.fromLTRB(
      math.min(start.dx, current.dx),
      plotRect.top,
      math.max(start.dx, current.dx),
      plotRect.bottom,
    );
  }

  Offset _clampPointToRect(Offset point, Rect rect) {
    return Offset(
      point.dx.clamp(rect.left, rect.right),
      point.dy.clamp(rect.top, rect.bottom),
    );
  }

  void _clearSelection() {
    if (_dragStart == null && _dragCurrent == null) {
      return;
    }
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
    });
  }

  void _commitSelection(Rect plotRect) {
    final selectionRect = _selectionRect(plotRect);
    _clearSelection();
    if (selectionRect == null || selectionRect.width < 10) {
      return;
    }
    if (widget.allowYZoom && selectionRect.height < 10) {
      return;
    }

    final xSpan = widget.viewport.xMaxNs - widget.viewport.xMinNs;
    if (xSpan <= 0 || plotRect.width <= 0) {
      return;
    }

    final xMinRatio = ((selectionRect.left - plotRect.left) / plotRect.width)
        .clamp(0.0, 1.0);
    final xMaxRatio = ((selectionRect.right - plotRect.left) / plotRect.width)
        .clamp(0.0, 1.0);
    final nextXMin = widget.viewport.xMinNs + xSpan * xMinRatio;
    final nextXMax = widget.viewport.xMinNs + xSpan * xMaxRatio;

    double? nextYMin;
    double? nextYMax;
    if (widget.allowYZoom) {
      if (plotRect.height <= 0) {
        return;
      }
      final topRatio = ((plotRect.bottom - selectionRect.top) / plotRect.height)
          .clamp(0.0, 1.0);
      final bottomRatio =
          ((plotRect.bottom - selectionRect.bottom) / plotRect.height).clamp(
            0.0,
            1.0,
          );
      if (widget.logY) {
        final safeMin =
            widget.viewport.yMin > 0 ? widget.viewport.yMin : 1e-12;
        final safeMax = widget.viewport.yMax > safeMin
            ? widget.viewport.yMax
            : safeMin * 10.0;
        final logMin = math.log(safeMin) / math.ln10;
        final logMax = math.log(safeMax) / math.ln10;
        final logSpan = logMax - logMin;
        if (logSpan <= 0) {
          return;
        }
        nextYMin = math.pow(10.0, logMin + logSpan * bottomRatio).toDouble();
        nextYMax = math.pow(10.0, logMin + logSpan * topRatio).toDouble();
      } else {
        final ySpan = widget.viewport.yMax - widget.viewport.yMin;
        if (ySpan <= 0) {
          return;
        }
        nextYMin = widget.viewport.yMin + ySpan * bottomRatio;
        nextYMax = widget.viewport.yMin + ySpan * topRatio;
      }
    }

    widget.onZoomSelection(
      widget.viewport.copyWith(
        autoX: false,
        autoY: widget.allowYZoom ? false : widget.viewport.autoY,
        xMinNs: nextXMin,
        xMaxNs: nextXMax,
        yMin: nextYMin ?? widget.viewport.yMin,
        yMax: nextYMax ?? widget.viewport.yMax,
      ),
    );
  }
}

class _SeriesDeckZoomSelectionPainter extends CustomPainter {
  _SeriesDeckZoomSelectionPainter({required this.selectionRect});

  final Rect selectionRect;

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..color = const Color(0x33157E6E)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFF157E6E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRRect(
      RRect.fromRectAndRadius(selectionRect, const Radius.circular(8)),
      fillPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(selectionRect, const Radius.circular(8)),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SeriesDeckZoomSelectionPainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect;
  }
}

class _SeriesDeckOverlayChart extends StatelessWidget {
  const _SeriesDeckOverlayChart({
    required this.deck,
    required this.viewport,
    required this.logY,
  });

  final List<SeriesDeckEntry> deck;
  final SeriesDeckViewport viewport;
  final bool logY;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SeriesDeckOverlayPainter(
        deck: deck,
        viewport: viewport,
        logY: logY,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SeriesDeckStackedCharts extends StatelessWidget {
  const _SeriesDeckStackedCharts({
    required this.controller,
    required this.deck,
  });

  final WorkspaceController controller;
  final List<SeriesDeckEntry> deck;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < deck.length; index++) ...[
          if (controller.stackedSeriesDeckViewportFor(
                deck[index].stream.channel.id,
              )
              case final viewport?)
            SizedBox(
              height: 220,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _TagChip(label: deck[index].stream.channel.displayName),
                      if (deck[index].stream.channel.unit != null &&
                          deck[index].stream.channel.unit!.isNotEmpty)
                        _TagChip(label: deck[index].stream.channel.unit!),
                      _TagChip(
                        label:
                            'X ${_formatNsLabel(viewport.xMinNs.round())} to ${_formatNsLabel(viewport.xMaxNs.round())}',
                      ),
                      _TagChip(
                        label:
                            'Y ${_formatPlotNumber(viewport.yMin)} to ${_formatPlotNumber(viewport.yMax)}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('Auto X'),
                        selected: viewport.autoX,
                        onSelected: (enabled) =>
                            controller.setStackedSeriesAutoX(
                              deck[index].stream.channel.id,
                              enabled,
                            ),
                      ),
                      FilterChip(
                        label: const Text('Auto Y'),
                        selected: viewport.autoY,
                        onSelected: (enabled) =>
                            controller.setStackedSeriesAutoY(
                              deck[index].stream.channel.id,
                              enabled,
                            ),
                      ),
                      OutlinedButton(
                        onPressed: () => controller.autoScaleStackedSeries(
                          deck[index].stream.channel.id,
                        ),
                        child: const Text('Auto plot'),
                      ),
                      OutlinedButton(
                        onPressed: () => controller.copyStackedSeriesXToAll(
                          deck[index].stream.channel.id,
                        ),
                        child: const Text('Zoom all X like this'),
                      ),
                      OutlinedButton(
                        onPressed: () => controller.copyStackedSeriesYToAll(
                          deck[index].stream.channel.id,
                        ),
                        child: const Text('Zoom all Y like this'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _BrushZoomableSeriesDeckChart(
                      viewport: viewport,
                      allowYZoom: true,
                      logY: controller.seriesDeckLogY,
                      onZoomSelection: (selection) {
                        controller.applyStackedSeriesViewport(
                          deck[index].stream.channel.id,
                          selection,
                        );
                      },
                      child: CustomPaint(
                        painter: _StackedSeriesDeckPainter(
                          series: deck[index].series,
                          color: _seriesDeckColor(index),
                          xMinNs: viewport.xMinNs,
                          xMaxNs: viewport.xMaxNs,
                          yMin: viewport.yMin,
                          yMax: viewport.yMax,
                          logY: controller.seriesDeckLogY,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (index != deck.length - 1) const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _NativeEnginePanel extends StatelessWidget {
  const _NativeEnginePanel({required this.controller});

  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Native engine',
      subtitle:
          'The Flutter app loads the Rust cdylib at runtime for local source access.',
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusChip(
              label: controller.runtimeLabel,
              color: controller.nativeAvailable
                  ? const Color(0xFF0A7B6C)
                  : const Color(0xFF8E6B12),
            ),
            const SizedBox(height: 14),
            Text(
              controller.runtimeDetail,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: const Color(0xFF46534D),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Search paths',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            for (final path in controller.searchedPaths.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF6F8F5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    path,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF596660),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SeriesPreview extends StatefulWidget {
  const _SeriesPreview({required this.series, required this.controller});

  final SeriesBlock series;
  final WorkspaceController controller;

  @override
  State<_SeriesPreview> createState() => _SeriesPreviewState();
}

class _SeriesPreviewState extends State<_SeriesPreview> {
  final TextEditingController _xMinController = TextEditingController();
  final TextEditingController _xMaxController = TextEditingController();
  final TextEditingController _yMinController = TextEditingController();
  final TextEditingController _yMaxController = TextEditingController();
  final FocusNode _xMinFocusNode = FocusNode();
  final FocusNode _xMaxFocusNode = FocusNode();
  final FocusNode _yMinFocusNode = FocusNode();
  final FocusNode _yMaxFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _syncAxisFields(force: true);
  }

  @override
  void didUpdateWidget(covariant _SeriesPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series != widget.series) {
      _syncAxisFields(force: true);
    }
  }

  @override
  void dispose() {
    _xMinController.dispose();
    _xMaxController.dispose();
    _yMinController.dispose();
    _yMaxController.dispose();
    _xMinFocusNode.dispose();
    _xMaxFocusNode.dispose();
    _yMinFocusNode.dispose();
    _yMaxFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncAxisFields();

    final viewport =
        widget.controller.seriesViewport ??
        _autoSeriesViewportFor(widget.series);
    final visibleSamples = _visibleSeriesSampleCount(widget.series, viewport);
    final unitLabel =
        widget.series.channel.unit == null ||
            widget.series.channel.unit!.isEmpty
        ? 'value'
        : widget.series.channel.unit!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _TagChip(label: '$visibleSamples visible samples'),
            _TagChip(
              label:
                  'X ${_formatNsLabel(viewport.xMinNs.round())} to ${_formatNsLabel(viewport.xMaxNs.round())}',
            ),
            _TagChip(
              label:
                  'Y ${_formatPlotNumber(viewport.yMin)} to ${_formatPlotNumber(viewport.yMax)}',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilterChip(
              label: const Text('Auto X'),
              selected: viewport.autoX,
              onSelected: widget.controller.isBusy
                  ? null
                  : widget.controller.setSeriesAutoX,
            ),
            FilterChip(
              label: const Text('Auto Y'),
              selected: viewport.autoY,
              onSelected: widget.controller.isBusy
                  ? null
                  : widget.controller.setSeriesAutoY,
            ),
            OutlinedButton.icon(
              onPressed: widget.controller.isBusy
                  ? null
                  : () => widget.controller.panSeriesX(-0.2),
              icon: const Icon(Icons.chevron_left_rounded),
              label: const Text('Pan left'),
            ),
            OutlinedButton.icon(
              onPressed: widget.controller.isBusy
                  ? null
                  : () => widget.controller.panSeriesX(0.2),
              icon: const Icon(Icons.chevron_right_rounded),
              label: const Text('Pan right'),
            ),
            OutlinedButton.icon(
              onPressed: widget.controller.isBusy
                  ? null
                  : () => widget.controller.zoomSeriesX(0.5),
              icon: const Icon(Icons.zoom_in_rounded),
              label: const Text('Zoom X in'),
            ),
            OutlinedButton.icon(
              onPressed: widget.controller.isBusy
                  ? null
                  : () => widget.controller.zoomSeriesX(2.0),
              icon: const Icon(Icons.zoom_out_rounded),
              label: const Text('Zoom X out'),
            ),
            OutlinedButton.icon(
              onPressed: widget.controller.isBusy
                  ? null
                  : () => widget.controller.zoomSeriesY(0.6),
              icon: const Icon(Icons.compress_rounded),
              label: const Text('Zoom Y in'),
            ),
            OutlinedButton.icon(
              onPressed: widget.controller.isBusy
                  ? null
                  : () => widget.controller.zoomSeriesY(1.8),
              icon: const Icon(Icons.expand_rounded),
              label: const Text('Zoom Y out'),
            ),
            FilledButton.tonalIcon(
              onPressed: widget.controller.isBusy
                  ? null
                  : widget.controller.autoScaleSeriesViewport,
              icon: const Icon(Icons.fit_screen_rounded),
              label: const Text('Auto scale'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 200,
              child: TextField(
                controller: _xMinController,
                focusNode: _xMinFocusNode,
                enabled: !viewport.autoX && !widget.controller.isBusy,
                decoration: _axisInputDecoration('X min (GPS s)'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onSubmitted: (_) => _applyAxisInputs(),
              ),
            ),
            SizedBox(
              width: 200,
              child: TextField(
                controller: _xMaxController,
                focusNode: _xMaxFocusNode,
                enabled: !viewport.autoX && !widget.controller.isBusy,
                decoration: _axisInputDecoration('X max (GPS s)'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onSubmitted: (_) => _applyAxisInputs(),
              ),
            ),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _yMinController,
                focusNode: _yMinFocusNode,
                enabled: !viewport.autoY && !widget.controller.isBusy,
                decoration: _axisInputDecoration('Y min ($unitLabel)'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                onSubmitted: (_) => _applyAxisInputs(),
              ),
            ),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _yMaxController,
                focusNode: _yMaxFocusNode,
                enabled: !viewport.autoY && !widget.controller.isBusy,
                decoration: _axisInputDecoration('Y max ($unitLabel)'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                onSubmitted: (_) => _applyAxisInputs(),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: widget.controller.isBusy ? null : _applyAxisInputs,
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Apply axis'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: CustomPaint(
            painter: _SeriesPainter(series: widget.series, viewport: viewport),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Values from ${widget.series.channel.displayName}. The viewport acts on the returned block, while timing context remains ${widget.series.axis.label}.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF53605A)),
        ),
      ],
    );
  }

  void _syncAxisFields({bool force = false}) {
    final viewport =
        widget.controller.seriesViewport ??
        _autoSeriesViewportFor(widget.series);

    _syncAxisField(
      controller: _xMinController,
      focusNode: _xMinFocusNode,
      value: viewport.xMinNs / 1.0e9,
      force: force,
      formatter: _formatGpsSecondsInput,
    );
    _syncAxisField(
      controller: _xMaxController,
      focusNode: _xMaxFocusNode,
      value: viewport.xMaxNs / 1.0e9,
      force: force,
      formatter: _formatGpsSecondsInput,
    );
    _syncAxisField(
      controller: _yMinController,
      focusNode: _yMinFocusNode,
      value: viewport.yMin,
      force: force,
      formatter: _formatAxisInput,
    );
    _syncAxisField(
      controller: _yMaxController,
      focusNode: _yMaxFocusNode,
      value: viewport.yMax,
      force: force,
      formatter: _formatAxisInput,
    );
  }

  void _syncAxisField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required double value,
    required bool force,
    required String Function(double value) formatter,
  }) {
    if (!force && focusNode.hasFocus) {
      return;
    }
    final text = formatter(value);
    if (controller.text == text) {
      return;
    }
    controller.text = text;
    controller.selection = TextSelection.collapsed(offset: text.length);
  }

  void _applyAxisInputs() {
    final viewport =
        widget.controller.seriesViewport ??
        _autoSeriesViewportFor(widget.series);

    final xMin = viewport.autoX
        ? null
        : _tryParseGpsSecondsToNs(
            _xMinController.text,
            fieldLabel: 'X minimum',
          );
    final xMax = viewport.autoX
        ? null
        : _tryParseGpsSecondsToNs(
            _xMaxController.text,
            fieldLabel: 'X maximum',
          );
    final yMin = viewport.autoY
        ? null
        : _tryParseAxisValue(_yMinController.text, fieldLabel: 'Y minimum');
    final yMax = viewport.autoY
        ? null
        : _tryParseAxisValue(_yMaxController.text, fieldLabel: 'Y maximum');

    if ((!viewport.autoX &&
            ((_xMinController.text.trim().isNotEmpty && xMin == null) ||
                (_xMaxController.text.trim().isNotEmpty && xMax == null))) ||
        (!viewport.autoY &&
            ((_yMinController.text.trim().isNotEmpty && yMin == null) ||
                (_yMaxController.text.trim().isNotEmpty && yMax == null)))) {
      return;
    }

    widget.controller.applySeriesManualBounds(
      xMinNs: xMin,
      xMaxNs: xMax,
      yMin: yMin,
      yMax: yMax,
    );
  }

  double? _tryParseGpsSecondsToNs(String raw, {required String fieldLabel}) {
    final parsedSeconds = _tryParseAxisValue(raw, fieldLabel: fieldLabel);
    if (parsedSeconds == null) {
      return null;
    }
    return parsedSeconds * 1.0e9;
  }

  double? _tryParseAxisValue(String raw, {required String fieldLabel}) {
    final value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    final parsed = double.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$fieldLabel must be a valid number.')),
    );
    return null;
  }

  InputDecoration _axisInputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: const Color(0xFFF2F5F1),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _SeriesPainter extends CustomPainter {
  _SeriesPainter({required this.series, required this.viewport});

  final SeriesBlock series;
  final SeriesViewport viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)),
      background,
    );

    final plotRect = _seriesChartPlotRect(size);

    if (plotRect.width <= 0 || plotRect.height <= 0) {
      return;
    }

    final plotBackground = Paint()
      ..color = const Color(0xFFF8FBF9)
      ..style = PaintingStyle.fill;
    final plotFrame = RRect.fromRectAndRadius(
      plotRect,
      const Radius.circular(16),
    );
    canvas.drawRRect(plotFrame, plotBackground);

    final gridPaint = Paint()
      ..color = const Color(0xFFE2E8E3)
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final dx = plotRect.left + plotRect.width * index / 4;
      final dy = plotRect.top + plotRect.height * index / 4;
      canvas.drawLine(
        Offset(dx, plotRect.top),
        Offset(dx, plotRect.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(plotRect.left, dy),
        Offset(plotRect.right, dy),
        gridPaint,
      );
    }

    final axisPaint = Paint()
      ..color = const Color(0xFF92A29B)
      ..strokeWidth = 1.4;
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

    if (series.values.isEmpty) {
      return;
    }

    final xSpan = math.max(1.0, viewport.xMaxNs - viewport.xMinNs);
    final ySpan = math.max(
      _adaptiveMagnitudeFloor(viewport.yMin, viewport.yMax),
      viewport.yMax - viewport.yMin,
    );

    if (viewport.yMin < 0 && viewport.yMax > 0) {
      final zeroY =
          plotRect.bottom - ((0 - viewport.yMin) / ySpan) * plotRect.height;
      final zeroPaint = Paint()
        ..color = const Color(0x55445C54)
        ..strokeWidth = 1.2;
      canvas.drawLine(
        Offset(plotRect.left, zeroY),
        Offset(plotRect.right, zeroY),
        zeroPaint,
      );
    }

    final linePaint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF0A7B6C), Color(0xFFDAA520)],
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    canvas.save();
    canvas.clipRRect(plotFrame);

    final path = Path();
    var moved = false;
    var visiblePoints = 0;
    Offset? singlePoint;
    for (var index = 0; index < series.values.length; index++) {
      final xNs = _seriesTimestampNs(series, index);
      if (xNs < viewport.xMinNs || xNs > viewport.xMaxNs) {
        continue;
      }
      final x =
          plotRect.left + ((xNs - viewport.xMinNs) / xSpan) * plotRect.width;
      final y =
          plotRect.bottom -
          ((series.values[index] - viewport.yMin) / ySpan) * plotRect.height;
      final point = Offset(x, y);
      if (!moved) {
        path.moveTo(x, y);
        moved = true;
        singlePoint = point;
      } else {
        path.lineTo(x, y);
      }
      visiblePoints += 1;
    }

    if (!moved) {
      canvas.restore();
      return;
    }

    if (visiblePoints == 1 && singlePoint != null) {
      canvas.drawCircle(
        singlePoint,
        4,
        Paint()..color = const Color(0xFF0A7B6C),
      );
    } else {
      canvas.drawPath(path, linePaint);
    }

    canvas.restore();

    final axisLabelStyle = const TextStyle(
      color: Color(0xFF57655E),
      fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    _paintAxisText(
      canvas,
      _formatPlotNumber(viewport.yMax),
      axisLabelStyle,
      Offset(10, plotRect.top - 2),
    );
    _paintAxisText(
      canvas,
      _formatPlotNumber((viewport.yMin + viewport.yMax) / 2),
      axisLabelStyle,
      Offset(10, plotRect.center.dy - 8),
    );
    _paintAxisText(
      canvas,
      _formatPlotNumber(viewport.yMin),
      axisLabelStyle,
      Offset(10, plotRect.bottom - 16),
    );
    _paintAxisText(
      canvas,
      _formatNsLabel(viewport.xMinNs.round()),
      axisLabelStyle,
      Offset(plotRect.left, plotRect.bottom + 10),
    );

    final xMaxPainter = TextPainter(
      text: TextSpan(
        text: _formatNsLabel(viewport.xMaxNs.round()),
        style: axisLabelStyle,
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    xMaxPainter.paint(
      canvas,
      Offset(plotRect.right - xMaxPainter.width, plotRect.bottom + 10),
    );
  }

  @override
  bool shouldRepaint(covariant _SeriesPainter oldDelegate) {
    return oldDelegate.series != series || oldDelegate.viewport != viewport;
  }

  void _paintAxisText(
    Canvas canvas,
    String text,
    TextStyle style,
    Offset offset,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(canvas, offset);
  }
}

class _SeriesDeckOverlayPainter extends CustomPainter {
  _SeriesDeckOverlayPainter({
    required this.deck,
    required this.viewport,
    required this.logY,
  });

  final List<SeriesDeckEntry> deck;
  final SeriesDeckViewport viewport;
  final bool logY;

  @override
  void paint(Canvas canvas, Size size) {
    _paintMultiSeriesChart(
      canvas: canvas,
      size: size,
      deck: deck,
      colors: [
        for (var index = 0; index < deck.length; index++)
          _seriesDeckColor(index),
      ],
      xExtentOverride: (viewport.xMinNs, viewport.xMaxNs),
      yExtentOverride: (viewport.yMin, viewport.yMax),
      logY: logY,
    );
  }

  @override
  bool shouldRepaint(covariant _SeriesDeckOverlayPainter oldDelegate) {
    return oldDelegate.deck != deck ||
        oldDelegate.viewport != viewport ||
        oldDelegate.logY != logY;
  }
}

class _StackedSeriesDeckPainter extends CustomPainter {
  _StackedSeriesDeckPainter({
    required this.series,
    required this.color,
    required this.xMinNs,
    required this.xMaxNs,
    required this.yMin,
    required this.yMax,
    required this.logY,
  });

  final SeriesBlock series;
  final Color color;
  final double xMinNs;
  final double xMaxNs;
  final double yMin;
  final double yMax;
  final bool logY;

  @override
  void paint(Canvas canvas, Size size) {
    _paintMultiSeriesChart(
      canvas: canvas,
      size: size,
      deck: [
        SeriesDeckEntry(
          stream: StreamDescriptor(
            channel: series.channel,
            kind: StreamKind.series1d,
            sampleShape: const [],
            tags: const [],
            extra: const {},
          ),
          series: series,
        ),
      ],
      colors: [color],
      xExtentOverride: (xMinNs, xMaxNs),
      yExtentOverride: (yMin, yMax),
      logY: logY,
    );
  }

  @override
  bool shouldRepaint(covariant _StackedSeriesDeckPainter oldDelegate) {
    return oldDelegate.series != series ||
        oldDelegate.color != color ||
        oldDelegate.xMinNs != xMinNs ||
        oldDelegate.xMaxNs != xMaxNs ||
        oldDelegate.yMin != yMin ||
        oldDelegate.yMax != yMax ||
        oldDelegate.logY != logY;
  }
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({
    required this.color,
    required this.borderColor,
    required this.textColor,
    required this.message,
  });

  final Color color;
  final Color borderColor;
  final Color textColor;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        message,
        style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 350),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: color.withAlpha(31),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF3EF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: Color(0xFF44514B),
        ),
      ),
    );
  }
}

class _CatalogInfoChip extends StatelessWidget {
  const _CatalogInfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF0ED),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF4F5E58),
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _FeatureBullet extends StatelessWidget {
  const _FeatureBullet({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF0A7B6C),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF51605A),
                  height: 1.5,
                ),
                children: [
                  TextSpan(
                    text: '$title. ',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2925),
                    ),
                  ),
                  TextSpan(text: text),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _paintMultiSeriesChart({
  required Canvas canvas,
  required Size size,
  required List<SeriesDeckEntry> deck,
  required List<Color> colors,
  (double, double)? xExtentOverride,
  (double, double)? yExtentOverride,
  bool logY = false,
}) {
  final background = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..style = PaintingStyle.fill;
  canvas.drawRRect(
    RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)),
    background,
  );

  if (deck.isEmpty) {
    return;
  }

  final plotRect = _seriesChartPlotRect(size);

  if (plotRect.width <= 0 || plotRect.height <= 0) {
    return;
  }

  final plotBackground = Paint()
    ..color = const Color(0xFFF8FBF9)
    ..style = PaintingStyle.fill;
  final plotFrame = RRect.fromRectAndRadius(
    plotRect,
    const Radius.circular(16),
  );
  canvas.drawRRect(plotFrame, plotBackground);

  final gridPaint = Paint()
    ..color = const Color(0xFFE2E8E3)
    ..strokeWidth = 1;
  for (var index = 0; index <= 4; index++) {
    final dx = plotRect.left + plotRect.width * index / 4;
    final dy = plotRect.top + plotRect.height * index / 4;
    canvas.drawLine(
      Offset(dx, plotRect.top),
      Offset(dx, plotRect.bottom),
      gridPaint,
    );
    canvas.drawLine(
      Offset(plotRect.left, dy),
      Offset(plotRect.right, dy),
      gridPaint,
    );
  }

  final axisPaint = Paint()
    ..color = const Color(0xFF92A29B)
    ..strokeWidth = 1.4;
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

  final xExtent = xExtentOverride ?? _seriesDeckTimeExtent(deck);
  final yExtent = yExtentOverride ?? _seriesDeckValueExtent(deck, logY: logY);
  final xSpan = math.max(1.0, xExtent.$2 - xExtent.$1);

  // Effective y-domain bounds. For log mode we clamp non-positives to a tiny
  // positive floor so the projection stays well-defined; data points <=0 are
  // dropped as gaps below.
  late final double effectiveYMin;
  late final double effectiveYMax;
  late final double logYMin;
  late final double logYMax;
  late final double logYSpan;
  late final double linearYSpan;
  if (logY) {
    effectiveYMin = yExtent.$1 > 0 ? yExtent.$1 : 1e-12;
    effectiveYMax = yExtent.$2 > effectiveYMin
        ? yExtent.$2
        : effectiveYMin * 10.0;
    logYMin = math.log(effectiveYMin) / math.ln10;
    logYMax = math.log(effectiveYMax) / math.ln10;
    logYSpan = math.max(1e-12, logYMax - logYMin);
    linearYSpan = effectiveYMax - effectiveYMin;
  } else {
    effectiveYMin = yExtent.$1;
    effectiveYMax = yExtent.$2;
    logYMin = 0;
    logYMax = 0;
    logYSpan = 1;
    linearYSpan = math.max(
      _adaptiveMagnitudeFloor(effectiveYMin, effectiveYMax),
      effectiveYMax - effectiveYMin,
    );
  }

  double yToPixel(double value) {
    if (logY) {
      if (!value.isFinite || value <= 0) {
        return double.nan;
      }
      final logValue = math.log(value) / math.ln10;
      return plotRect.bottom -
          ((logValue - logYMin) / logYSpan) * plotRect.height;
    }
    if (!value.isFinite) {
      return double.nan;
    }
    return plotRect.bottom -
        ((value - effectiveYMin) / linearYSpan) * plotRect.height;
  }

  if (!logY && effectiveYMin < 0 && effectiveYMax > 0) {
    final zeroY = yToPixel(0);
    if (zeroY.isFinite) {
      final zeroPaint = Paint()
        ..color = const Color(0x55445C54)
        ..strokeWidth = 1.2;
      canvas.drawLine(
        Offset(plotRect.left, zeroY),
        Offset(plotRect.right, zeroY),
        zeroPaint,
      );
    }
  }

  if (logY) {
    final decadeGridPaint = Paint()
      ..color = const Color(0x33445C54)
      ..strokeWidth = 1.0;
    final startDecade = logYMin.floor();
    final endDecade = logYMax.ceil();
    for (var decade = startDecade; decade <= endDecade; decade++) {
      final value = math.pow(10.0, decade).toDouble();
      final yPx = yToPixel(value);
      if (yPx.isFinite && yPx >= plotRect.top && yPx <= plotRect.bottom) {
        canvas.drawLine(
          Offset(plotRect.left, yPx),
          Offset(plotRect.right, yPx),
          decadeGridPaint,
        );
      }
    }
  }

  canvas.save();
  canvas.clipRRect(plotFrame);
  for (var entryIndex = 0; entryIndex < deck.length; entryIndex++) {
    final series = deck[entryIndex].series;
    if (series.values.isEmpty) {
      continue;
    }

    final path = Path();
    var moved = false;
    var visiblePoints = 0;
    Offset? singlePoint;
    for (
      var sampleIndex = 0;
      sampleIndex < series.values.length;
      sampleIndex++
    ) {
      final xNs = _seriesTimestampNs(series, sampleIndex);
      if (xNs < xExtent.$1 || xNs > xExtent.$2) {
        continue;
      }
      final value = series.values[sampleIndex];
      final y = yToPixel(value);
      if (!y.isFinite) {
        // Break the line on missing / non-positive (in log mode) samples.
        moved = false;
        singlePoint = null;
        continue;
      }
      final x = plotRect.left + ((xNs - xExtent.$1) / xSpan) * plotRect.width;
      final point = Offset(x, y);
      if (!moved) {
        path.moveTo(x, y);
        moved = true;
        singlePoint = point;
      } else {
        path.lineTo(x, y);
      }
      visiblePoints += 1;
    }

    if (visiblePoints == 0) {
      continue;
    }

    final color = colors[entryIndex % colors.length];
    if (visiblePoints == 1 && singlePoint != null) {
      canvas.drawCircle(singlePoint, 3.5, Paint()..color = color);
      continue;
    }

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, linePaint);
  }
  canvas.restore();

  final axisLabelStyle = const TextStyle(
    color: Color(0xFF57655E),
    fontSize: 11,
    fontWeight: FontWeight.w600,
  );
  final yMidValue = logY
      ? math.pow(10.0, (logYMin + logYMax) / 2).toDouble()
      : (effectiveYMin + effectiveYMax) / 2;
  _paintAxisText(
    canvas,
    _formatPlotNumber(effectiveYMax),
    axisLabelStyle,
    Offset(10, plotRect.top - 2),
  );
  _paintAxisText(
    canvas,
    _formatPlotNumber(yMidValue),
    axisLabelStyle,
    Offset(10, plotRect.center.dy - 8),
  );
  _paintAxisText(
    canvas,
    _formatPlotNumber(effectiveYMin),
    axisLabelStyle,
    Offset(10, plotRect.bottom - 16),
  );
  if (logY) {
    _paintAxisText(
      canvas,
      'log',
      axisLabelStyle.copyWith(fontStyle: FontStyle.italic),
      Offset(10, plotRect.top + 14),
    );
  }
  _paintAxisText(
    canvas,
    _formatNsLabel(xExtent.$1.round()),
    axisLabelStyle,
    Offset(plotRect.left, plotRect.bottom + 10),
  );
  final xMaxPainter = TextPainter(
    text: TextSpan(
      text: _formatNsLabel(xExtent.$2.round()),
      style: axisLabelStyle,
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  xMaxPainter.paint(
    canvas,
    Offset(plotRect.right - xMaxPainter.width, plotRect.bottom + 10),
  );
}

void _paintAxisText(
  Canvas canvas,
  String text,
  TextStyle style,
  Offset offset,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  painter.paint(canvas, offset);
}

(double, double) _seriesDeckTimeExtent(List<SeriesDeckEntry> deck) {
  if (deck.isEmpty) {
    return (0, 1);
  }

  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  for (final entry in deck) {
    final extent = _seriesDeckEntryTimeExtent(entry);
    minX = math.min(minX, extent.$1);
    maxX = math.max(maxX, extent.$2);
  }
  if (!minX.isFinite || !maxX.isFinite || maxX <= minX) {
    return (0, 1);
  }
  return (minX, maxX);
}

(double, double) _seriesDeckEntryTimeExtent(SeriesDeckEntry entry) {
  final windowRange = entry.windowRange;
  if (windowRange != null && windowRange.endNs > windowRange.startNs) {
    return (windowRange.startNs.toDouble(), windowRange.endNs.toDouble());
  }
  return _seriesTimeExtent(entry.series);
}

SeriesBlock? _asScalarSeriesBlock(DataBlock? block) {
  if (block is SeriesBlock) {
    return block;
  }
  if (block is SampledBlock) {
    return block.asScalarSeries;
  }
  return null;
}

(double, double) _seriesDeckValueExtent(
  List<SeriesDeckEntry> deck, {
  bool logY = false,
}) {
  if (deck.isEmpty) {
    return logY ? (0.1, 10.0) : (-1, 1);
  }

  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  for (final entry in deck) {
    final extent = _seriesYExtent(entry.series, logY: logY);
    minY = math.min(minY, extent.$1);
    maxY = math.max(maxY, extent.$2);
  }
  if (!minY.isFinite || !maxY.isFinite || maxY <= minY) {
    return logY ? (0.1, 10.0) : (-1, 1);
  }
  return (minY, maxY);
}

(double, double) _seriesDeckVisibleValueExtent(
  List<SeriesDeckEntry> deck,
  double xMinNs,
  double xMaxNs, {
  bool logY = false,
}) {
  if (deck.isEmpty) {
    return logY ? (0.1, 10.0) : (-1, 1);
  }

  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  for (final entry in deck) {
    final extent = _seriesVisibleValueExtent(
      entry.series,
      xMinNs,
      xMaxNs,
      logY: logY,
    );
    minY = math.min(minY, extent.$1);
    maxY = math.max(maxY, extent.$2);
  }
  if (!minY.isFinite || !maxY.isFinite || maxY <= minY) {
    return _seriesDeckValueExtent(deck, logY: logY);
  }
  return (minY, maxY);
}

(double, double) _seriesTimeExtent(SeriesBlock series) {
  if (series.values.isEmpty) {
    return (0, 1);
  }

  if (series.axis case RegularTimeAxis axis) {
    final start = axis.startNs.toDouble();
    if (series.values.length > 1 && axis.samplePeriodNs > 0) {
      return (start, start + axis.samplePeriodNs * (series.values.length - 1));
    }

    final previewEndNs =
        _parseInt(series.metadata['preview.end_ns']) ??
        _parseInt(series.channel.metadata['preview.end_ns']) ??
        _parseInt(series.metadata['hdf5.attr.end_ns']) ??
        _parseInt(series.channel.metadata['hdf5.attr.end_ns']);
    if (previewEndNs != null && previewEndNs > axis.startNs) {
      return (start, previewEndNs.toDouble());
    }

    final stepNs = _seriesStepNs(series);
    if (stepNs > 0) {
      return (start, start + stepNs);
    }

    return (start, start + 1);
  }

  if (series.axis case IrregularTimeAxis axis) {
    if (axis.timestampsNs.isEmpty) {
      return (0, 1);
    }

    final start = axis.timestampsNs.first.toDouble();
    final end = axis.timestampsNs.last.toDouble();
    if (end > start) {
      return (start, end);
    }
    return (start, start + 1);
  }

  final start = _seriesTimestampNs(series, 0);
  final end = _seriesTimestampNs(series, math.max(0, series.values.length - 1));
  if (end <= start) {
    return (start, start + 1);
  }
  return (start, end);
}

(double, double) _seriesVisibleValueExtent(
  SeriesBlock series,
  double xMinNs,
  double xMaxNs, {
  bool logY = false,
}) {
  if (series.values.isEmpty) {
    return logY ? (0.1, 10.0) : (-1, 1);
  }

  var minValue = double.infinity;
  var maxValue = double.negativeInfinity;
  for (var index = 0; index < series.values.length; index++) {
    final xNs = _seriesTimestampNs(series, index);
    if (xNs < xMinNs || xNs > xMaxNs) {
      continue;
    }
    final value = series.values[index];
    if (logY && (!value.isFinite || value <= 0)) {
      continue;
    }
    minValue = math.min(minValue, value);
    maxValue = math.max(maxValue, value);
  }

  if (!minValue.isFinite || !maxValue.isFinite) {
    return _seriesYExtent(series, logY: logY);
  }
  return logY
      ? _expandPlotLogYExtent(minValue, maxValue)
      : _expandPlotYExtent(minValue, maxValue);
}

double _seriesTimestampNs(SeriesBlock series, int index) {
  if (series.axis case RegularTimeAxis axis) {
    return axis.startNs + axis.samplePeriodNs * index.toDouble();
  }
  if (series.axis case IrregularTimeAxis axis) {
    if (axis.timestampsNs.isEmpty) {
      return index.toDouble();
    }
    final clampedIndex = index.clamp(0, axis.timestampsNs.length - 1);
    return axis.timestampsNs[clampedIndex].toDouble();
  }
  return index.toDouble();
}

double _seriesStepNs(SeriesBlock series) {
  if (series.axis case RegularTimeAxis axis) {
    if (axis.samplePeriodNs > 0) {
      return axis.samplePeriodNs.toDouble();
    }
  }

  final samplePeriodNs =
      _parseInt(series.metadata['preview.sample_period_ns']) ??
      _parseInt(series.channel.metadata['preview.sample_period_ns']) ??
      _parseInt(series.metadata['hdf5.attr.sample_period_ns']) ??
      _parseInt(series.channel.metadata['hdf5.attr.sample_period_ns']) ??
      _samplePeriodFromRate(series.channel.sampleRateHz);
  if (samplePeriodNs == null || samplePeriodNs <= 0) {
    return 1.0;
  }
  return samplePeriodNs.toDouble();
}

bool _seriesDeckHasMixedUnits(List<SeriesDeckEntry> deck) {
  final units = deck
      .map((entry) => entry.stream.channel.unit?.trim() ?? '')
      .where((unit) => unit.isNotEmpty)
      .toSet();
  return units.length > 1;
}

SeriesDeckViewport _autoSeriesDeckViewport(
  List<SeriesDeckEntry> deck, {
  bool logY = false,
}) {
  final xExtent = _seriesDeckTimeExtent(deck);
  final yExtent = _seriesDeckValueExtent(deck, logY: logY);
  return SeriesDeckViewport(
    autoX: true,
    autoY: true,
    xMinNs: xExtent.$1,
    xMaxNs: xExtent.$2,
    yMin: yExtent.$1,
    yMax: yExtent.$2,
  );
}

SeriesDeckViewport _normalizeSeriesDeckViewport(
  List<SeriesDeckEntry> deck,
  SeriesDeckViewport viewport, {
  bool logY = false,
}) {
  final fullXExtent = _seriesDeckTimeExtent(deck);
  final fullXSpan = math.max(1.0, fullXExtent.$2 - fullXExtent.$1);

  var xMinNs = viewport.autoX ? fullXExtent.$1 : viewport.xMinNs;
  var xMaxNs = viewport.autoX ? fullXExtent.$2 : viewport.xMaxNs;
  const minXSpan = 1.0;

  if (xMinNs < fullXExtent.$1) {
    xMaxNs += fullXExtent.$1 - xMinNs;
    xMinNs = fullXExtent.$1;
  }
  if (xMaxNs > fullXExtent.$2) {
    xMinNs -= xMaxNs - fullXExtent.$2;
    xMaxNs = fullXExtent.$2;
  }
  if (xMaxNs - xMinNs < minXSpan) {
    final center = (xMinNs + xMaxNs) / 2;
    xMinNs = center - minXSpan / 2;
    xMaxNs = center + minXSpan / 2;
  }
  if (xMinNs < fullXExtent.$1) {
    xMaxNs += fullXExtent.$1 - xMinNs;
    xMinNs = fullXExtent.$1;
  }
  if (xMaxNs > fullXExtent.$2) {
    xMinNs -= xMaxNs - fullXExtent.$2;
    xMaxNs = fullXExtent.$2;
  }
  if (xMaxNs - xMinNs > fullXSpan) {
    xMinNs = fullXExtent.$1;
    xMaxNs = fullXExtent.$2;
  }

  final visibleYExtent = _seriesDeckVisibleValueExtent(
    deck,
    xMinNs,
    xMaxNs,
    logY: logY,
  );
  var yMin = viewport.autoY ? visibleYExtent.$1 : viewport.yMin;
  var yMax = viewport.autoY ? visibleYExtent.$2 : viewport.yMax;
  if (logY) {
    if (yMin <= 0) {
      yMin = visibleYExtent.$1 > 0 ? visibleYExtent.$1 : 1e-12;
    }
    if (yMax <= yMin) {
      yMax = yMin * 10.0;
    }
  } else {
    final minYSpan = _adaptiveMagnitudeFloor(
      visibleYExtent.$1,
      visibleYExtent.$2,
    );
    if (yMax - yMin < minYSpan) {
      final center = (yMin + yMax) / 2;
      yMin = center - minYSpan / 2;
      yMax = center + minYSpan / 2;
    }
  }

  return SeriesDeckViewport(
    autoX: viewport.autoX,
    autoY: viewport.autoY,
    xMinNs: xMinNs,
    xMaxNs: xMaxNs,
    yMin: yMin,
    yMax: yMax,
  );
}

SeriesDeckViewport _autoSeriesDeckViewportForEntry(
  SeriesDeckEntry entry, {
  bool logY = false,
}) {
  return _autoSeriesDeckViewport([entry], logY: logY);
}

SeriesDeckViewport _normalizeSeriesDeckViewportForEntry(
  SeriesDeckEntry entry,
  SeriesDeckViewport viewport, {
  bool logY = false,
}) {
  return _normalizeSeriesDeckViewport([entry], viewport, logY: logY);
}

SeriesDeckViewport _panSeriesDeckViewportX(
  SeriesDeckEntry entry,
  SeriesDeckViewport viewport,
  double fraction, {
  bool logY = false,
}) {
  final span = viewport.xMaxNs - viewport.xMinNs;
  final delta = span * fraction;
  return _normalizeSeriesDeckViewportForEntry(
    entry,
    viewport.copyWith(
      autoX: false,
      xMinNs: viewport.xMinNs + delta,
      xMaxNs: viewport.xMaxNs + delta,
    ),
    logY: logY,
  );
}

SeriesDeckViewport _panSeriesDeckViewportY(
  SeriesDeckEntry entry,
  SeriesDeckViewport viewport,
  double fraction, {
  bool logY = false,
}) {
  if (logY) {
    final newBounds = _logScaledYBounds(
      viewport.yMin,
      viewport.yMax,
      panFraction: fraction,
    );
    return _normalizeSeriesDeckViewportForEntry(
      entry,
      viewport.copyWith(
        autoY: false,
        yMin: newBounds.$1,
        yMax: newBounds.$2,
      ),
      logY: logY,
    );
  }
  final span = viewport.yMax - viewport.yMin;
  final delta = span * fraction;
  return _normalizeSeriesDeckViewportForEntry(
    entry,
    viewport.copyWith(
      autoY: false,
      yMin: viewport.yMin + delta,
      yMax: viewport.yMax + delta,
    ),
    logY: logY,
  );
}

(double, double) _logScaledYBounds(
  double yMin,
  double yMax, {
  double panFraction = 0.0,
  double zoomFactor = 1.0,
}) {
  final safeMin = yMin > 0 ? yMin : 1e-12;
  final safeMax = yMax > safeMin ? yMax : safeMin * 10.0;
  final logMin = math.log(safeMin) / math.ln10;
  final logMax = math.log(safeMax) / math.ln10;
  final span = logMax - logMin;
  final delta = span * panFraction;
  final center = (logMin + logMax) / 2 + delta;
  final nextSpan = span * zoomFactor;
  final newLogMin = center - nextSpan / 2;
  final newLogMax = center + nextSpan / 2;
  return (
    math.pow(10.0, newLogMin).toDouble(),
    math.pow(10.0, newLogMax).toDouble(),
  );
}

Color _seriesDeckColor(int index) {
  const palette = [
    Color(0xFF0A7B6C),
    Color(0xFFDAA520),
    Color(0xFF335C81),
    Color(0xFFC65F2A),
    Color(0xFFAA3A52),
    Color(0xFF5D7C2F),
  ];
  return palette[index % palette.length];
}

const _seriesChartLeftInset = 78.0;
const _seriesChartRightInset = 22.0;
const _seriesChartTopInset = 18.0;
const _seriesChartBottomInset = 42.0;

Rect _seriesChartPlotRect(Size size) {
  return Rect.fromLTWH(
    _seriesChartLeftInset,
    _seriesChartTopInset,
    math.max(0.0, size.width - _seriesChartLeftInset - _seriesChartRightInset),
    math.max(0.0, size.height - _seriesChartTopInset - _seriesChartBottomInset),
  );
}

SeriesViewport _autoSeriesViewportFor(SeriesBlock series) {
  final xExtent = _seriesTimeExtent(series);
  final (yMin, yMax) = _seriesYExtent(series);
  return SeriesViewport(
    autoX: true,
    autoY: true,
    xMinNs: xExtent.$1,
    xMaxNs: xExtent.$2,
    yMin: yMin,
    yMax: yMax,
  );
}

SeriesViewport _normalizeSeriesViewport(
  SeriesBlock series,
  SeriesViewport viewport,
) {
  final fullXExtent = _seriesTimeExtent(series);
  final fullXSpan = math.max(1.0, fullXExtent.$2 - fullXExtent.$1);
  final minXSpan = math.max(1.0, _seriesStepNs(series));

  var xMinNs = viewport.autoX ? fullXExtent.$1 : viewport.xMinNs;
  var xMaxNs = viewport.autoX ? fullXExtent.$2 : viewport.xMaxNs;

  if (xMinNs < fullXExtent.$1) {
    xMaxNs += fullXExtent.$1 - xMinNs;
    xMinNs = fullXExtent.$1;
  }
  if (xMaxNs > fullXExtent.$2) {
    xMinNs -= xMaxNs - fullXExtent.$2;
    xMaxNs = fullXExtent.$2;
  }
  if (xMaxNs - xMinNs < minXSpan) {
    final center = (xMinNs + xMaxNs) / 2;
    xMinNs = center - minXSpan / 2;
    xMaxNs = center + minXSpan / 2;
  }
  if (xMinNs < fullXExtent.$1) {
    xMaxNs += fullXExtent.$1 - xMinNs;
    xMinNs = fullXExtent.$1;
  }
  if (xMaxNs > fullXExtent.$2) {
    xMinNs -= xMaxNs - fullXExtent.$2;
    xMaxNs = fullXExtent.$2;
  }
  if (xMaxNs - xMinNs > fullXSpan) {
    xMinNs = fullXExtent.$1;
    xMaxNs = fullXExtent.$2;
  }

  final (dataYMin, dataYMax) = _seriesYExtent(series);
  var yMin = viewport.autoY ? dataYMin : viewport.yMin;
  var yMax = viewport.autoY ? dataYMax : viewport.yMax;
  final minYSpan = _adaptiveMagnitudeFloor(dataYMin, dataYMax);
  if (yMax - yMin < minYSpan) {
    final center = (yMin + yMax) / 2;
    yMin = center - minYSpan / 2;
    yMax = center + minYSpan / 2;
  }

  return SeriesViewport(
    autoX: viewport.autoX,
    autoY: viewport.autoY,
    xMinNs: xMinNs,
    xMaxNs: xMaxNs,
    yMin: yMin,
    yMax: yMax,
  );
}

(double, double) _seriesYExtent(SeriesBlock series, {bool logY = false}) {
  if (series.values.isEmpty) {
    return logY ? (0.1, 10.0) : (-1.0, 1.0);
  }

  var minValue = double.infinity;
  var maxValue = double.negativeInfinity;
  for (final value in series.values) {
    if (!value.isFinite) {
      continue;
    }
    if (logY && value <= 0) {
      continue;
    }
    if (value < minValue) {
      minValue = value;
    }
    if (value > maxValue) {
      maxValue = value;
    }
  }
  if (!minValue.isFinite || !maxValue.isFinite) {
    return logY ? (0.1, 10.0) : (-1.0, 1.0);
  }

  return logY
      ? _expandPlotLogYExtent(minValue, maxValue)
      : _expandPlotYExtent(minValue, maxValue);
}

(double, double) _expandPlotYExtent(double minValue, double maxValue) {
  if (!minValue.isFinite || !maxValue.isFinite) {
    return (-1, 1);
  }

  final span = (maxValue - minValue).abs();
  final floor = _adaptiveMagnitudeFloor(minValue, maxValue);
  final padding = span <= floor
      ? math.max(math.max(minValue.abs(), maxValue.abs()) * 0.1, floor * 100)
      : math.max(span * 0.05, floor * 100);
  return (minValue - padding, maxValue + padding);
}

(double, double) _expandPlotLogYExtent(double minValue, double maxValue) {
  if (!minValue.isFinite || !maxValue.isFinite || minValue <= 0) {
    return (0.1, 10.0);
  }
  if (maxValue <= minValue) {
    return (minValue / 10.0, math.max(maxValue, minValue) * 10.0);
  }
  final logMin = math.log(minValue) / math.ln10;
  final logMax = math.log(maxValue) / math.ln10;
  final padding = math.max(0.05 * (logMax - logMin), 0.05);
  final paddedMin = math.pow(10.0, logMin - padding).toDouble();
  final paddedMax = math.pow(10.0, logMax + padding).toDouble();
  return (paddedMin, paddedMax);
}

int _visibleSeriesSampleCount(SeriesBlock series, SeriesViewport viewport) {
  if (series.values.isEmpty) {
    return 0;
  }
  var count = 0;
  for (var index = 0; index < series.values.length; index++) {
    final xNs = _seriesTimestampNs(series, index);
    if (xNs >= viewport.xMinNs && xNs <= viewport.xMaxNs) {
      count += 1;
    }
  }
  return count;
}

String _formatAxisInput(double value) {
  if ((value - value.round()).abs() < 1e-6) {
    return value.round().toString();
  }
  final absValue = value.abs();
  if (absValue >= 100000 || (absValue > 0 && absValue < 0.001)) {
    return value.toStringAsExponential(6);
  }
  if (absValue >= 1000) {
    return value.toStringAsFixed(1);
  }
  if (absValue >= 1) {
    return value.toStringAsFixed(6);
  }
  return value.toStringAsFixed(9);
}

String _formatGpsSecondsInput(double valueSeconds) {
  if ((valueSeconds - valueSeconds.round()).abs() < 1e-9) {
    return valueSeconds.round().toString();
  }
  return valueSeconds.toStringAsFixed(6);
}

String _formatGpsSecondsInputFromNs(double valueNs) {
  return _formatGpsSecondsInput(valueNs / 1.0e9);
}

String _formatDurationSecondsInput(int durationNs) {
  return _formatGpsSecondsInput(durationNs / 1.0e9);
}

String _formatPlotNumber(double value) {
  final absValue = value.abs();
  if (absValue >= 100000 || (absValue > 0 && absValue < 0.001)) {
    return value.toStringAsExponential(3);
  }
  if (absValue >= 1000) {
    return value.toStringAsFixed(0);
  }
  if (absValue >= 10) {
    return value.toStringAsFixed(2);
  }
  if (absValue >= 1) {
    return value.toStringAsFixed(3);
  }
  return value.toStringAsFixed(6);
}

double _adaptiveMagnitudeFloor(double minValue, double maxValue) {
  final referenceMagnitude = math.max(
    (maxValue - minValue).abs(),
    math.max(minValue.abs(), maxValue.abs()),
  );
  if (referenceMagnitude <= 0) {
    return 1e-24;
  }
  return referenceMagnitude * 1e-6;
}

Color _kindColor(StreamKind kind) {
  switch (kind) {
    case StreamKind.series1d:
      return const Color(0xFF0A7B6C);
    case StreamKind.sampled:
      return const Color(0xFF0E8F83);
    case StreamKind.grid2d:
      return const Color(0xFF335C81);
    case StreamKind.volume3d:
      return const Color(0xFFC27B2B);
    case StreamKind.eventSeries:
      return const Color(0xFFAA3A52);
  }
}

int? _parseInt(String? value) => value == null ? null : int.tryParse(value);

int? _samplePeriodFromRate(double? sampleRateHz) {
  if (sampleRateHz == null || sampleRateHz <= 0) {
    return null;
  }
  return (1000000000 / sampleRateHz).round();
}

String _formatNsLabel(int value) {
  if (value.abs() >= 1000000000) {
    final seconds = value / 1000000000;
    if ((seconds - seconds.round()).abs() < 1e-9) {
      return '${seconds.round()} s';
    }
    if ((seconds * 1000 - (seconds * 1000).round()).abs() < 1e-6) {
      return '${seconds.toStringAsFixed(3)} s';
    }
    return '${seconds.toStringAsFixed(6)} s';
  }
  if (value.abs() >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)} ms';
  }
  return '$value ns';
}

// ─────────────────────────────────────────────────────────────────────────────
// Tomcat backend panel
// ─────────────────────────────────────────────────────────────────────────────

class _TomcatPanel extends StatefulWidget {
  const _TomcatPanel({required this.controller});

  final WorkspaceController controller;

  @override
  State<_TomcatPanel> createState() => _TomcatPanelState();
}

/// Default Tomcat backend URL. Overridable at startup with `DD_TOMCAT_URL`.
String _defaultTomcatUrl() {
  final fromEnv = io.Platform.environment['DD_TOMCAT_URL']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }
  return 'http://olserver134.virgo.infn.it:8082/datadisplay-tomcat-backend';
}

/// Default channel list for the live panel. Overridable with `DD_TOMCAT_LIVE_CHANNELS`.
String _defaultTomcatLiveChannels() {
  final fromEnv = io.Platform.environment['DD_TOMCAT_LIVE_CHANNELS']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }
  return 'V1:DER_DATA_H';
}

class _TomcatPanelState extends State<_TomcatPanel> {
  final _hostController = TextEditingController(text: _defaultTomcatUrl());
  final _liveChannelsController = TextEditingController(
    text: _defaultTomcatLiveChannels(),
  );

  List<Map<String, dynamic>> _fflSources = [];
  String? _selectedFfl;
  bool _connecting = false;
  String? _error;

  TomcatLivePoller? _livePoller;
  StreamSubscription<LivePollResult>? _liveSub;
  bool _liveRunning = false;
  LivePollResult? _lastLive;
  int? _ffiSubscriptionId;
  Timer? _ffiPollTimer;
  String? _liveMode; // 'ffi' or 'http'
  int _ffiSampleCount = 0;
  String? _ffiLastChannel;

  String get _baseUrl => _hostController.text.trim();

  @override
  void dispose() {
    // Tear down live resources directly here without setState — the widget is
    // already being unmounted, so notifying listeners is unsafe.
    _liveSub?.cancel();
    _liveSub = null;
    _livePoller?.dispose();
    _livePoller = null;
    _ffiPollTimer?.cancel();
    _ffiPollTimer = null;
    final native = widget.controller.nativeLoadResult.backend;
    final subId = _ffiSubscriptionId;
    if (native != null && subId != null) {
      native.unsubscribe(subId).catchError((_) {});
    }
    _ffiSubscriptionId = null;
    _hostController.dispose();
    _liveChannelsController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
      _fflSources = [];
      _selectedFfl = null;
    });
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/datadisplay/ffls');
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        setState(() { _error = 'HTTP ${response.statusCode}'; });
        return;
      }
      final json = dart_convert.jsonDecode(response.body) as List<dynamic>;
      final sources = json.cast<Map<String, dynamic>>();
      setState(() {
        _fflSources = sources;
        _selectedFfl = sources.isNotEmpty ? sources.first['id'] as String : null;
      });
    } catch (e) {
      setState(() { _error = '$e'; });
    } finally {
      setState(() { _connecting = false; });
    }
  }

  Future<void> _openArchiveSource() async {
    final ffl = _selectedFfl;
    if (ffl == null) return;
    final urlPart = _baseUrl.replaceFirst(RegExp(r'^https?://'), '');
    final uri = 'tomcat://$urlPart?ffl=$ffl';
    widget.controller.openSource(uri);
  }

  Future<void> _startLive() async {
    if (_liveRunning) return;
    final channels = _liveChannelsController.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (channels.isEmpty) return;

    final native = widget.controller.nativeLoadResult.backend;
    final source = widget.controller.source;
    final ffiCapable = native != null &&
        source != null &&
        source.uri.startsWith('tomcat://') &&
        source.capabilities.liveSubscriptions;

    if (ffiCapable) {
      try {
        final subId = await native.subscribe(
          sourceId: source.sourceId,
          channelId: channels.first,
        );
        _ffiSubscriptionId = subId;
        _ffiLastChannel = channels.first;
        _ffiSampleCount = 0;
        _ffiPollTimer = Timer.periodic(
          const Duration(milliseconds: 1000),
          (_) => _pollFfiSubscription(),
        );
        if (mounted) {
          setState(() {
            _liveRunning = true;
            _liveMode = 'ffi';
            _error = null;
          });
        }
        return;
      } catch (error) {
        if (mounted) setState(() { _error = 'FFI subscribe failed: $error'; });
        return;
      }
    }

    final poller = TomcatLivePoller(
      baseUrl: _baseUrl,
      channels: channels,
      pollIntervalMs: 1000,
    );
    _livePoller = poller;
    _liveSub = poller.stream.listen((result) {
      if (mounted) setState(() { _lastLive = result; });
    });
    poller.start();
    if (mounted) {
      setState(() {
        _liveRunning = true;
        _liveMode = 'http';
      });
    }
  }

  Future<void> _pollFfiSubscription() async {
    final native = widget.controller.nativeLoadResult.backend;
    final subId = _ffiSubscriptionId;
    if (native == null || subId == null) return;
    try {
      final block = await native.pollSubscription(subId);
      if (block is SeriesBlock && mounted) {
        setState(() {
          _ffiSampleCount += block.values.length;
        });
      }
    } catch (_) {
      // swallow transient errors
    }
  }

  Future<void> _stopLive() async {
    _liveSub?.cancel();
    _liveSub = null;
    _livePoller?.dispose();
    _livePoller = null;

    _ffiPollTimer?.cancel();
    _ffiPollTimer = null;
    final native = widget.controller.nativeLoadResult.backend;
    final subId = _ffiSubscriptionId;
    if (native != null && subId != null) {
      try {
        await native.unsubscribe(subId);
      } catch (_) {}
    }
    _ffiSubscriptionId = null;

    if (mounted) {
      setState(() {
        _liveRunning = false;
        _liveMode = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Tomcat backend',
      subtitle: 'Connect to the DataDisplay Tomcat endpoint for FFL archive and live Ser data.',
      expandChild: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Backend URL',
              hintText: 'http://olserver134.virgo.infn.it:8082/datadisplay-tomcat-backend',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            ElevatedButton(
              onPressed: _connecting ? null : _connect,
              child: _connecting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Connect'),
            ),
            if (_fflSources.isNotEmpty) ...[
              const SizedBox(width: 12),
              DropdownButton<String>(
                value: _selectedFfl,
                isDense: true,
                items: [
                  for (final src in _fflSources)
                    DropdownMenuItem(
                      value: src['id'] as String,
                      child: Text(src['label'] as String? ?? src['id'] as String),
                    ),
                ],
                onChanged: (v) => setState(() { _selectedFfl = v; }),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _selectedFfl != null ? _openArchiveSource : null,
                child: const Text('Open archive'),
              ),
            ],
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          const Text('Live (1 Hz Ser)', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          TextField(
            controller: _liveChannelsController,
            decoration: const InputDecoration(
              labelText: 'Channels (comma-separated)',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            ElevatedButton(
              onPressed: _liveRunning ? null : _startLive,
              child: const Text('Start live'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _liveRunning ? _stopLive : null,
              child: const Text('Stop'),
            ),
            if (_liveRunning) ...[
              const SizedBox(width: 12),
              _StatusChip(
                label: _liveMode == 'ffi' ? 'Live (FFI)' : 'Live (HTTP)',
                color: const Color(0xFF0A7B6C),
              ),
            ],
          ]),
          if (_liveMode == 'http' && _lastLive != null) ...[
            const SizedBox(height: 10),
            Text(
              '${_lastLive!.series.length} channel(s) · '
              '${_lastLive!.series.fold(0, (sum, s) => sum + s.values.length)} samples (HTTP)',
              style: const TextStyle(fontSize: 12, color: Color(0xFF46534D)),
            ),
          ],
          if (_liveMode == 'ffi') ...[
            const SizedBox(height: 10),
            Text(
              'Channel ${_ffiLastChannel ?? '-'} · $_ffiSampleCount samples received (dd-ffi subscription)',
              style: const TextStyle(fontSize: 12, color: Color(0xFF46534D)),
            ),
          ],
        ],
      ),
    );
  }
}
