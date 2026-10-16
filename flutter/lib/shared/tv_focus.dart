import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// D-pad / remote friendly focus ring — matches AnisFlix Android TV
/// (scale + accent border + glow fill).
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    required this.onActivate,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = 10,
    this.scale = 1.08,
    this.circle = false,
    this.fillOnFocus = true,
    this.enabled = true,
    this.onKey,
  });

  final Widget child;
  final VoidCallback onActivate;
  final bool autofocus;
  final FocusNode? focusNode;
  final double borderRadius;
  /// Leanback scale when focused (AnisFlix uses ~1.10–1.12).
  final double scale;
  final bool circle;
  final bool fillOnFocus;
  final bool enabled;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  void _activate() {
    if (!widget.enabled) return;
    widget.onActivate();
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.circle ? 999.0 : widget.borderRadius;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: widget.enabled,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (_, event) {
        final custom = widget.onKey?.call(event);
        if (custom != null && custom != KeyEventResult.ignored) return custom;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          _activate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: _activate,
        child: AnimatedScale(
          scale: _focused ? widget.scale : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              shape: widget.circle ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: widget.circle ? null : BorderRadius.circular(radius),
              color: _focused && widget.fillOnFocus
                  ? FctvColors.accent.withValues(alpha: 0.22)
                  : Colors.transparent,
              border: Border.all(
                color: _focused ? FctvColors.accent : Colors.transparent,
                width: 3,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: FctvColors.accent.withValues(alpha: 0.55),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Circular player control with AnisFlix-style TV focus highlight.
class TvFocusIconButton extends StatefulWidget {
  const TvFocusIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.focusNode,
    this.autofocus = false,
    this.primary = false,
    this.diameter,
    this.iconSize,
    this.iconColor,
    this.active = false,
    this.onKey,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool primary;
  /// Hit target diameter. Defaults: primary 48, secondary 36.
  final double? diameter;
  final double? iconSize;
  final Color? iconColor;
  /// When true, accent the icon even when unfocused (e.g. non-default aspect).
  final bool active;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  State<TvFocusIconButton> createState() => _TvFocusIconButtonState();
}

class _TvFocusIconButtonState extends State<TvFocusIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final size = widget.diameter ?? (widget.primary ? 48.0 : 36.0);
    final iconSize = widget.iconSize ?? (widget.primary ? 28.0 : 20.0);
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: Focus(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onFocusChange: (focused) => setState(() => _focused = focused),
          onKeyEvent: (_, event) {
            final custom = widget.onKey?.call(event);
            if (custom != null && custom != KeyEventResult.ignored) return custom;
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA) {
              widget.onPressed();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            onTap: widget.onPressed,
            child: AnimatedScale(
              scale: _focused ? 1.1 : 1,
              duration: const Duration(milliseconds: 120),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _focused
                      ? FctvColors.accent
                      : widget.primary
                          ? Colors.white.withValues(alpha: 0.22)
                          : Colors.black.withValues(alpha: 0.55),
                  border: Border.all(
                    color: _focused
                        ? Colors.white
                        : widget.active
                            ? FctvColors.accent
                            : Colors.white38,
                    width: _focused ? 3 : 1,
                  ),
                  boxShadow: _focused
                      ? [
                          BoxShadow(
                            color: FctvColors.accent.withValues(alpha: 0.7),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  widget.icon,
                  size: iconSize,
                  color: _focused
                      ? Colors.white
                      : widget.active
                          ? FctvColors.accent
                          : (widget.iconColor ?? Colors.white),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Selectable list row with TV focus (aspect panel, sheets, etc.).
class TvSelectableRow extends StatefulWidget {
  const TvSelectableRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
    this.leading,
    this.dense = false,
  });

  final String title;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final Widget? leading;
  /// Shorter row so a list can fit inside the inline player.
  final bool dense;

  @override
  State<TvSelectableRow> createState() => _TvSelectableRowState();
}

class _TvSelectableRowState extends State<TvSelectableRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final dense = widget.dense;
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 2 : 8),
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: (focused) => setState(() => _focused = focused),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: EdgeInsets.symmetric(horizontal: dense ? 10 : 12, vertical: dense ? 4 : 12),
            decoration: BoxDecoration(
              color: _focused
                  ? FctvColors.accent.withValues(alpha: 0.22)
                  : const Color(0xFF202329),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused
                    ? FctvColors.accent
                    : widget.selected
                        ? FctvColors.accent.withValues(alpha: 0.55)
                        : const Color(0xFF363A43),
                width: _focused ? 3 : 1,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: FctvColors.accent.withValues(alpha: 0.4),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: dense ? 13 : null,
                      color: _focused ? Colors.white : Colors.white.withValues(alpha: 0.92),
                    ),
                  ),
                ),
                if (widget.selected)
                  const Icon(Icons.check, color: FctvColors.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
