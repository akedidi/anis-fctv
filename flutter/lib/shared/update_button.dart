import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_update.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import 'tv_focus.dart';

/// Top-right update control — visible only when a newer APK is on the git channel.
/// Flow matches AnisFlix Android TV: poll → tap → native download → system installer.
class AppUpdateButton extends StatefulWidget {
  const AppUpdateButton({super.key});

  @override
  State<AppUpdateButton> createState() => _AppUpdateButtonState();
}

class _AppUpdateButtonState extends State<AppUpdateButton> {
  final _service = AppUpdateService();
  AppUpdateInfo? _update;
  bool _busy = false;
  String? _status;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (_service.isSupported) {
      unawaited(_refresh());
      // Same cadence as AnisFlix TV update checks.
      _poll = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_refresh()));
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    final info = await _service.checkForUpdate();
    if (!mounted) return;
    setState(() {
      // null ⇒ already on latest (or check failed) ⇒ hide the button
      _update = info;
      if (info == null) {
        _busy = false;
        _status = null;
      }
    });
  }

  Future<void> _onPressed() async {
    final info = _update;
    if (info == null || _busy) return;

    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: !isAndroidTv,
      builder: (ctx) {
        final body = Text(
          info.changelog.isEmpty
              ? 'A new ${info.channel} build is available. Download and install?'
              : info.changelog,
          style: const TextStyle(color: FctvColors.textSecondary, height: 1.35),
        );
        if (!isAndroidTv) {
          return AlertDialog(
            backgroundColor: FctvColors.surfaceElevated,
            title: Text('Update to ${info.versionName}'),
            content: body,
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Update'),
              ),
            ],
          );
        }
        // TV: both actions share the same idle look; only the focused one fills accent
        // (a permanent accent "Update" chip made left/right feel broken).
        return FocusScope(
          autofocus: true,
          child: AlertDialog(
            backgroundColor: FctvColors.surfaceElevated,
            title: Text('Update to ${info.versionName}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                body,
                const SizedBox(height: 22),
                FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(1),
                        child: _TvUpdateDialogAction(
                          label: 'Later',
                          onActivate: () => Navigator.pop(ctx, false),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: _TvUpdateDialogAction(
                          label: 'Update',
                          autofocus: true,
                          onActivate: () => Navigator.pop(ctx, true),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (go != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = 'Downloading…';
    });
    final result = await _service.installUpdate(info);
    if (!mounted) return;

    // Native returns immediately with "started" while download continues —
    // unlock the UI like AnisFlix so menus stay usable.
    setState(() {
      _busy = false;
      _status = null;
    });

    final message = switch (result) {
      'started' => 'Download started. The installer will open automatically.',
      'settings' => 'Allow FCTV33 to install apps, then tap Update again.',
      'invalid_url' => 'Invalid update URL.',
      'ignored' => null,
      _ => 'Unable to start the update.',
    };
    if (message != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    }
    if (result == 'started') {
      // Hide until a newer build appears after relaunch.
      setState(() => _update = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = _update;
    if (!_service.isSupported || update == null) {
      return const SizedBox.shrink();
    }

    final label = _busy ? (_status ?? '…') : 'Update';
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
            )
          else
            const Icon(Icons.system_update_alt_rounded, size: 16, color: Colors.black),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );

    if (isAndroidTv) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TvFocusable(
          onActivate: _busy ? () {} : _onPressed,
          enabled: !_busy,
          borderRadius: 10,
          scale: 1.1,
          child: Material(
            color: FctvColors.accent,
            borderRadius: BorderRadius.circular(10),
            child: content,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: FctvColors.accent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: _busy ? null : _onPressed,
          borderRadius: BorderRadius.circular(10),
          child: content,
        ),
      ),
    );
  }
}

/// Dialog action for Android TV — idle = muted chip, focused = accent fill + ring.
class _TvUpdateDialogAction extends StatefulWidget {
  const _TvUpdateDialogAction({
    required this.label,
    required this.onActivate,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onActivate;
  final bool autofocus;

  @override
  State<_TvUpdateDialogAction> createState() => _TvUpdateDialogActionState();
}

class _TvUpdateDialogActionState extends State<_TvUpdateDialogAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final fg = _focused ? Colors.black : Colors.white;
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onActivate,
        child: AnimatedScale(
          scale: _focused ? 1.1 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: _focused ? FctvColors.accent : Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _focused ? FctvColors.accent : Colors.white24,
                width: _focused ? 3 : 1.5,
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
            child: Text(
              widget.label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
