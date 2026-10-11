import 'package:flutter/material.dart';

/// Non-web stub — real implementation is [web_hls_surface_web.dart].
class WebHlsSurface extends StatelessWidget {
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
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

Future<void> webHlsSetMuted(bool muted) async {}

Future<void> webHlsTogglePlay() async {}

Future<void> webHlsPlay() async {}

Future<void> webHlsPause() async {}

Future<bool> webEnterFullscreen() async => false;

Future<void> webExitFullscreen() async {}

bool webIsFullscreen() => false;

VoidCallback webListenFullscreen(void Function(bool fullscreen) onChanged) => () {};

Future<bool> webTogglePictureInPicture() async => false;

bool webIsPictureInPicture() => false;
