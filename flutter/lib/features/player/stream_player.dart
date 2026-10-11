import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/theme.dart';

/// Stable player surface — keep one [State] across layout changes (fullscreen / panel),
/// but recreate the underlying [Player] on each URL switch so HLS sessions tear down
/// cleanly (same idea as destroying hls.js before loadSource).
class StreamPlayer extends StatefulWidget {
  const StreamPlayer({
    super.key,
    required this.url,
    required this.title,
    this.expanded = true,
    this.isFullscreen = false,
    this.resolving = false,
    /// Bumps on every server switch so we reopen even if the proxy URL looks similar.
    this.loadToken = 0,
    this.onTogglePiP,
    this.onToggleFullscreen,
    this.onAirPlay,
  });

  final String? url;
  final String title;
  final bool expanded;
  final bool isFullscreen;
  /// True while the parent is resolving a playable URL (server switch / first play).
  final bool resolving;
  final int loadToken;
  final VoidCallback? onTogglePiP;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback? onAirPlay;

  @override
  State<StreamPlayer> createState() => StreamPlayerState();
}

class StreamPlayerState extends State<StreamPlayer> {
  Player _player = Player();
  late VideoController _controller = VideoController(_player);
  String? _loadedUrl;
  int _loadedToken = -1;
  int _openGen = 0;
  bool _muted = false;
  bool _playing = true;
  bool _opening = false;
  bool _buffering = false;
  /// True from resolve/open until media_kit reports playing — keeps loader, hides play button.
  bool _awaitingPlayback = false;
  /// Center play + dimmer only — bottom-right action cluster stays visible.
  bool _showCenterChrome = false;
  Timer? _hideTimer;
  Timer? _playbackWatchdog;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;

  Player get player => _player;

  bool get _waitingForStream =>
      widget.resolving ||
      _opening ||
      _buffering ||
      _awaitingPlayback ||
      (widget.url != null &&
          widget.url!.isNotEmpty &&
          (widget.url != _loadedUrl || widget.loadToken != _loadedToken));

  @override
  void initState() {
    super.initState();
    _bindPlayerStreams();
    if (widget.url != null && widget.url!.isNotEmpty) {
      _awaitingPlayback = true;
    }
    _openIfNeeded(widget.url, token: widget.loadToken, force: true);
  }

  void _bindPlayerStreams() {
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _playingSub = _player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() {
        _playing = playing;
        if (playing) {
          _awaitingPlayback = false;
          _playbackWatchdog?.cancel();
        }
      });
      if (playing) _bumpAutoHide();
    });
    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => _buffering = buffering);
    });
  }

  /// Tear down the previous media_kit / web HLS session completely.
  Future<void> _recreatePlayer() async {
    _playbackWatchdog?.cancel();
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    _playingSub = null;
    _bufferingSub = null;
    final old = _player;
    _player = Player();
    _controller = VideoController(_player);
    _bindPlayerStreams();
    if (_muted) {
      await _player.setVolume(0);
    }
    try {
      await old.stop();
    } catch (_) {}
    try {
      await old.dispose();
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant StreamPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final urlChanged = oldWidget.url != widget.url;
    final tokenChanged = oldWidget.loadToken != widget.loadToken;
    if (urlChanged || tokenChanged) {
      _openIfNeeded(
        widget.url,
        token: widget.loadToken,
        force: tokenChanged || urlChanged,
      );
    } else if (!oldWidget.resolving && widget.resolving) {
      // Server switch started — stay on loader, never flash the play button.
      setState(() {
        _awaitingPlayback = true;
        _showCenterChrome = false;
      });
    } else if (oldWidget.resolving != widget.resolving) {
      setState(() {});
    }
  }

  Future<void> _openIfNeeded(
    String? url, {
    required int token,
    bool force = false,
  }) async {
    final gen = ++_openGen;
    _playbackWatchdog?.cancel();
    if (url == null || url.isEmpty) {
      if (mounted) {
        setState(() {
          _opening = false;
          _awaitingPlayback = widget.resolving;
          _loadedUrl = null;
          _loadedToken = -1;
        });
      } else {
        _loadedUrl = null;
        _loadedToken = -1;
      }
      try {
        await _player.stop();
      } catch (_) {}
      return;
    }
    if (!force && url == _loadedUrl && token == _loadedToken) {
      if (mounted) {
        setState(() {
          _opening = false;
          if (_playing) _awaitingPlayback = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _opening = true;
        _awaitingPlayback = true;
        _showCenterChrome = false;
        _playing = false;
      });
    }
    // Recreate so the previous HLS session cannot stick (web media_kit / hls.js).
    final hadMedia = _loadedUrl != null;
    _loadedUrl = null;
    _loadedToken = -1;
    if (hadMedia || force) {
      await _recreatePlayer();
      if (!mounted || gen != _openGen) return;
      setState(() {}); // pick up new VideoController
    } else {
      try {
        await _player.stop();
      } catch (_) {}
      if (!mounted || gen != _openGen) return;
    }
    try {
      // Web: async resolve loses the tap gesture — browsers only allow muted autoplay.
      final wantSound = !_muted;
      if (kIsWeb) {
        await _player.setVolume(0);
      }
      await _player.open(Media(url), play: true);
      if (!mounted || gen != _openGen) return;
      _loadedUrl = url;
      _loadedToken = token;
      await _player.play();
      if (!mounted || gen != _openGen) return;
      if (kIsWeb && wantSound) {
        // Best-effort unmute after muted autoplay engages (may stay muted until user taps).
        try {
          await _player.setVolume(100);
          if (mounted) setState(() => _muted = false);
        } catch (_) {
          if (mounted) setState(() => _muted = true);
        }
      }
      _playbackWatchdog = Timer(const Duration(seconds: 5), () {
        if (!mounted || gen != _openGen) return;
        if (_awaitingPlayback && !_playing) {
          // Last resort: another play() then show the center control.
          unawaited(_player.play());
          Future<void>.delayed(const Duration(milliseconds: 400), () {
            if (!mounted || gen != _openGen) return;
            if (_awaitingPlayback && !_playing) {
              setState(() {
                _awaitingPlayback = false;
                _showCenterChrome = true;
              });
            }
          });
        }
      });
    } catch (_) {
      if (!mounted || gen != _openGen) return;
      _loadedUrl = null;
      _loadedToken = -1;
      setState(() {
        _awaitingPlayback = false;
        _showCenterChrome = true;
      });
    } finally {
      if (gen == _openGen && mounted) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    await _player.setVolume(_muted ? 0 : 100);
    setState(() {});
  }

  Future<void> togglePlay() async {
    await _player.playOrPause();
    setState(() => _showCenterChrome = true);
    _bumpAutoHide();
  }

  void _onVideoTap() {
    if (_waitingForStream) return;
    setState(() => _showCenterChrome = !_showCenterChrome);
    if (_showCenterChrome) _bumpAutoHide();
  }

  void _bumpAutoHide() {
    _hideTimer?.cancel();
    if (!_showCenterChrome || widget.url == null || _waitingForStream) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_playing || _waitingForStream) return;
      setState(() => _showCenterChrome = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playbackWatchdog?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = Video(
      controller: _controller,
      controls: NoVideoControls,
      fit: BoxFit.contain,
    );

    if (!widget.expanded) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: Colors.black, child: video),
              if (_waitingForStream)
                const ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: FctvColors.accent),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final hasUrl = widget.url != null && widget.url!.isNotEmpty;
    final waiting = _waitingForStream || (!hasUrl && widget.resolving);
    final idleEmpty = !hasUrl && !widget.resolving;

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.isFullscreen ? 0 : 10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black, child: video),
            if (idleEmpty)
              const Center(
                child: Text('Select a server', style: TextStyle(color: FctvColors.textSecondary)),
              )
            else ...[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _onVideoTap,
                ),
              ),
              if (waiting)
                const ColoredBox(
                  color: Color(0x99000000),
                  child: Center(
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.8,
                        color: FctvColors.accent,
                      ),
                    ),
                  ),
                )
              else if (_showCenterChrome) ...[
                IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
                ),
                Center(
                  child: IconButton(
                    onPressed: togglePlay,
                    iconSize: widget.isFullscreen ? 64 : 52,
                    icon: Icon(
                      _playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
                      color: Colors.white,
                      shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                    ),
                  ),
                ),
                if (widget.isFullscreen)
                  Positioned(
                    left: 20,
                    top: 16,
                    right: 100,
                    child: IgnorePointer(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                        ),
                      ),
                    ),
                  ),
              ],
              if (!waiting)
                Positioned(
                  right: widget.isFullscreen ? 16 : 10,
                  bottom: widget.isFullscreen ? 16 : 10,
                  child: _PlayerActionBar(
                    isFullscreen: widget.isFullscreen,
                    isMuted: _muted,
                    isPlaying: _playing,
                    onToggleMute: toggleMute,
                    onTogglePiP: widget.onTogglePiP,
                    onToggleFullscreen: widget.onToggleFullscreen,
                    onAirPlay: widget.onAirPlay ?? () => _defaultAirPlay(context),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _defaultAirPlay(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final msg = kIsWeb
        ? 'AirPlay / Cast: use the browser or system share sheet on Apple devices.'
        : defaultTargetPlatform == TargetPlatform.iOS
            ? 'Use Control Center AirPlay, or the route picker when available.'
            : 'Use Cast from your device media controls when available.';
    messenger?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2), behavior: SnackBarBehavior.floating),
    );
  }
}

class _PlayerActionBar extends StatelessWidget {
  const _PlayerActionBar({
    required this.isFullscreen,
    required this.isMuted,
    required this.isPlaying,
    required this.onToggleMute,
    required this.onTogglePiP,
    required this.onToggleFullscreen,
    required this.onAirPlay,
  });

  final bool isFullscreen;
  final bool isMuted;
  final bool isPlaying;
  final VoidCallback onToggleMute;
  final VoidCallback? onTogglePiP;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback onAirPlay;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CtrlBtn(
              icon: isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              tooltip: isMuted ? 'Unmute' : 'Mute',
              onTap: onToggleMute,
            ),
            _CtrlBtn(
              icon: Icons.airplay_rounded,
              tooltip: 'AirPlay / Cast',
              onTap: onAirPlay,
            ),
            if (onTogglePiP != null)
              _CtrlBtn(
                icon: Icons.picture_in_picture_alt_rounded,
                tooltip: 'Picture in Picture',
                enabled: isPlaying,
                onTap: onTogglePiP,
              ),
            _CtrlBtn(
              icon: isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              tooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
              enabled: onToggleFullscreen != null,
              onTap: onToggleFullscreen,
            ),
          ],
        ),
      ),
    );
  }
}

class _CtrlBtn extends StatelessWidget {
  const _CtrlBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Icon(
            icon,
            size: 22,
            color: Colors.white.withValues(alpha: enabled ? 1 : 0.35),
          ),
        ),
      ),
    );
  }
}
