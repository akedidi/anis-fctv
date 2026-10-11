import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

@JS('fctvAttachHls')
external JSPromise<JSAny?> _fctvAttachHls(web.HTMLVideoElement video, String url);

@JS('fctvDestroyHls')
external void _fctvDestroyHls();

web.HTMLVideoElement? _activeVideo;

/// Native HTML &lt;video&gt; + hls.js — avoids media_kit's CanvasKit black surface.
class WebHlsSurface extends StatefulWidget {
  const WebHlsSurface({
    super.key,
    required this.url,
    required this.viewId,
    this.muted = true,
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

  void _bindVideo(web.HTMLVideoElement video) {
    _video = video;
    _activeVideo = video;
    video.autoplay = true;
    video.muted = widget.muted;
    video.controls = false;
    video.setAttribute('playsinline', 'true');
    video.setAttribute('webkit-playsinline', 'true');
    video.style
      ..setProperty('width', '100%')
      ..setProperty('height', '100%')
      ..setProperty('object-fit', 'contain')
      ..setProperty('background', '#000')
      ..setProperty('display', 'block');
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
    // isVisible: true keeps the platform view painted (not DOM-only).
    return HtmlElementView.fromTagName(
      key: ValueKey('fctv-video-${widget.viewId}'),
      tagName: 'video',
      isVisible: true,
      onElementCreated: (Object element) {
        _bindVideo(element as web.HTMLVideoElement);
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
