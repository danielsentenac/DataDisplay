import 'dart:convert';

import 'analysis_deck.dart';

/// Versioned workspace-session persistence (schema v1):
/// sources, GPS window, analysis pad grid and deck entries.

const sessionSchemaVersion = 1;
const sessionAppName = 'datadisplay';

class SessionFormatException implements Exception {
  SessionFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reference-plot display state persisted with the session (the figure
/// itself stays in its own `.ddref.json` file, referenced by path).
class SessionReference {
  const SessionReference({
    required this.path,
    required this.colorIndex,
    required this.visible,
  });

  final String path;
  final int colorIndex;
  final bool visible;

  Map<String, Object?> toJson() => {
    'path': path,
    'color': colorIndex,
    'visible': visible,
  };

  factory SessionReference.fromJson(Map<String, dynamic> json) {
    return SessionReference(
      path: json['path'] as String? ?? '',
      colorIndex: (json['color'] as num?)?.toInt() ?? 0,
      visible: json['visible'] as bool? ?? true,
    );
  }
}

/// Live deck-refresh state persisted with the session.
class SessionLiveConfig {
  const SessionLiveConfig({
    this.enabled = false,
    this.intervalSeconds = 10,
    this.followNow = true,
  });

  final bool enabled;
  final int intervalSeconds;
  final bool followNow;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'interval_s': intervalSeconds,
    'follow_now': followNow,
  };

  factory SessionLiveConfig.fromJson(Map<String, dynamic> json) {
    return SessionLiveConfig(
      enabled: json['enabled'] as bool? ?? false,
      intervalSeconds: (json['interval_s'] as num?)?.toInt() ?? 10,
      followNow: json['follow_now'] as bool? ?? true,
    );
  }
}

class WorkspaceSession {
  const WorkspaceSession({
    required this.sourceUris,
    required this.gpsStartSeconds,
    required this.durationSeconds,
    required this.gridColumns,
    required this.gridRows,
    required this.deck,
    this.references = const [],
    this.live = const SessionLiveConfig(),
  });

  final List<String> sourceUris;
  final double? gpsStartSeconds;
  final double? durationSeconds;
  final int gridColumns;
  final int gridRows;

  /// Fresh entries (no computed figures); safe to hand to the controller.
  final List<AnalysisDeckEntry> deck;

  /// Additive optional fields (absent in early v1 sessions).
  final List<SessionReference> references;
  final SessionLiveConfig live;

  Map<String, Object?> toJson() {
    return {
      'version': sessionSchemaVersion,
      'app': sessionAppName,
      'sources': [
        for (final uri in sourceUris) {'uri': uri},
      ],
      'gps_start': ?gpsStartSeconds,
      'duration_s': ?durationSeconds,
      'grid': {'columns': gridColumns, 'rows': gridRows},
      'deck': [
        for (final entry in deck)
          {
            'label': entry.label,
            'channels': entry.channelIds,
            'spec': entry.spec,
            'expression': ?entry.expression,
          },
      ],
      if (references.isNotEmpty)
        'references': [
          for (final reference in references) reference.toJson(),
        ],
      'live': live.toJson(),
    };
  }

  factory WorkspaceSession.fromJson(Map<String, dynamic> json) {
    final app = json['app'];
    if (app != sessionAppName) {
      throw SessionFormatException(
        'Not a $sessionAppName session file (app: `$app`).',
      );
    }
    final version = json['version'];
    if (version != sessionSchemaVersion) {
      throw SessionFormatException(
        'Unsupported session version `$version` '
        '(this build reads version $sessionSchemaVersion).',
      );
    }

    final grid = json['grid'] as Map<String, dynamic>? ?? const {};
    return WorkspaceSession(
      sourceUris: [
        for (final source in json['sources'] as List<dynamic>? ?? const [])
          if (source is Map && source['uri'] is String)
            source['uri'] as String,
      ],
      gpsStartSeconds: _asDouble(json['gps_start']),
      durationSeconds: _asDouble(json['duration_s']),
      gridColumns: (grid['columns'] as num?)?.toInt() ?? 2,
      gridRows: (grid['rows'] as num?)?.toInt() ?? 2,
      deck: [
        for (final raw in json['deck'] as List<dynamic>? ?? const [])
          _deckEntryFromJson(raw),
      ],
      references: [
        for (final raw in json['references'] as List<dynamic>? ?? const [])
          if (raw is Map)
            SessionReference.fromJson(Map<String, dynamic>.from(raw)),
      ],
      live: json['live'] is Map
          ? SessionLiveConfig.fromJson(
              Map<String, dynamic>.from(json['live'] as Map),
            )
          : const SessionLiveConfig(),
    );
  }
}

AnalysisDeckEntry _deckEntryFromJson(Object? raw) {
  final json = raw is Map
      ? Map<String, dynamic>.from(raw)
      : const <String, dynamic>{};
  return AnalysisDeckEntry(
    label: json['label'] as String? ?? '',
    channelIds: [
      for (final channel in json['channels'] as List<dynamic>? ?? const [])
        channel.toString(),
    ],
    spec: json['spec'] is Map
        ? Map<String, Object?>.from(json['spec'] as Map)
        : <String, Object?>{},
    expression: json['expression'] as String?,
  );
}

String encodeWorkspaceSession(WorkspaceSession session) {
  return const JsonEncoder.withIndent('  ').convert(session.toJson());
}

WorkspaceSession decodeWorkspaceSession(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw SessionFormatException('Session file is not valid JSON: $error');
  }
  if (decoded is! Map<String, dynamic>) {
    throw SessionFormatException('Session file must contain a JSON object.');
  }
  return WorkspaceSession.fromJson(decoded);
}

/// Per-user autosave location for `last_session.json`, derived from the
/// process environment (no extra packages):
/// `$XDG_STATE_HOME/datadisplay/` or `$HOME/.local/state/datadisplay/` on
/// Linux/macOS, `%APPDATA%\datadisplay\` on Windows.
String? defaultSessionAutosavePath(
  Map<String, String> environment, {
  required bool isWindows,
}) {
  if (isWindows) {
    final appData = environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      return null;
    }
    return '$appData\\datadisplay\\last_session.json';
  }
  final stateHome = environment['XDG_STATE_HOME'];
  final base = stateHome != null && stateHome.isNotEmpty
      ? stateHome
      : () {
          final home = environment['HOME'];
          return home == null || home.isEmpty ? null : '$home/.local/state';
        }();
  if (base == null) {
    return null;
  }
  return '$base/datadisplay/last_session.json';
}

double? _asDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}
