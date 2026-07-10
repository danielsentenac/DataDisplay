import 'dart:convert';

import 'package:flutter/material.dart';

import 'plot_scene.dart';

/// Reference plots: frozen line figures (schema v1, kind "reference") that
/// can be superposed on later computed plots for comparison — the original
/// tool's "Ref Plots" workflow.

const referenceSchemaVersion = 1;

/// Small palette cycled/chosen per reference (distinct from the trace
/// colors the engine assigns to live curves).
const referencePalette = <Color>[
  Color(0xFF7B1FA2),
  Color(0xFFD81B60),
  Color(0xFF00838F),
  Color(0xFF5D4037),
  Color(0xFF455A64),
  Color(0xFFEF6C00),
  Color(0xFF2E7D32),
  Color(0xFF283593),
];

class ReferenceFormatException implements Exception {
  ReferenceFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A reference figure loaded into the workspace, plus its display state.
class LoadedReference {
  LoadedReference({
    required this.filePath,
    required this.title,
    required this.savedAt,
    required this.scenes,
    this.colorIndex = 0,
    this.visible = true,
  });

  final String filePath;
  final String title;
  final String? savedAt;
  final List<PlotSceneData> scenes;

  int colorIndex;
  bool visible;

  Color get color => referencePalette[colorIndex % referencePalette.length];
}

/// Returns a user-facing message when the figure cannot be saved as a
/// reference (only line scenes are supported), or null when it can.
String? referenceSaveBlocker(List<PlotSceneData> scenes) {
  if (scenes.isEmpty) {
    return 'The figure has no scenes to save as a reference.';
  }
  for (final scene in scenes) {
    if (scene.plotKind != 'line1d') {
      return 'Only line plots can be saved as references — '
          '`${scene.plotKind}` scenes (e.g. spectrograms) are not supported.';
    }
  }
  return null;
}

String encodeReferenceFigure({
  required String title,
  required String savedAt,
  required List<PlotSceneData> scenes,
}) {
  return const JsonEncoder.withIndent('  ').convert({
    'version': referenceSchemaVersion,
    'app': 'datadisplay',
    'kind': 'reference',
    'title': title,
    'saved_at': savedAt,
    'scenes': [for (final scene in scenes) scene.toJson()],
  });
}

LoadedReference decodeReferenceFigure(String text, {required String filePath}) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw ReferenceFormatException(
      'Reference file is not valid JSON: $error',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw ReferenceFormatException(
      'Reference file must contain a JSON object.',
    );
  }
  if (decoded['app'] != 'datadisplay' || decoded['kind'] != 'reference') {
    throw ReferenceFormatException(
      'Not a datadisplay reference file '
      '(app: `${decoded['app']}`, kind: `${decoded['kind']}`).',
    );
  }
  if (decoded['version'] != referenceSchemaVersion) {
    throw ReferenceFormatException(
      'Unsupported reference version `${decoded['version']}` '
      '(this build reads version $referenceSchemaVersion).',
    );
  }

  return LoadedReference(
    filePath: filePath,
    title: decoded['title'] as String? ?? '',
    savedAt: decoded['saved_at'] as String?,
    scenes: [
      for (final scene in decoded['scenes'] as List<dynamic>? ?? const [])
        PlotSceneData.fromJson(scene as Map<String, dynamic>),
    ],
  );
}

/// A reference trace ready to superpose on a scene (drawn dashed in the
/// reference's override color).
class ReferenceTrace {
  const ReferenceTrace({
    required this.label,
    required this.xs,
    required this.ys,
    required this.color,
  });

  final String label;
  final List<double> xs;
  final List<double> ys;
  final Color color;
}

/// Collects the traces of every visible reference that is compatible with
/// `scene`: the target must be a line scene with the same x-axis unit
/// (s vs Hz); log/lin character does not matter — the axes adapt.
List<ReferenceTrace> compatibleReferenceTraces(
  List<LoadedReference> references,
  PlotSceneData scene,
) {
  if (scene.plotKind != 'line1d') {
    return const [];
  }
  final targetUnit = _normalizedUnit(scene.xAxis.unit);
  final traces = <ReferenceTrace>[];
  for (final reference in references) {
    if (!reference.visible) {
      continue;
    }
    for (final referenceScene in reference.scenes) {
      if (referenceScene.plotKind != 'line1d' ||
          _normalizedUnit(referenceScene.xAxis.unit) != targetUnit) {
        continue;
      }
      for (final layer in referenceScene.lineLayers) {
        final baseLabel = layer.label.isEmpty ? reference.title : layer.label;
        traces.add(
          ReferenceTrace(
            label: '$baseLabel (ref)',
            xs: layer.xs,
            ys: layer.ys,
            color: reference.color,
          ),
        );
      }
    }
  }
  return traces;
}

String _normalizedUnit(String? unit) => (unit ?? '').trim().toLowerCase();
