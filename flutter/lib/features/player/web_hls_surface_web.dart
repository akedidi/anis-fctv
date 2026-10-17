import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

@JS('fctvAttachHls')
external JSPromise<JSAny?> _fctvAttachHls(web.HTMLVideoElement video, String url);

@JS('fctvDestroyHls')
external void _fctvDestroyHls();

@JS('fctvMountPlayer')
external web.HTMLVideoElement _fctvMountPlayer(web.HTMLElement root, JSAny? opts);

@JS('fctvOnStreamNeedsRefresh')
external set _fctvOnStreamNeedsRefresh(JSFunction? fn);

web.HTMLVideoElement? _activeVideo;
VoidCallback? _streamNeedsRefreshHandler;

/// JS HLS watchdog calls this after repeated local reloads fail (expired token, etc.).
void webBindStreamNeedsRefresh(VoidCallback? handler) {
  _streamNeedsRefreshHandler = handler;
  if (handler == null) {
    _fctvOnStreamNeedsRefresh = null;
    return;
  }
  _fctvOnStreamNeedsRefresh = ((JSAny? _) {
    _streamNeedsRefreshHandler?.call();
  }).toJS;
}

/// Native HTML player shell (video + overlay controls) inside one platform view.
class WebHlsSurface extends StatefulWidget {
  const WebHlsSurface({
    super.key,
    required this.url,
    required this.viewId,
    this.muted = false,
    this.onPlaying,
    this.onMuted,
  });

  final String? url;
  final int viewId;
  final bool muted;
  final ValueChanged<bool>? onPlaying;
  final ValueChanged<bool>? onMuted;

  @override
  State<WebHlsSurface> createState() => _WebHlsSurfaceState();
}

class _WebHlsSurfaceState extends State<WebHlsSurface> {
  web.HTMLVideoElement? _video;
  String? _attachedUrl;

  void _bindRoot(web.HTMLElement root) {
    final video = _fctvMountPlayer(root, null);
    video.muted = widget.muted;
    _video = video;
    _activeVideo = video;
    video.addEventListener(
      'playing',
      (web.Event _) {
        widget.onPlaying?.call(true);
      }.toJS,
    );
    video.addEventListener(
      'pause',
      (web.Event _) {
        widget.onPlaying?.call(false);
      }.toJS,
    );
    video.addEventListener(
      'volumechange',
      (web.Event _) {
        widget.onMuted?.call(video.muted || video.volume == 0);
      }.toJS,
    );
    scheduleMicrotask(() => _attachIfNeeded());
  }

  @override
  void didUpdateWidget(covariant WebHlsSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.viewId != widget.viewId) {
      _attachedUrl = null;
      _attachIfNeeded();
    }
    final v = _video;
    if (v != null && v.muted != widget.muted) {
      v.muted = widget.muted;
      if (!widget.muted) v.volume = 1;
    }
  }

  Future<void> _attachIfNeeded() async {
    final video = _video;
    final url = widget.url;
    if (video == null || url == null || url.isEmpty) return;
    if (_attachedUrl == url) return;
    _attachedUrl = url;
    video.muted = widget.muted;
    try {
      await _fctvAttachHls(video, url).toDart;
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_activeVideo == _video) {
      _fctvDestroyHls();
      _activeVideo = null;
    }
    _video = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView.fromTagName(
      key: ValueKey('fctv-player-${widget.viewId}'),
      tagName: 'div',
      isVisible: true,
      onElementCreated: (Object element) {
        _bindRoot(element as web.HTMLElement);
      },
    );
  }
}

Future<void> webHlsSetMuted(bool muted) async {
  final v = _activeVideo;
  if (v == null) return;
  v.muted = muted;
  if (!muted) v.volume = 1;
  if (!muted) {
    try {
      await v.play().toDart;
    } catch (_) {
      v.muted = true;
      await v.play().toDart;
    }
  }
}

Future<void> webHlsTogglePlay() async {
  final v = _activeVideo;
  if (v == null) return;
  if (v.paused) {
    await webHlsPlay();
  } else {
    v.pause();
  }
}

Future<void> webHlsPlay() async {
  final v = _activeVideo;
  if (v == null) return;
  try {
    await v.play().toDart;
  } catch (_) {
    v.muted = true;
    await v.play().toDart;
  }
}

Future<void> webHlsPause() async {
  _activeVideo?.pause();
}

@JS('fctvEnterFullscreen')
external JSPromise<JSAny?> _fctvEnterFullscreen(web.HTMLVideoElement? video);

@JS('fctvExitFullscreen')
external JSPromise<JSAny?> _fctvExitFullscreen();

@JS('fctvIsFullscreen')
external bool _fctvIsFullscreen();

Future<bool> webEnterFullscreen() async {
  try {
    await _fctvEnterFullscreen(_activeVideo).toDart;
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> webExitFullscreen() async {
  try {
    await _fctvExitFullscreen().toDart;
  } catch (_) {}
}

bool webIsFullscreen() {
  try {
    return _fctvIsFullscreen();
  } catch (_) {
    return false;
  }
}

VoidCallback webListenFullscreen(void Function(bool fullscreen) onChanged) {
  void handler(web.Event _) => onChanged(webIsFullscreen());
  final jsHandler = handler.toJS;
  web.document.addEventListener('fullscreenchange', jsHandler);
  web.document.addEventListener('webkitfullscreenchange', jsHandler);
  return () {
    web.document.removeEventListener('fullscreenchange', jsHandler);
    web.document.removeEventListener('webkitfullscreenchange', jsHandler);
  };
}

@JS('fctvTogglePiP')
external JSPromise<JSAny?> _fctvTogglePiP(web.HTMLVideoElement? video);

@JS('fctvIsPiP')
external bool _fctvIsPiP(web.HTMLVideoElement? video);

Future<bool> webTogglePictureInPicture() async {
  final v = _activeVideo;
  if (v == null) return false;
  try {
    final result = await _fctvTogglePiP(v).toDart;
    if (result == null) return webIsPictureInPicture();
    return (result as JSBoolean).toDart;
  } catch (_) {
    return false;
  }
}

bool webIsPictureInPicture() {
  final v = _activeVideo;
  if (v == null) return false;
  try {
    return _fctvIsPiP(v);
  } catch (_) {
    return false;
  }
}
