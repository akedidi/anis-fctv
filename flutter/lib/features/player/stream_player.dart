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

/// Video framing — same options as AnisFlix Android TV.
enum VideoDisplayMode { original, ratio16x9, ratio4x3, stretch }

extension VideoDisplayModeX on VideoDisplayMode {
  String get label => switch (this) {
        VideoDisplayMode.original => 'Original',
        VideoDisplayMode.ratio16x9 => '16:9',
        VideoDisplayMode.ratio4x3 => '4:3',
        VideoDisplayMode.stretch => 'Stretch',
      };

  IconData get icon => switch (this) {
        VideoDisplayMode.original => Icons.crop_original,
        VideoDisplayMode.ratio16x9 => Icons.crop_16_9,
        VideoDisplayMode.ratio4x3 => Icons.crop_landscape,
        VideoDisplayMode.stretch => Icons.zoom_out_map,
      };
}

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
    this.onMoveDownToServers,
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
  /// Down from the inline format / fullscreen buttons.
  final VoidCallback? onMoveDownToServers;

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
  bool _showAspectPanel = false;
  VideoDisplayMode _displayMode = VideoDisplayMode.original;
  Timer? _hideTimer;
  Timer? _playbackWatchdog;
  final _playFocus = FocusNode(debugLabel: 'fs play');
  final _aspectFocus = FocusNode(debugLabel: 'fs aspect');
  final _exitFsFocus = FocusNode(debugLabel: 'fs exit');
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
    // Position ticks must not reset the idle timer — only arm it if it isn't running.
    if (v.isPlaying && _hideTimer == null) _bumpAutoHide();
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
      // Texture/SurfaceProducer leaves a green overlay on Fire Stick / some Android TV
      // SoCs (Chromecast often OK). PlatformView renders via a native SurfaceView.
      viewType: VideoViewType.platformView,
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
    if (!oldWidget.isFullscreen && widget.isFullscreen) {
      setState(() => _showCenterChrome = true);
      _bumpAutoHide();
      _focusFullscreenPlay();
    }
  }

  bool get _fullscreenControlFocused =>
      _playFocus.hasFocus || _aspectFocus.hasFocus || _exitFsFocus.hasFocus;

  void _focusFullscreenPlay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.isFullscreen || !_showCenterChrome) return;
      _playFocus.requestFocus();
    });
  }

  /// D-pad between play (center) and the corner controls (aspect, exit).
  KeyEventResult _moveFullscreenControl(LogicalKeyboardKey key) {
    if (_playFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowRight) {
        (_aspectFocus.context != null ? _aspectFocus : _exitFsFocus).requestFocus();
        return KeyEventResult.handled;
      }
    } else if (_aspectFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowRight) {
        _exitFsFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp) {
        _playFocus.requestFocus();
        return KeyEventResult.handled;
      }
    } else if (_exitFsFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowLeft && _aspectFocus.context != null) {
        _aspectFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowLeft) {
        _playFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Down from format / fullscreen stays put, or moves to the first server when one exists.
  KeyEventResult _onInlineControlDown(KeyEvent event) {
    if (widget.isFullscreen || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) return KeyEventResult.ignored;
    widget.onMoveDownToServers?.call();
    return KeyEventResult.handled;
  }
  bool focusFullscreenButton() {
    if (_exitFsFocus.context == null) return false;
    _exitFsFocus.requestFocus();
    return true;
  }

  /// Closes the aspect picker. Back itself leaves fullscreen.
  bool consumeBackToHideControls() {
    if (_showAspectPanel) {
      _closeAspectPanel();
      return true;
    }
    return false;
  }

  void revealControls() {
    if (!mounted) return;
    setState(() => _showCenterChrome = true);
    _bumpAutoHide();
  }

  /// Enter / Select on the focused fullscreen control.
  bool _activateFocusedControl(LogicalKeyboardKey key) {
    final activate = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!activate) return false;
    if (_playFocus.hasFocus) {
      unawaited(togglePlay());
      return true;
    }
    if (_aspectFocus.hasFocus) {
      _openAspectPanel();
      _bumpAutoHide();
      return true;
    }
    if (_exitFsFocus.hasFocus) {
      widget.onToggleFullscreen?.call();
      return true;
    }
    return false;
  }

  /// Keys while fullscreen chrome is hidden (or media keys).
  KeyEventResult handleFullscreenKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_showAspectPanel) return KeyEventResult.ignored;

    final revealKeys = event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space ||
        event.logicalKey == LogicalKeyboardKey.gameButtonA ||
        event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight;

    if (widget.isFullscreen && !_showCenterChrome && revealKeys) {
      revealControls();
      _focusFullscreenPlay();
      return KeyEventResult.handled;
    }
    // Any remote activity while chrome is up restarts the 2s idle hide.
    if (widget.isFullscreen && _showCenterChrome && revealKeys) {
      _bumpAutoHide();
      final arrows = event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight;
      if (arrows) {
        if (!_fullscreenControlFocused) {
          _focusFullscreenPlay();
          return KeyEventResult.handled;
        }
        return _moveFullscreenControl(event.logicalKey);
      }
      if (_activateFocusedControl(event.logicalKey)) return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
        event.logicalKey == LogicalKeyboardKey.mediaPlay ||
        event.logicalKey == LogicalKeyboardKey.mediaPause) {
      unawaited(togglePlay());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    // TV keeps inline controls visible; auto-hide only in fullscreen.
    if (isAndroidTv && !widget.isFullscreen) return;
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_showCenterChrome || _showAspectPanel || widget.url == null || _waitingForStream) {
      return;
    }
    final delay = widget.isFullscreen ? const Duration(seconds: 2) : const Duration(seconds: 4);
    _hideTimer = Timer(delay, () {
      _hideTimer = null;
      if (!mounted || _waitingForStream || _showAspectPanel) return;
      if (!widget.isFullscreen && !_playing) return;
      setState(() => _showCenterChrome = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playbackWatchdog?.cancel();
    _playFocus.dispose();
    _aspectFocus.dispose();
    _exitFsFocus.dispose();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _exo?.removeListener(_onExoUpdate);
    unawaited(_disposeExo());
    _player?.dispose();
    super.dispose();
  }

  Widget _maybeClip(double radius, Widget child) {
    // PlatformView (Exo on TV) ignores Flutter clips and can glitch under ClipRRect.
    if (kIsWeb || radius <= 0 || _useExo) return child;
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
      final child = SizedBox(
        width: exo.value.size.width.clamp(1, 4096),
        height: exo.value.size.height.clamp(1, 4096),
        child: VideoPlayer(exo),
      );
      return _DisplayModeBox(mode: _displayMode, child: child);
    }
    final fit = switch (_displayMode) {
      VideoDisplayMode.original => BoxFit.contain,
      VideoDisplayMode.stretch => BoxFit.fill,
      VideoDisplayMode.ratio16x9 || VideoDisplayMode.ratio4x3 => BoxFit.cover,
    };
    final video = Video(
      controller: _controller!,
      controls: NoVideoControls,
      fit: fit,
      fill: Colors.transparent,
    );
    return switch (_displayMode) {
      VideoDisplayMode.ratio16x9 => Center(
          child: AspectRatio(aspectRatio: 16 / 9, child: video),
        ),
      VideoDisplayMode.ratio4x3 => Center(
          child: AspectRatio(aspectRatio: 4 / 3, child: video),
        ),
      _ => video,
    };
  }

  void _openAspectPanel() {
    _hideTimer?.cancel();
    setState(() {
      _showAspectPanel = true;
      _showCenterChrome = true;
    });
  }

  void _closeAspectPanel() {
    if (!_showAspectPanel) return;
    setState(() => _showAspectPanel = false);
    _bumpAutoHide();
  }

  void _selectDisplayMode(VideoDisplayMode mode) {
    setState(() {
      _displayMode = mode;
      _showAspectPanel = false;
    });
    _bumpAutoHide();
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
                if (isAndroidTv)
                  Center(
                    child: FocusTraversalOrder(
                      order: const NumericFocusOrder(1),
                      child: TvFocusIconButton(
                        focusNode: widget.isFullscreen ? _playFocus : null,
                        tooltip: _playing ? 'Pause' : 'Play',
                        icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        onPressed: () {
                          unawaited(togglePlay());
                          _bumpAutoHide();
                        },
                        primary: true,
                        diameter: widget.isFullscreen ? 64 : 52,
                        iconSize: widget.isFullscreen ? 36 : 30,
                        autofocus: widget.isFullscreen,
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
              // Hide action bar with chrome in fullscreen (auto-hide / Back).
              if (!waiting && (_showCenterChrome || !widget.isFullscreen))
                Positioned(
                  right: widget.isFullscreen ? 16 : 10,
                  bottom: widget.isFullscreen ? 16 : 10,
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(2),
                    child: _PlayerActionBar(
                      isFullscreen: widget.isFullscreen,
                      isMuted: _muted,
                      isPlaying: _playing,
                      leanback: isAndroidTv,
                      displayMode: _displayMode,
                      onTogglePlay: isAndroidTv ? null : () => unawaited(togglePlay()),
                      onToggleMute: toggleMute,
                      onAspectFormat: () {
                        _openAspectPanel();
                        _bumpAutoHide();
                      },
                      onTogglePiP: (!supportsPictureInPicture)
                          ? null
                          : (kIsWeb || widget.onTogglePiP != null)
                              ? () => unawaited(togglePictureInPicture())
                              : null,
                      onToggleFullscreen: widget.onToggleFullscreen,
                      aspectFocus: isAndroidTv ? _aspectFocus : null,
                      fullscreenFocus: isAndroidTv ? _exitFsFocus : null,
                      onControlKey: isAndroidTv && !widget.isFullscreen ? _onInlineControlDown : null,
                      onAirPlay: supportsAirPlayChrome
                          ? (widget.onAirPlay ?? () => _defaultAirPlay(context))
                          : null,
                    ),
                  ),
                ),
              if (_showAspectPanel)
                _AspectFormatPanel(
                  selected: _displayMode,
                  fullscreen: widget.isFullscreen,
                  onSelected: _selectDisplayMode,
                  onClose: _closeAspectPanel,
                ),
            ],
          ],
        ),
      ),
    );

    if (!isAndroidTv) return surface;

    // Key handler only — must not join focus traversal (traps D-pad on "empty" chrome).
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent || idleEmpty || waiting) return KeyEventResult.ignored;
          if (_showAspectPanel) {
            if (event.logicalKey == LogicalKeyboardKey.goBack ||
                event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.browserBack) {
              _closeAspectPanel();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }
          // Fullscreen Back is owned by the route PopScope (hide chrome → exit).
          if (widget.isFullscreen &&
              (event.logicalKey == LogicalKeyboardKey.goBack ||
                  event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.browserBack)) {
            return KeyEventResult.ignored;
          }
          if (widget.isFullscreen && _showCenterChrome) {
            _bumpAutoHide();
          }
          if (widget.isFullscreen && !_showCenterChrome) {
            return handleFullscreenKey(event);
          }
          if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause ||
              event.logicalKey == LogicalKeyboardKey.mediaPlay ||
              event.logicalKey == LogicalKeyboardKey.mediaPause) {
            unawaited(togglePlay());
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: surface,
      ),
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
    required this.displayMode,
    this.leanback = false,
    this.onTogglePlay,
    this.onAspectFormat,
    this.onTogglePiP,
    this.onToggleFullscreen,
    this.onAirPlay,
    this.aspectFocus,
    this.fullscreenFocus,
    this.onControlKey,
  });

  final bool isFullscreen;
  final bool isMuted;
  final bool isPlaying;
  final bool leanback;
  final VideoDisplayMode displayMode;
  final VoidCallback onToggleMute;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onAspectFormat;
  final VoidCallback? onTogglePiP;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback? onAirPlay;
  final FocusNode? aspectFocus;
  final FocusNode? fullscreenFocus;
  final KeyEventResult Function(KeyEvent event)? onControlKey;

  @override
  Widget build(BuildContext context) {
    if (leanback) {
      // Play/pause is centered on the player; corner bar keeps format + fullscreen only.
      final actions = <Widget>[
        if (onAspectFormat != null)
          TvFocusIconButton(
            focusNode: aspectFocus,
            onKey: onControlKey,
            tooltip: 'Aspect format',
            icon: Icons.aspect_ratio,
            onPressed: onAspectFormat!,
            diameter: isFullscreen ? 48 : 36,
            iconSize: isFullscreen ? 22 : 18,
            active: displayMode != VideoDisplayMode.original,
          ),
        if (onToggleFullscreen != null)
          TvFocusIconButton(
            focusNode: fullscreenFocus,
            onKey: onControlKey,
            tooltip: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
            icon: isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            onPressed: onToggleFullscreen!,
            diameter: isFullscreen ? 48 : 36,
            iconSize: isFullscreen ? 22 : 18,
          ),
      ];
      if (actions.isEmpty) return const SizedBox.shrink();
      return Material(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  actions[i],
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _iconBtn(
              icon: isMuted ? Icons.volume_off : Icons.volume_up,
              onPressed: onToggleMute,
              enabled: true,
            ),
            if (onAspectFormat != null)
              _iconBtn(
                icon: Icons.aspect_ratio,
                onPressed: onAspectFormat!,
                enabled: true,
                active: displayMode != VideoDisplayMode.original,
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
    bool active = false,
  }) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: active ? 'Aspect format' : null,
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        size: isFullscreen ? 22 : 20,
        color: !enabled
            ? Colors.white.withValues(alpha: 0.35)
            : active
                ? FctvColors.accent
                : Colors.white,
      ),
    );
  }
}

class _DisplayModeBox extends StatelessWidget {
  const _DisplayModeBox({required this.mode, required this.child});

  final VideoDisplayMode mode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case VideoDisplayMode.original:
        return FittedBox(
          fit: BoxFit.contain,
          clipBehavior: Clip.hardEdge,
          child: child,
        );
      case VideoDisplayMode.stretch:
        return FittedBox(
          fit: BoxFit.fill,
          clipBehavior: Clip.hardEdge,
          child: child,
        );
      case VideoDisplayMode.ratio16x9:
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: child,
            ),
          ),
        );
      case VideoDisplayMode.ratio4x3:
        return Center(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: child,
            ),
          ),
        );
    }
  }
}

class _AspectFormatPanel extends StatefulWidget {
  const _AspectFormatPanel({
    required this.selected,
    required this.onSelected,
    required this.onClose,
    required this.fullscreen,
  });

  final VideoDisplayMode selected;
  final ValueChanged<VideoDisplayMode> onSelected;
  final VoidCallback onClose;
  final bool fullscreen;

  @override
  State<_AspectFormatPanel> createState() => _AspectFormatPanelState();
}

class _AspectFormatPanelState extends State<_AspectFormatPanel> {
  final _scopeNode = FocusScopeNode(debugLabel: 'TV aspect panel');
  final _closeFocusNode = FocusNode(debugLabel: 'aspect close');
  late final List<FocusNode> _optionNodes = List.generate(
    VideoDisplayMode.values.length,
    (index) => FocusNode(debugLabel: 'aspect option $index'),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scopeNode.requestFocus();
      final index = VideoDisplayMode.values.indexOf(widget.selected);
      _optionNodes[index.clamp(0, _optionNodes.length - 1)].requestFocus();
    });
  }

  @override
  void dispose() {
    _scopeNode.dispose();
    _closeFocusNode.dispose();
    for (final node in _optionNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handlePanelKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isTv = isAndroidTv;
    final compact = !widget.fullscreen;
    final selectedIndex = VideoDisplayMode.values.indexOf(widget.selected);
    final modes = VideoDisplayMode.values;
    return Positioned.fill(
      child: FocusScope(
        node: _scopeNode,
        autofocus: isTv,
        onKeyEvent: _handlePanelKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Inline player is short; keep the sheet inside it and scroll if needed.
            final maxHeight = compact
                ? (constraints.maxHeight - 12).clamp(0.0, constraints.maxHeight)
                : constraints.maxHeight * 0.72;
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    child: ColoredBox(color: Colors.black.withValues(alpha: 0.55)),
                  ),
                ),
                Align(
                  alignment: compact ? Alignment.center : Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.all(compact ? 6 : 0),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: compact ? constraints.maxWidth : (isTv ? 560 : double.infinity),
                        maxHeight: maxHeight,
                      ),
                      child: Material(
                        color: FctvColors.surfaceElevated,
                        borderRadius: compact
                            ? BorderRadius.circular(12)
                            : const BorderRadius.vertical(top: Radius.circular(20)),
                        clipBehavior: Clip.antiAlias,
                        child: ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.fromLTRB(compact ? 10 : 20, compact ? 6 : 8, compact ? 10 : 20, compact ? 4 : 24),
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Aspect format',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: compact ? 14 : 18,
                                    ),
                                  ),
                                ),
                                if (isTv)
                                  TvFocusable(
                                    focusNode: _closeFocusNode,
                                    onActivate: widget.onClose,
                                    borderRadius: 10,
                                    scale: compact ? 1 : 1.08,
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: compact ? 8 : 12,
                                        vertical: compact ? 4 : 8,
                                      ),
                                      child: Text(
                                        'Close',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: compact ? 12 : null,
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  TextButton(onPressed: widget.onClose, child: const Text('Close')),
                              ],
                            ),
                            SizedBox(height: compact ? 4 : 12),
                            for (var i = 0; i < modes.length; i++)
                              TvSelectableRow(
                                focusNode: _optionNodes[i],
                                autofocus: isTv && i == selectedIndex,
                                title: modes[i].label,
                                selected: widget.selected == modes[i],
                                dense: compact,
                                leading: Icon(modes[i].icon, size: compact ? 18 : 24),
                                onPressed: () => widget.onSelected(modes[i]),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
