// instrument_dock.dart
//
// The signature element of the UI: a floating "instrument tray". Reading shows a
// compact capsule; tapping it fans out the instruments. Selecting a marking tool
// lifts it and reveals an inline color + stroke rail. Drives AnnotationController.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'annotation_overlay.dart';
import '../theme/app_theme.dart';

class InstrumentDock extends StatefulWidget {
  final AnnotationController controller;
  const InstrumentDock({super.key, required this.controller});

  @override
  State<InstrumentDock> createState() => _InstrumentDockState();
}

class _InstrumentDockState extends State<InstrumentDock> {
  bool _expanded = true;

  static const List<(AnnotationTool, IconData, String)> _tools =
      <(AnnotationTool, IconData, String)>[
    (AnnotationTool.none, Icons.pan_tool_alt, 'Pan'),
    (AnnotationTool.ink, Icons.draw, 'Pen'),
    (AnnotationTool.highlight, Icons.highlight, 'Highlight'),
    (AnnotationTool.rectangle, Icons.crop_square, 'Rectangle'),
    (AnnotationTool.ellipse, Icons.circle_outlined, 'Ellipse'),
    (AnnotationTool.line, Icons.horizontal_rule, 'Line'),
    (AnnotationTool.note, Icons.sticky_note_2_outlined, 'Note'),
    (AnnotationTool.erase, Icons.delete_outline, 'Erase'),
  ];

  static const List<double> _strokes = <double>[2.0, 4.0, 7.0];

  bool get _isMarking {
    final t = widget.controller.tool;
    return t != AnnotationTool.none && t != AnnotationTool.erase;
  }

  IconData _iconFor(AnnotationTool tool) =>
      _tools.firstWhere((e) => e.$1 == tool).$2;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = (isDark ? AppColors.slateSurface : Colors.white)
        .withValues(alpha: 0.92);
    final border = isDark ? AppColors.slateLine : AppColors.hairline;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: border),
                boxShadow: [
                  BoxShadow(
                    color: (isDark ? Colors.black : AppColors.ink)
                        .withValues(alpha: isDark ? 0.45 : 0.16),
                    blurRadius: 28,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: _expanded
                    ? _fullTray(scheme, border)
                    : _capsule(scheme),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _gripRow(ColorScheme scheme) {
    final c = widget.controller;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _miniButton(Icons.undo, c.canUndo, scheme, c.undo, 'Undo'),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = false),
              child: Container(
                height: 22,
                alignment: Alignment.center,
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
          _miniButton(Icons.redo, c.canRedo, scheme, c.redo, 'Redo'),
        ],
      ),
    );
  }

  Widget _miniButton(IconData icon, bool enabled, ColorScheme scheme,
      VoidCallback onTap, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 32,
          height: 24,
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? scheme.onSurfaceVariant
                : scheme.onSurfaceVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }

  Widget _capsule(ColorScheme scheme) {
    final tool = widget.controller.tool;
    return InkWell(
      onTap: () => setState(() => _expanded = true),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconFor(tool), size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              _tools.firstWhere((e) => e.$1 == tool).$3,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                  color: scheme.onSurface),
            ),
            const SizedBox(width: 6),
            Icon(Icons.keyboard_arrow_up,
                size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _fullTray(ColorScheme scheme, Color border) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _gripRow(scheme),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (tool, icon, label) in _tools)
                _ToolButton(
                  icon: icon,
                  label: label,
                  selected: widget.controller.tool == tool,
                  accent: scheme.primary,
                  rest: scheme.onSurfaceVariant,
                  onTap: () => widget.controller.tool = tool,
                ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: _isMarking
                ? _rail(scheme, border)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _rail(ColorScheme scheme, Color border) {
    final current = widget.controller.colorArgb;
    final stroke = widget.controller.strokeWidth;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          for (final argb in AppColors.markerPalette)
            _Swatch(
              argb: argb,
              selected: current == argb,
              ring: scheme.primary,
              gap: scheme.surface,
              onTap: () => widget.controller.colorArgb = argb,
            ),
          const Spacer(),
          for (final w in _strokes)
            _StrokeDot(
              width: w,
              selected: (stroke - w).abs() < 0.5,
              accent: scheme.primary,
              rest: scheme.onSurfaceVariant,
              onTap: () => widget.controller.strokeWidth = w,
            ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final Color rest;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.rest,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          width: 32,
          height: 36,
          transform: Matrix4.translationValues(0, selected ? -4 : 0, 0),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.24),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Icon(icon, size: 19, color: selected ? accent : rest),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final int argb;
  final bool selected;
  final Color ring;
  final Color gap;
  final VoidCallback onTap;

  const _Swatch({
    required this.argb,
    required this.selected,
    required this.ring,
    required this.gap,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ring : Colors.transparent,
            width: 2,
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            color: Color(argb),
            shape: BoxShape.circle,
            border: Border.all(color: gap, width: 0.5),
          ),
        ),
      ),
    );
  }
}

class _StrokeDot extends StatelessWidget {
  final double width;
  final bool selected;
  final Color accent;
  final Color rest;
  final VoidCallback onTap;

  const _StrokeDot({
    required this.width,
    required this.selected,
    required this.accent,
    required this.rest,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final d = 4.0 + width; // visual size tracks stroke weight
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: SizedBox(
          width: 18,
          height: 26,
          child: Center(
            child: Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                color: selected ? accent : rest,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
