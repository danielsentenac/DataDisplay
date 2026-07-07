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

class WorkspaceSession {
  const WorkspaceSession({
    required this.sourceUris,
    required this.gpsStartSeconds,
    required this.durationSeconds,
    required this.gridColumns,
    required this.gridRows,
    required this.deck,
  });

  final List<String> sourceUris;
  final double? gpsStartSeconds;
  final double? durationSeconds;
  final int gridColumns;
  final int gridRows;

  /// Fresh entries (no computed figures); safe to hand to the controller.
  final List<AnalysisDeckEntry> deck;

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
          },
      ],
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
