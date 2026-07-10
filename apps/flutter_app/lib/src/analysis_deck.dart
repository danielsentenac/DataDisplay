import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'plot_scene.dart';
import 'reference_plots.dart';
import 'scene_plot_view.dart';

/// A saved analysis configuration plus its latest computed result.
///
/// Channel ids are stored (not source ids) so entries stay valid when the
/// source is reopened; the caller resolves the source id at compute time.
class AnalysisDeckEntry {
  AnalysisDeckEntry({
    required this.label,
    required this.channelIds,
    required this.spec,
    this.expression,
  });

  String label;
  List<String> channelIds;
  Map<String, Object?> spec;

  /// Optional request-level channel maths (`ch0 - 2*ch1`), stored alongside
  /// the spec like the channel ids.
  String? expression;

  PlotFigure? figure;
  String? error;
  bool computing = false;
}

/// Shared x-axis zoom state for the deck: one viewport per x-axis unit so
/// cells with the same unit (s, Hz, ...) zoom together. Pure view state —
/// zooming never recomputes; drawing is clipped to the range.
class DeckXZoom {
  final Map<String, (double, double)> _byUnit = {};

  static String _normalize(String? unit) => (unit ?? '').trim().toLowerCase();

  (double, double)? viewportFor(String? unit) => _byUnit[_normalize(unit)];

  /// Returns false (and stores nothing) for degenerate or non-finite ranges.
  bool setRange(String? unit, double xMin, double xMax) {
    if (!xMin.isFinite || !xMax.isFinite || xMax <= xMin) {
      return false;
    }
    _byUnit[_normalize(unit)] = (xMin, xMax);
    return true;
  }

  void clear(String? unit) => _byUnit.remove(_normalize(unit));

  void clearAll() => _byUnit.clear();

  bool get isEmpty => _byUnit.isEmpty;
  bool get isNotEmpty => _byUnit.isNotEmpty;
}

/// The original tool's multi-pad canvas: deck entries laid out in a
/// `columns` wide grid; `rows` only controls the cell height so overflowing
/// entries wrap into additional rows.
class AnalysisDeckGrid extends StatelessWidget {
  const AnalysisDeckGrid({
    super.key,
    required this.entries,
    required this.columns,
    required this.rows,
    this.references = const [],
    this.fitReferences = false,
    this.xZoom,
    this.onRecompute,
    this.onEdit,
    this.onMove,
    this.onRemove,
    this.onSaveReference,
    this.onXZoom,
    this.onUnzoomUnits,
  });

  final List<AnalysisDeckEntry> entries;
  final int columns;
  final int rows;

  /// Loaded reference figures superposed on compatible cell scenes.
  final List<LoadedReference> references;
  final bool fitReferences;

  /// Shared per-unit x zoom; cells whose scene x unit has a stored viewport
  /// render zoomed, and brush selections report through [onXZoom].
  final DeckXZoom? xZoom;
  final ValueChanged<int>? onRecompute;
  final ValueChanged<int>? onEdit;

  /// `onMove(index, delta)` with delta -1 (up) or +1 (down).
  final void Function(int index, int delta)? onMove;
  final ValueChanged<int>? onRemove;
  final ValueChanged<int>? onSaveReference;
  final void Function(String? unit, double xMin, double xMax)? onXZoom;

  /// Per-cell unzoom: called with the x units of that cell's scenes.
  final ValueChanged<Set<String?>>? onUnzoomUnits;

  double get _cellHeight {
    switch (rows) {
      case 1:
        return 430;
      case 2:
        return 340;
      default:
        return 270;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'The deck is empty. Configure a plot above and press "Add to deck".',
          style: TextStyle(
            color: Color(0xFF5C6963),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: entries.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: math.max(1, columns),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        mainAxisExtent: _cellHeight,
      ),
      itemBuilder: (context, index) => _AnalysisDeckCell(
        entry: entries[index],
        references: references,
        fitReferences: fitReferences,
        xZoom: xZoom,
        onXZoom: onXZoom,
        onUnzoomUnits: onUnzoomUnits,
        onRecompute: onRecompute == null ? null : () => onRecompute!(index),
        onEdit: onEdit == null ? null : () => onEdit!(index),
        onMoveUp: onMove == null || index == 0
            ? null
            : () => onMove!(index, -1),
        onMoveDown: onMove == null || index == entries.length - 1
            ? null
            : () => onMove!(index, 1),
        onRemove: onRemove == null ? null : () => onRemove!(index),
        onSaveReference: onSaveReference == null
            ? null
            : () => onSaveReference!(index),
      ),
    );
  }
}

class _AnalysisDeckCell extends StatelessWidget {
  const _AnalysisDeckCell({
    required this.entry,
    required this.references,
    required this.fitReferences,
    required this.xZoom,
    required this.onXZoom,
    required this.onUnzoomUnits,
    required this.onRecompute,
    required this.onEdit,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
    required this.onSaveReference,
  });

  final AnalysisDeckEntry entry;
  final List<LoadedReference> references;
  final bool fitReferences;
  final DeckXZoom? xZoom;
  final void Function(String? unit, double xMin, double xMax)? onXZoom;
  final ValueChanged<Set<String?>>? onUnzoomUnits;
  final VoidCallback? onRecompute;
  final VoidCallback? onEdit;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onRemove;
  final VoidCallback? onSaveReference;

  Set<String?> get _sceneUnits => {
    for (final scene in entry.figure?.scenes ?? const <PlotSceneData>[])
      scene.xAxis.unit,
  };

  bool get _hasActiveZoom {
    final zoom = xZoom;
    if (zoom == null) {
      return false;
    }
    return _sceneUnits.any((unit) => zoom.viewportFor(unit) != null);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE0E6E1)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF1F2925),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (entry.computing)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              _cellAction(
                icon: Icons.refresh_rounded,
                tooltip: 'Recompute',
                onPressed: entry.computing ? null : onRecompute,
              ),
              _cellAction(
                icon: Icons.bookmark_add_rounded,
                tooltip: 'Save as reference',
                onPressed: entry.figure == null ? null : onSaveReference,
              ),
              _cellAction(
                icon: Icons.zoom_out_map_rounded,
                tooltip: 'Unzoom',
                onPressed: _hasActiveZoom && onUnzoomUnits != null
                    ? () => onUnzoomUnits!(_sceneUnits)
                    : null,
              ),
              _cellAction(
                icon: Icons.edit_rounded,
                tooltip: 'Edit parameters',
                onPressed: onEdit,
              ),
              _cellAction(
                icon: Icons.arrow_upward_rounded,
                tooltip: 'Move up',
                onPressed: onMoveUp,
              ),
              _cellAction(
                icon: Icons.arrow_downward_rounded,
                tooltip: 'Move down',
                onPressed: onMoveDown,
              ),
              _cellAction(
                icon: Icons.close_rounded,
                tooltip: 'Remove',
                onPressed: onRemove,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(child: _cellBody()),
        ],
      ),
    );
  }

  Widget _cellBody() {
    final error = entry.error;
    if (error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: SelectableText(
          error,
          style: const TextStyle(
            color: Color(0xFF6A241E),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    final figure = entry.figure;
    if (figure == null || figure.scenes.isEmpty) {
      return const Center(
        child: Text(
          'Not computed yet.',
          style: TextStyle(
            color: Color(0xFF5C6963),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final scene in figure.scenes) ...[
          Expanded(
            child: ScenePlotView(
              scene: scene,
              references: compatibleReferenceTraces(references, scene),
              fitReferences: fitReferences,
              xViewport: xZoom?.viewportFor(scene.xAxis.unit),
              onXZoom: onXZoom == null
                  ? null
                  : (xMin, xMax) => onXZoom!(scene.xAxis.unit, xMin, xMax),
            ),
          ),
          if (scene != figure.scenes.last) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _cellAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      visualDensity: VisualDensity.compact,
      color: const Color(0xFF51605A),
    );
  }
}
