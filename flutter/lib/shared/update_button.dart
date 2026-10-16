import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import 'tv_focus.dart';

/// Top-right update control — visible only when a newer APK is on the git channel.
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
      _poll = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(_refresh()));
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
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
        // TV: Material dialog actions are not D-pad friendly — use TvFocusable.
        return FocusScope(
          autofocus: true,
          child: AlertDialog(
            backgroundColor: FctvColors.surfaceElevated,
            title: Text('Update to ${info.versionName}'),
            content: body,
            actionsAlignment: MainAxisAlignment.end,
            actions: [
              TvFocusable(
                onActivate: () => Navigator.pop(ctx, false),
                borderRadius: 10,
                scale: 1.08,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text('Later', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 8),
              TvFocusable(
                autofocus: true,
                onActivate: () => Navigator.pop(ctx, true),
                borderRadius: 10,
                scale: 1.08,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: FctvColors.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Update',
                    style: TextStyle(fontWeight: FontWeight.w800, color: Colors.black),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (go != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = 'Downloading…';
    });
    final err = await _service.installUpdate(info);
    if (!mounted) return;
    if (err == null) {
      // Installer opened — hide until a newer build appears after relaunch.
      setState(() {
        _busy = false;
        _status = null;
        _update = null;
      });
      return;
    }
    setState(() {
      _busy = false;
      _status = err;
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), behavior: SnackBarBehavior.floating),
      );
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
