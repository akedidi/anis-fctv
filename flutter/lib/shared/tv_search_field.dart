import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import 'tv_focus.dart';

/// Home route uses this to swallow Back while the letter pad is open.
class TvSearchPadLink extends ChangeNotifier {
  VoidCallback? _close;

  bool get isOpen => _close != null;

  void bind(VoidCallback? close) {
    if (_close == close) return;
    _close = close;
    notifyListeners();
  }

  void close() => _close?.call();
}

/// Android TV search — no [TextField] (it traps D-pad). Focusable chip + letter pad.
class TvSearchField extends StatefulWidget {
  const TvSearchField({
    super.key,
    required this.controller,
    this.hint = 'Search teams, leagues…',
    this.padLink,
  });

  final TextEditingController controller;
  final String hint;
  final TvSearchPadLink? padLink;

  @override
  State<TvSearchField> createState() => _TvSearchFieldState();
}

class _TvSearchFieldState extends State<TvSearchField> {
  final _chipFocus = FocusNode(debugLabel: 'tv search chip');
  bool _padOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _chipFocus.dispose();
    super.dispose();
  }

  void _append(String ch) {
    final t = widget.controller.text;
    widget.controller.value = TextEditingValue(
      text: t + ch,
      selection: TextSelection.collapsed(offset: t.length + ch.length),
    );
  }

  void _backspace() {
    final t = widget.controller.text;
    if (t.isEmpty) return;
    widget.controller.value = TextEditingValue(
      text: t.substring(0, t.length - 1),
      selection: TextSelection.collapsed(offset: t.length - 1),
    );
  }

  void _clear() {
    widget.controller.clear();
  }

  void _openPad() {
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    setState(() => _padOpen = true);
    widget.padLink?.bind(_closePad);
  }

  void _closePad({bool refocusChip = true}) {
    if (!_padOpen) return;
    setState(() => _padOpen = false);
    widget.padLink?.bind(null);
    if (refocusChip) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _chipFocus.requestFocus();
      });
    }
  }

  KeyEventResult _onChipKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Leave search with D-pad — never trap arrows on this control.
    final dir = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (dir != null) {
      final moved = node.focusInDirection(dir);
      return moved ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.browserBack) {
      if (_padOpen) {
        _closePad(refocusChip: false);
        node.unfocus();
        return KeyEventResult.handled;
      }
      if (widget.controller.text.isNotEmpty) {
        _clear();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA) {
      if (_padOpen) {
        _closePad();
      } else {
        _openPad();
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }

    final ch = event.character;
    if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32) {
      _append(ch);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final empty = text.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          focusNode: _chipFocus,
          onKeyEvent: _onChipKey,
          child: Builder(
            builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return GestureDetector(
                onTap: () {
                  _chipFocus.requestFocus();
                  _openPad();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: focused ? FctvColors.accent : Colors.transparent,
                      width: focused ? 2 : 0,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search_rounded, size: 20, color: FctvColors.textMuted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          empty ? widget.hint : text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: empty ? FctvColors.textMuted : Colors.white,
                            fontSize: 14,
                            fontWeight: empty ? FontWeight.w500 : FontWeight.w700,
                          ),
                        ),
                      ),
                      if (!empty)
                        GestureDetector(
                          onTap: _clear,
                          child: const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(Icons.close_rounded, size: 18, color: FctvColors.textMuted),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (_padOpen) ...[
          const SizedBox(height: 8),
          Focus(
            skipTraversal: true,
            canRequestFocus: false,
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.goBack ||
                  event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.browserBack) {
                _closePad();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: _TvLetterPad(
              onChar: _append,
              onSpace: () => _append(' '),
              onBackspace: _backspace,
              onClear: _clear,
              onDone: _closePad,
            ),
          ),
        ],
      ],
    );
  }
}

class _TvLetterPad extends StatelessWidget {
  const _TvLetterPad({
    required this.onChar,
    required this.onSpace,
    required this.onBackspace,
    required this.onClear,
    required this.onDone,
  });

  final ValueChanged<String> onChar;
  final VoidCallback onSpace;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onDone;

  static const _rows = [
    'ABCDEFGHI',
    'JKLMNOPQR',
    'STUVWXYZ0',
  ];

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: FctvColors.surfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          children: [
            for (var r = 0; r < _rows.length; r++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    for (var i = 0; i < _rows[r].length; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: TvFocusable(
                            autofocus: r == 0 && i == 0,
                            onActivate: () => onChar(_rows[r][i].toLowerCase()),
                            borderRadius: 8,
                            scale: 1.1,
                            child: Container(
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _rows[r][i],
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TvFocusable(
                    onActivate: onSpace,
                    borderRadius: 8,
                    scale: 1.08,
                    child: Container(
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Space', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TvFocusable(
                    onActivate: onBackspace,
                    borderRadius: 8,
                    scale: 1.08,
                    child: Container(
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.backspace_outlined, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TvFocusable(
                    onActivate: onClear,
                    borderRadius: 8,
                    scale: 1.08,
                    child: Container(
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Clear', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TvFocusable(
                    onActivate: onDone,
                    borderRadius: 8,
                    scale: 1.08,
                    fillOnFocus: false,
                    child: Container(
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: FctvColors.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Done',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
