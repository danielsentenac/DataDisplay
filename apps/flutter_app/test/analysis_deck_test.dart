import 'package:datadisplay_app/src/analysis_deck.dart';
import 'package:datadisplay_app/src/datadisplay_backend.dart';
import 'package:datadisplay_app/src/plot_scene.dart';
import 'package:datadisplay_app/src/scene_plot_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake backend whose plot() returns a small single-line figure titled after
/// the requested spec kind and channel.
class _FakePlotBackend implements DatadisplayBackendClient {
  @override
  Future<PlotFigure> plot({
    required List<PlotChannelRef> channels,
    required TimeRange timeRange,
    required Map<String, Object?> spec,
    String? expression,
    bool allowGaps = false,
  }) async {
    final title = '${spec['kind']} ${channels.first.channelId}';
    return PlotFigure(
      title: title,
      scenes: [
        PlotSceneData(
          title: title,
          plotKind: 'line1d',
          xAxis: const PlotAxis(
            label: 'Frequency',
            unit: 'Hz',
            logScale: false,
            rangeMin: null,
            rangeMax: null,
          ),
          yAxis: const PlotAxis(
            label: 'ASD',
            unit: null,
            logScale: false,
            rangeMin: null,
            rangeMax: null,
          ),
          zAxis: null,
          epochNs: null,
          timeRange: timeRange,
          layers: const [
            LinePlotLayer(
              label: 'trace',
              xs: [1.0, 2.0, 3.0],
              ys: [0.5, 1.0, 0.25],
              colorRgba: [0.1, 0.45, 0.95, 1.0],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<OpenedSource> openSource(String uri) => throw UnimplementedError();

  @override
  Future<void> closeSource(int sourceId) => throw UnimplementedError();

  @override
  Future<CatalogPage> catalog({
    required int sourceId,
    String? text,
    List<String> tags = const [],
    int offset = 0,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<DataBlock> read({
    required int sourceId,
    required String channelId,
    required TimeRange timeRange,
    required ReadAggregation aggregation,
    int? maxPoints,
    bool allowGaps = false,
  }) => throw UnimplementedError();

  @override
  void dispose() {}
}

void main() {
  testWidgets('deck grid renders one cell per entry with computed figures', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final backend = _FakePlotBackend();
    const timeRange = TimeRange(startNs: 0, endNs: 1000000000);

    final entryA = AnalysisDeckEntry(
      label: 'FFT chan.a',
      channelIds: ['chan.a'],
      spec: {'kind': 'fft', 'segment_duration_s': 1.0},
    );
    final entryB = AnalysisDeckEntry(
      label: 'Time chan.b',
      channelIds: ['chan.b'],
      spec: {'kind': 'time'},
    );

    entryA.figure = await backend.plot(
      channels: const [PlotChannelRef(sourceId: 1, channelId: 'chan.a')],
      timeRange: timeRange,
      spec: entryA.spec,
    );
    entryB.figure = await backend.plot(
      channels: const [PlotChannelRef(sourceId: 1, channelId: 'chan.b')],
      timeRange: timeRange,
      spec: entryB.spec,
    );

    final moves = <(int, int)>[];
    final removed = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnalysisDeckGrid(
              entries: [entryA, entryB],
              columns: 2,
              rows: 2,
              onRecompute: (_) {},
              onEdit: (_) {},
              onMove: (index, delta) => moves.add((index, delta)),
              onRemove: removed.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('FFT chan.a'), findsOneWidget);
    expect(find.text('Time chan.b'), findsOneWidget);
    expect(find.byType(ScenePlotView), findsNWidgets(2));

    // First cell can only move down, last only up.
    await tester.tap(find.byTooltip('Move down').first);
    expect(moves, [(0, 1)]);

    await tester.tap(find.byTooltip('Remove').last);
    expect(removed, [1]);
  });

  testWidgets('deck grid shows placeholder and error states', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final pending = AnalysisDeckEntry(
      label: 'BRMS chan.a',
      channelIds: ['chan.a'],
      spec: {'kind': 'brms', 'fmin_hz': 1.0, 'fmax_hz': 100.0},
    );
    final failed = AnalysisDeckEntry(
      label: 'Coherence chan.a / chan.b',
      channelIds: ['chan.a', 'chan.b'],
      spec: {'kind': 'coherence'},
    )..error = 'coherence plot needs exactly 2 channel(s), got 1';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AnalysisDeckGrid(
              entries: [pending, failed],
              columns: 1,
              rows: 3,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Not computed yet.'), findsOneWidget);
    expect(
      find.text('coherence plot needs exactly 2 channel(s), got 1'),
      findsOneWidget,
    );
  });

  group('DeckXZoom', () {
    test('shares viewports per normalized x unit', () {
      final zoom = DeckXZoom();
      expect(zoom.isEmpty, isTrue);

      expect(zoom.setRange('Hz', 10.0, 100.0), isTrue);
      // Same unit up to case/whitespace -> same shared viewport.
      expect(zoom.viewportFor('Hz'), (10.0, 100.0));
      expect(zoom.viewportFor(' hz '), (10.0, 100.0));
      // A different unit is not affected.
      expect(zoom.viewportFor('s'), isNull);
      expect(zoom.viewportFor(null), isNull);

      expect(zoom.setRange('s', 0.0, 2.0), isTrue);
      expect(zoom.viewportFor('s'), (0.0, 2.0));
      expect(zoom.isNotEmpty, isTrue);

      zoom.clear('HZ');
      expect(zoom.viewportFor('Hz'), isNull);
      expect(zoom.viewportFor('s'), (0.0, 2.0));

      zoom.clearAll();
      expect(zoom.isEmpty, isTrue);
    });

    test('rejects degenerate or non-finite ranges', () {
      final zoom = DeckXZoom();
      expect(zoom.setRange('Hz', 5.0, 5.0), isFalse);
      expect(zoom.setRange('Hz', 10.0, 1.0), isFalse);
      expect(zoom.setRange('Hz', double.nan, 1.0), isFalse);
      expect(zoom.setRange('Hz', 0.0, double.infinity), isFalse);
      expect(zoom.isEmpty, isTrue);
    });

    test('null and empty units share one viewport', () {
      final zoom = DeckXZoom();
      zoom.setRange(null, 1.0, 2.0);
      expect(zoom.viewportFor(''), (1.0, 2.0));
      expect(zoom.viewportFor(null), (1.0, 2.0));
    });
  });
}
