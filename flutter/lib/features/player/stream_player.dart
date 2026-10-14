import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../shared/tv_focus.dart';
import 'web_hls_surface_stub.dart'
    if (dart.library.html) 'web_hls_surface_web.dart';

/// Stable player surface — keep one [State] across layout changes (fullscreen / panel).
/// Web uses a native HTML &lt;video&gt; + hls.js (media_kit's CanvasKit surface stays black).
/// Android TV / emulator use ExoPlayer via [video_player] — media_kit GPU/EGL stays black there.
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
  Player? _player;
  VideoController? _controller;
  VideoPlayerController? _exo;
  String? _loadedUrl;
  int _loadedToken = -1;
  int _openGen = 0;
  int _webViewId = 0;
  bool _muted = false;
  bool _playing = false;
  bool _opening = false;
  bool _buffering = false;
  bool _awaitingPlayback = false;
  bool _showCenterChrome = false;
  Timer? _hideTimer;
  Timer? _playbackWatchdog;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  /// Emulator VO attempt index (cycles known-working SurfaceView paths).
  int _emulatorVoAttempt = 0;

  /// ExoPlayer path — required on Android TV emulator (media_kit EGL black frames).
  bool get _useExo =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      (isAndroidTv || isAndroidEmulator);

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
    if (!kIsWeb && !_useExo) {
      _player = Player();
      _controller = VideoController(_player!, configuration: _videoControllerConfiguration());
      _bindPlayerStreams();
    }
    if (isAndroidTv) {
      _showCenterChrome = true;
    }
    if (widget.url != null && widget.url!.isNotEmpty) {
      _awaitingPlayback = true;
    }
    _openIfNeeded(widget.url, token: widget.loadToken, force: true);
  }

  void _onExoUpdate() {
    final exo = _exo;
    if (!mounted || exo == null) return;
    final v = exo.value;
    setState(() {
      _playing = v.isPlaying;
      _buffering = v.isBuffering;
      if (v.isPlaying) {
        _awaitingPlayback = false;
        _playbackWatchdog?.cancel();
      }
      if (v.hasError) {
        _awaitingPlayback = false;
        _showCenterChrome = true;
        debugPrint('FCTV exo error: ${v.errorDescription}');
      }
    });
    if (v.isPlaying) _bumpAutoHide();
  }

  Future<void> _disposeExo() async {
    final old = _exo;
    _exo = null;
    old?.removeListener(_onExoUpdate);
    try {
      await old?.dispose();
    } catch (_) {}
  }

  Future<void> _openExo(String url, {required int token, required int gen}) async {
    await _disposeExo();
    if (!mounted || gen != _openGen) return;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      // Our API always proxies HLS; without this ExoPlayer sniffs and fails.
      formatHint: VideoFormat.hls,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _exo = controller;
    controller.addListener(_onExoUpdate);
    try {
      await controller.initialize();
      if (!mounted || gen != _openGen) return;
      await controller.setVolume(_muted ? 0 : 1);
      await controller.setLooping(false);
      await controller.play();
      if (!mounted || gen != _openGen) return;
      _loadedUrl = url;
      _loadedToken = token;
      setState(() {
        _opening = false;
        _awaitingPlayback = !controller.value.isPlaying;
        _playing = controller.value.isPlaying;
        if (isAndroidTv) _showCenterChrome = true;
      });
      debugPrint(
        'FCTV exo ready ${controller.value.size.width}x${controller.value.size.height} '
        'playing=${controller.value.isPlaying}',
      );
      _playbackWatchdog?.cancel();
      _playbackWatchdog = Timer(const Duration(seconds: 3), () {
        if (!mounted || gen != _openGen) return;
        if (_playing) return;
        setState(() {
          _awaitingPlayback = false;
          _showCenterChrome = true;
        });
      });
    } catch (e) {
      debugPrint('FCTV exo open failed: $e');
      if (!mounted || gen != _openGen) return;
      _loadedUrl = null;
      _loadedToken = -1;
      setState(() {
        _opening = false;
        _awaitingPlayback = false;
        _showCenterChrome = true;
      });
    }
  }

  void _bindPlayerStreams() {
    final player = _player;
    if (player == null) return;
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _playingSub = player.stream.playing.listen((playing) {
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
    _bufferingSub = player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => _buffering = buffering);
    });
  }

  /// Android video output for media_kit.
  /// Emulator: never use `vo=gpu` — EGL_BAD_ATTRIBUTE → black frame (audio still plays).
  /// Prefer `mediacodec_embed` (SurfaceView). Real TV devices can use `gpu`.
  VideoControllerConfiguration _videoControllerConfiguration() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const VideoControllerConfiguration();
    }
    if (isAndroidEmulator) {
      // Cycle: embed+mediacodec → embed+auto → embed+no
      switch (_emulatorVoAttempt % 3) {
        case 1:
          return const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
            vo: 'mediacodec_embed',
            hwdec: 'auto',
          );
        case 2:
          return const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
            vo: 'mediacodec_embed',
            hwdec: 'no',
          );
        default:
          return const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
            vo: 'mediacodec_embed',
            hwdec: 'mediacodec',
          );
      }
    }
    // TV + phone: SurfaceView embed is the most reliable path across devices.
    // (gpu+mediacodec still used as optional fallback via recreate if needed.)
    return const VideoControllerConfiguration(
      enableHardwareAcceleration: true,
      vo: 'mediacodec_embed',
      hwdec: 'mediacodec',
    );
  }

  Future<void> _recreatePlayer() async {
    if (kIsWeb) return;
    _playbackWatchdog?.cancel();
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    _playingSub = null;
    _bufferingSub = null;
    final old = _player;
    _player = Player();
    _controller = VideoController(_player!, configuration: _videoControllerConfiguration());
    _bindPlayerStreams();
    if (_muted) {
      await _player!.setVolume(0);
    }
    try {
      await old?.stop();
    } catch (_) {}
    try {
      await old?.dispose();
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
      if (kIsWeb) {
        // keep surface; empty url handled by WebHlsSurface
      } else if (_useExo) {
        await _disposeExo();
      } else {
        try {
          await _player?.stop();
        } catch (_) {}
      }
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
    if (force || url != _loadedUrl) {
      _emulatorVoAttempt = 0;
    }

    if (kIsWeb) {
      _loadedUrl = null;
      _loadedToken = -1;
      _webViewId++;
      if (mounted) setState(() {});
      // Surface attaches + plays; mark loaded after a beat so overlays clear on playing.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted || gen != _openGen) return;
      _loadedUrl = url;
      _loadedToken = token;
      _playbackWatchdog = Timer(const Duration(seconds: 3), () {
        if (!mounted || gen != _openGen) return;
        if (_playing) return;
        setState(() {
          _awaitingPlayback = false;
          _showCenterChrome = true;
        });
      });
      if (mounted) setState(() => _opening = false);
      return;
    }

    if (_useExo) {
      await _openExo(url, token: token, gen: gen);
      return;
    }

    final hadMedia = _loadedUrl != null;
    _loadedUrl = null;
    _loadedToken = -1;
    if (hadMedia || force) {
      await _recreatePlayer();
      if (!mounted || gen != _openGen) return;
      setState(() {});
    } else {
      try {
        await _player?.stop();
      } catch (_) {}
      if (!mounted || gen != _openGen) return;
    }
    try {
      await _player!.setVolume(_muted ? 0 : 100);
      await _player!.open(Media(url), play: true);
      if (!mounted || gen != _openGen) return;
      _loadedUrl = url;
      _loadedToken = token;
      await _player!.play();
      _playbackWatchdog?.cancel();
      _playbackWatchdog = Timer(const Duration(seconds: 2), () {
        if (!mounted || gen != _openGen) return;
        if (_playing) return;
        unawaited(_recoverNativeAutoplay(gen));
      });
      if (isAndroidEmulator) {
        Timer(const Duration(seconds: 4), () {
          if (!mounted || gen != _openGen) return;
          // Audio can play while video surface stays black — still retry VO.
          unawaited(_retryEmulatorVoPath(url, token, gen));
        });
      }
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

  Future<void> _recoverNativeAutoplay(int gen) async {
    if (!mounted || gen != _openGen) return;
    try {
      _muted = true;
      await _player?.setVolume(0);
      await _player?.play();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || gen != _openGen) return;
    if (!_playing) {
      setState(() {
        _awaitingPlayback = false;
        _showCenterChrome = true;
        _muted = true;
      });
    }
  }

  /// Emulator black-screen fallback: cycle mediacodec_embed hwdec variants (max 2 retries).
  Future<void> _retryEmulatorVoPath(String url, int token, int gen) async {
    if (!isAndroidEmulator || !mounted || gen != _openGen) return;
    if (_emulatorVoAttempt >= 2) return;
    _emulatorVoAttempt++;
    debugPrint('FCTV video: emulator VO retry #$_emulatorVoAttempt');
    try {
      await _recreatePlayer();
      if (!mounted || gen != _openGen) return;
      setState(() {
        _opening = true;
        _awaitingPlayback = true;
      });
      await _player!.setVolume(_muted ? 0 : 100);
      await _player!.open(Media(url), play: true);
      if (!mounted || gen != _openGen) return;
      _loadedUrl = url;
      _loadedToken = token;
      await _player!.play();
      Timer(const Duration(seconds: 4), () {
        if (!mounted || gen != _openGen) return;
        unawaited(_retryEmulatorVoPath(url, token, gen));
      });
    } catch (e) {
      debugPrint('FCTV video: emulator VO retry failed: $e');
    } finally {
      if (mounted && gen == _openGen) {
        setState(() => _opening = false);
      }
    }
  }

  Future<void> togglePictureInPicture() async {
    if (kIsWeb) {
      await webTogglePictureInPicture();
      if (mounted) setState(() {});
      return;
    }
    // Android phone: prefer OS Picture-in-Picture, then in-app mini player.
    if (isAndroidPhone) {
      final ok = await enterAndroidPictureInPicture();
      if (ok) return;
    }
    widget.onTogglePiP?.call();
  }

  Future<void> toggleMute() async {
    final next = !_muted;
    if (kIsWeb) {
      await webHlsSetMuted(next);
      if (!mounted) return;
      setState(() => _muted = next);
      _bumpAutoHide();
      return;
    }
    if (_useExo) {
      await _exo?.setVolume(next ? 0 : 1);
      if (!mounted) return;
      setState(() => _muted = next);
      _bumpAutoHide();
      return;
    }
    await _player?.setVolume(next ? 0 : 100);
    if (!mounted) return;
    setState(() => _muted = next);
    if (!next) {
      try {
        await _player?.play();
      } catch (_) {
        await _player?.setVolume(0);
        await _player?.play();
        if (mounted) setState(() => _muted = true);
      }
    }
    _bumpAutoHide();
  }

  Future<void> togglePlay() async {
    if (kIsWeb) {
      await webHlsTogglePlay();
      if (!mounted) return;
      setState(() {
        _awaitingPlayback = false;
        _showCenterChrome = true;
      });
      _bumpAutoHide();
      return;
    }
    if (_useExo) {
      final exo = _exo;
      if (exo == null) return;
      if (exo.value.isPlaying) {
        await exo.pause();
      } else {
        await exo.play();
      }
      if (!mounted) return;
      setState(() {
        _awaitingPlayback = false;
        _showCenterChrome = true;
        _playing = exo.value.isPlaying;
      });
      _bumpAutoHide();
      return;
    }
    if (_playing) {
      await _player?.pause();
    } else {
      await _player?.play();
    }
    if (!mounted) return;
    setState(() {
      _awaitingPlayback = false;
      _showCenterChrome = true;
    });
    _bumpAutoHide();
  }

  void _onVideoTap() {
    if (_awaitingPlayback && _loadedUrl != null && !_playing) {
      unawaited(togglePlay());
      return;
    }
    if (_opening || widget.resolving) return;
    setState(() => _showCenterChrome = !_showCenterChrome);
    if (_showCenterChrome) _bumpAutoHide();
  }

  void _bumpAutoHide() {
    if (isAndroidTv) return;
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
    _exo?.removeListener(_onExoUpdate);
    unawaited(_disposeExo());
    _player?.dispose();
    super.dispose();
  }

  Widget _maybeClip(double radius, Widget child) {
    if (kIsWeb || radius <= 0) return child;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: child,
    );
  }

  Widget _videoSurface() {
    if (kIsWeb) {
      return WebHlsSurface(
        key: ValueKey('web-hls-$_webViewId-${widget.loadToken}'),
        url: widget.url,
        viewId: _webViewId,
        muted: _muted,
        onPlaying: (playing) {
          if (!mounted) return;
          setState(() {
            _playing = playing;
            if (playing) {
              _awaitingPlayback = false;
              _playbackWatchdog?.cancel();
            }
          });
          if (playing) _bumpAutoHide();
        },
        onMuted: (muted) {
          if (!mounted) return;
          setState(() => _muted = muted);
        },
      );
    }
    if (_useExo) {
      final exo = _exo;
      if (exo == null || !exo.value.isInitialized) {
        return const SizedBox.expand();
      }
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: exo.value.size.width.clamp(1, 4096),
          height: exo.value.size.height.clamp(1, 4096),
          child: VideoPlayer(exo),
        ),
      );
    }
    return Video(
      controller: _controller!,
      controls: NoVideoControls,
      fit: BoxFit.contain,
      fill: Colors.transparent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final video = _videoSurface();

    if (!widget.expanded) {
      // Mini / PiP: no overlays on web platform views.
      return _maybeClip(
        kIsWeb ? 0 : 8,
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: video,
          ),
        ),
      );
    }

    final hasUrl = widget.url != null && widget.url!.isNotEmpty;
    final waiting = _waitingForStream || (!hasUrl && widget.resolving);
    final idleEmpty = !hasUrl && !widget.resolving;

    // Web: controls live inside the HTML player shell (auto-hide). Do not stack
    // Flutter widgets over HtmlElementView — that blanks the video on CanvasKit.
    if (kIsWeb) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: idleEmpty
              ? const Center(
                  child: Text(
                    'Select a server',
                    style: TextStyle(color: FctvColors.textSecondary),
                  ),
                )
              : video,
        ),
      );
    }

    final surface = AspectRatio(
      aspectRatio: 16 / 9,
      child: _maybeClip(
        widget.isFullscreen ? 0 : 10,
        Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            video,
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
                if (!isAndroidTv)
                  IgnorePointer(
                    child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
                  ),
                if (!isAndroidTv)
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
                    leanback: isAndroidTv,
                    onTogglePlay: () => unawaited(togglePlay()),
                    onToggleMute: toggleMute,
                    onTogglePiP: (!supportsPictureInPicture)
                        ? null
                        : (kIsWeb || widget.onTogglePiP != null)
                            ? () => unawaited(togglePictureInPicture())
                            : null,
                    onToggleFullscreen: widget.onToggleFullscreen,
                    onAirPlay: supportsAirPlayChrome
                        ? (widget.onAirPlay ?? () => _defaultAirPlay(context))
                        : null,
                  ),
                ),
            ],
          ],
        ),
      ),
    );

    if (!isAndroidTv) return surface;

    return Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || idleEmpty || waiting) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
            event.logicalKey == LogicalKeyboardKey.mediaPlay ||
            event.logicalKey == LogicalKeyboardKey.mediaPause) {
          unawaited(togglePlay());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: surface,
    );
  }

  void _defaultAirPlay(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final msg = kIsWeb
        ? 'AirPlay / Cast: use the browser or system share sheet on Apple devices.'
        : defaultTargetPlatform == TargetPlatform.iOS
            ? 'Use Control Center AirPlay, or the route picker when available.'
            : isAndroidPhone
                ? 'Cast: open the notification shade while playing, or use Google Home / Cast devices.'
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
    this.leanback = false,
    this.onTogglePlay,
    this.onTogglePiP,
    this.onToggleFullscreen,
    this.onAirPlay,
  });

  final bool isFullscreen;
  final bool isMuted;
  final bool isPlaying;
  final bool leanback;
  final VoidCallback onToggleMute;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onTogglePiP;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback? onAirPlay;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leanback && onTogglePlay != null)
              _iconBtn(
                icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                onPressed: onTogglePlay!,
                enabled: true,
              ),
            _iconBtn(
              icon: isMuted ? Icons.volume_off : Icons.volume_up,
              onPressed: onToggleMute,
              enabled: true,
            ),
            if (onTogglePiP != null)
              _iconBtn(icon: Icons.picture_in_picture_alt, onPressed: onTogglePiP!, enabled: true),
            if (onAirPlay != null)
              _iconBtn(icon: Icons.airplay, onPressed: onAirPlay!, enabled: true),
            if (onToggleFullscreen != null)
              _iconBtn(
                icon: isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                onPressed: onToggleFullscreen!,
                enabled: true,
              ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required VoidCallback onPressed,
    required bool enabled,
  }) {
    if (leanback) {
      return TvFocusable(
        onActivate: onPressed,
        borderRadius: 20,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            size: isFullscreen ? 24 : 22,
            color: enabled ? Colors.white : Colors.white38,
          ),
        ),
      );
    }
    return IconButton(
      visualDensity: VisualDensity.compact,
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        size: isFullscreen ? 22 : 20,
        color: Colors.white.withValues(alpha: enabled ? 1 : 0.35),
      ),
    );
  }
}
