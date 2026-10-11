import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/theme.dart';

/// Stable player surface — keep one [Player] across layout changes (fullscreen / panel).
class StreamPlayer extends StatefulWidget {
  const StreamPlayer({
    super.key,
    required this.url,
    required this.title,
    this.expanded = true,
  });

  final String? url;
  final String title;
  final bool expanded;

  @override
  State<StreamPlayer> createState() => StreamPlayerState();
}

class StreamPlayerState extends State<StreamPlayer> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  String? _loadedUrl;
  bool _muted = false;

  Player get player => _player;

  @override
  void initState() {
    super.initState();
    _openIfNeeded(widget.url);
  }

  @override
  void didUpdateWidget(covariant StreamPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _openIfNeeded(widget.url);
    }
  }

  Future<void> _openIfNeeded(String? url) async {
    if (url == null || url.isEmpty) {
      await _player.stop();
      _loadedUrl = null;
      return;
    }
    if (url == _loadedUrl) return;
    _loadedUrl = url;
    await _player.open(Media(url), play: true);
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    await _player.setVolume(_muted ? 0 : 100);
    setState(() {});
  }

  Future<void> togglePlay() async {
    await _player.playOrPause();
    setState(() {});
  }

  @override
  void dispose() {
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
        child: AspectRatio(aspectRatio: 16 / 9, child: video),
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black, child: video),
            if (widget.url == null)
              const Center(
                child: Text('Select a server', style: TextStyle(color: FctvColors.textSecondary)),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Row(
                children: [
                  _RoundBtn(icon: Icons.play_arrow, onTap: togglePlay),
                  const SizedBox(width: 8),
                  _RoundBtn(
                    icon: _muted ? Icons.volume_off : Icons.volume_up,
                    onTap: toggleMute,
                  ),
                  const Spacer(),
                  Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}
