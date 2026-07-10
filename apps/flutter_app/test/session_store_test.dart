import 'dart:convert';

import 'package:datadisplay_app/src/analysis_deck.dart';
import 'package:datadisplay_app/src/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session JSON round-trips deck, grid, sources and timing', () {
    final session = WorkspaceSession(
      sourceUris: const ['ffl:///virgoData/ffl/raw.ffl'],
      gpsStartSeconds: 1464682484.0,
      durationSeconds: 60.0,
      gridColumns: 3,
      gridRows: 2,
      deck: [
        AnalysisDeckEntry(
          label: 'FFT chan.a',
          channelIds: ['chan.a'],
          spec: {
            'kind': 'fft',
            'segment_duration_s': 1.0,
            'overlap': 0.5,
            'fmin_hz': 5.0,
            'log_x': true,
          },
        ),
        AnalysisDeckEntry(
          label: 'Coherence chan.a / chan.b',
          channelIds: ['chan.a', 'chan.b'],
          spec: {'kind': 'coherence', 'segment_duration_s': 2.0},
        ),
      ],
    );

    final restored = decodeWorkspaceSession(encodeWorkspaceSession(session));

    expect(restored.sourceUris, ['ffl:///virgoData/ffl/raw.ffl']);
    expect(restored.gpsStartSeconds, 1464682484.0);
    expect(restored.durationSeconds, 60.0);
    expect(restored.gridColumns, 3);
    expect(restored.gridRows, 2);
    expect(restored.deck, hasLength(2));
    expect(restored.deck[0].label, 'FFT chan.a');
    expect(restored.deck[0].channelIds, ['chan.a']);
    expect(restored.deck[0].spec['kind'], 'fft');
    expect(restored.deck[0].spec['segment_duration_s'], 1.0);
    expect(restored.deck[0].spec['fmin_hz'], 5.0);
    expect(restored.deck[0].spec['log_x'], true);
    expect(restored.deck[1].channelIds, ['chan.a', 'chan.b']);
    expect(restored.deck[1].spec['kind'], 'coherence');
  });

  test('written JSON carries the schema header and shape', () {
    final json =
        jsonDecode(
              encodeWorkspaceSession(
                const WorkspaceSession(
                  sourceUris: ['gwf:///data/test.gwf'],
                  gpsStartSeconds: 100.0,
                  durationSeconds: 10.0,
                  gridColumns: 2,
                  gridRows: 2,
                  deck: [],
                ),
              ),
            )
            as Map<String, dynamic>;

    expect(json['version'], 1);
    expect(json['app'], 'datadisplay');
    expect(json['sources'], [
      {'uri': 'gwf:///data/test.gwf'},
    ]);
    expect(json['grid'], {'columns': 2, 'rows': 2});
    expect(json['deck'], isEmpty);
  });

  test('omits GPS window keys when no window is configured', () {
    final json =
        jsonDecode(
              encodeWorkspaceSession(
                const WorkspaceSession(
                  sourceUris: [],
                  gpsStartSeconds: null,
                  durationSeconds: null,
                  gridColumns: 1,
                  gridRows: 1,
                  deck: [],
                ),
              ),
            )
            as Map<String, dynamic>;
    expect(json.containsKey('gps_start'), isFalse);
    expect(json.containsKey('duration_s'), isFalse);
  });

  test('accepts string-typed GPS values', () {
    final session = decodeWorkspaceSession('''
{"version": 1, "app": "datadisplay", "sources": [],
 "gps_start": "1464682484.5", "duration_s": "30",
 "grid": {"columns": 2, "rows": 1}, "deck": []}
''');
    expect(session.gpsStartSeconds, 1464682484.5);
    expect(session.durationSeconds, 30.0);
  });

  test('rejects unknown versions and foreign apps without partial data', () {
    expect(
      () => decodeWorkspaceSession(
        '{"version": 2, "app": "datadisplay", "deck": [{"label": "x"}]}',
      ),
      throwsA(
        isA<SessionFormatException>().having(
          (error) => error.message,
          'message',
          contains('version'),
        ),
      ),
    );
    expect(
      () => decodeWorkspaceSession('{"version": 1, "app": "otherapp"}'),
      throwsA(isA<SessionFormatException>()),
    );
    expect(
      () => decodeWorkspaceSession('not json at all'),
      throwsA(isA<SessionFormatException>()),
    );
    expect(
      () => decodeWorkspaceSession('[1, 2, 3]'),
      throwsA(isA<SessionFormatException>()),
    );
  });

  test('round-trips the deck entry expression', () {
    final session = WorkspaceSession(
      sourceUris: const [],
      gpsStartSeconds: null,
      durationSeconds: null,
      gridColumns: 2,
      gridRows: 2,
      deck: [
        AnalysisDeckEntry(
          label: 'FFT combined',
          channelIds: ['chan.a', 'chan.b'],
          spec: {'kind': 'fft', 'segment_duration_s': 1.0},
          expression: 'ch0 - 2*ch1',
        ),
        AnalysisDeckEntry(
          label: 'Time chan.a',
          channelIds: ['chan.a'],
          spec: {'kind': 'time'},
        ),
      ],
    );

    final restored = decodeWorkspaceSession(encodeWorkspaceSession(session));
    expect(restored.deck[0].expression, 'ch0 - 2*ch1');
    expect(restored.deck[1].expression, isNull);
  });

  test('round-trips reference and live-refresh state', () {
    final session = WorkspaceSession(
      sourceUris: const [],
      gpsStartSeconds: null,
      durationSeconds: null,
      gridColumns: 2,
      gridRows: 2,
      deck: const [],
      references: const [
        SessionReference(
          path: '/data/refs/darm.ddref.json',
          colorIndex: 3,
          visible: false,
        ),
      ],
      live: const SessionLiveConfig(
        enabled: true,
        intervalSeconds: 30,
        followNow: false,
      ),
    );

    final restored = decodeWorkspaceSession(encodeWorkspaceSession(session));
    expect(restored.references, hasLength(1));
    expect(restored.references.single.path, '/data/refs/darm.ddref.json');
    expect(restored.references.single.colorIndex, 3);
    expect(restored.references.single.visible, isFalse);
    expect(restored.live.enabled, isTrue);
    expect(restored.live.intervalSeconds, 30);
    expect(restored.live.followNow, isFalse);
  });

  test('old v1 sessions without references/live decode with defaults', () {
    final session = decodeWorkspaceSession('''
{"version": 1, "app": "datadisplay", "sources": [],
 "grid": {"columns": 2, "rows": 2}, "deck": []}
''');
    expect(session.references, isEmpty);
    expect(session.live.enabled, isFalse);
    expect(session.live.intervalSeconds, 10);
    expect(session.live.followNow, isTrue);
  });

  test('derives the autosave path from the environment', () {
    expect(
      defaultSessionAutosavePath(
        const {'XDG_STATE_HOME': '/tmp/state', 'HOME': '/home/user'},
        isWindows: false,
      ),
      '/tmp/state/datadisplay/last_session.json',
    );
    expect(
      defaultSessionAutosavePath(const {
        'HOME': '/home/user',
      }, isWindows: false),
      '/home/user/.local/state/datadisplay/last_session.json',
    );
    expect(
      defaultSessionAutosavePath(const {}, isWindows: false),
      isNull,
    );
    expect(
      defaultSessionAutosavePath(
        const {'APPDATA': r'C:\Users\user\AppData\Roaming'},
        isWindows: true,
      ),
      r'C:\Users\user\AppData\Roaming\datadisplay\last_session.json',
    );
  });
}
