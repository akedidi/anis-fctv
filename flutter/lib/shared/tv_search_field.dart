import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import 'tv_focus.dart';

/// Android TV search — never opens the system soft IME (it steals mouse/D-pad).
/// Use the on-screen letter pad, or type with the host keyboard while focused.
class TvSearchField extends StatefulWidget {
  const TvSearchField({
    super.key,
    required this.controller,
    this.hint = 'Search teams, leagues…',
  });

  final TextEditingController controller;
  final String hint;

  @override
  State<TvSearchField> createState() => _TvSearchFieldState();
}

class _TvSearchFieldState extends State<TvSearchField> {
  late final FocusNode _focus = FocusNode(
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final key = event.character;
      if (key != null && key.isNotEmpty && key.codeUnitAt(0) >= 32) {
        _append(key);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        _backspace();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );
  bool _padOpen = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        SystemChannels.textInput.invokeMethod('TextInput.hide');
      } else if (mounted && _padOpen) {
        setState(() => _padOpen = false);
      }
    });
    widget.controller.addListener(_onText);
  }

  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          focusNode: _focus,
          controller: widget.controller,
          readOnly: true,
          showCursor: true,
          enableInteractiveSelection: false,
          keyboardType: TextInputType.none,
          onTap: () {
            SystemChannels.textInput.invokeMethod('TextInput.hide');
            setState(() => _padOpen = !_padOpen);
            _focus.requestFocus();
          },
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: const Icon(Icons.search_rounded, size: 20, color: FctvColors.textMuted),
            suffixIcon: widget.controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    onPressed: _clear,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        if (_padOpen) ...[
          const SizedBox(height: 8),
          _TvLetterPad(
            onChar: _append,
            onSpace: () => _append(' '),
            onBackspace: _backspace,
            onDone: () {
              setState(() => _padOpen = false);
              _focus.unfocus();
            },
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
    required this.onDone,
  });

  final ValueChanged<String> onChar;
  final VoidCallback onSpace;
  final VoidCallback onBackspace;
  final VoidCallback onDone;

  static const _rows = [
    'ABCDEFGHI',
    'JKLMNOPQR',
    'STUVWXYZ0',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: FctvColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          for (final row in _rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  for (var i = 0; i < row.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: TvFocusable(
                          onActivate: () => onChar(row[i].toLowerCase()),
                          borderRadius: 8,
                          child: Container(
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              row[i],
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
                  onActivate: onDone,
                  borderRadius: 8,
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
    );
  }
}
