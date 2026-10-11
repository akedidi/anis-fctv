import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/theme.dart';

class RemoteLogo extends StatelessWidget {
  const RemoteLogo({super.key, this.url, required this.name, this.size = 22});
  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: FctvColors.surfaceMuted,
        shape: BoxShape.circle,
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(fontSize: size * 0.45, fontWeight: FontWeight.w800),
      ),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class LiveDot extends StatefulWidget {
  const LiveDot({super.key, this.size = 7});
  final double size;

  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = Curves.easeOut.transform(_c.value);
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: FctvColors.live,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: FctvColors.live.withValues(alpha: (1 - t) * 0.55),
                blurRadius: 8 * t,
                spreadRadius: 6 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

class MatchRowCard extends StatelessWidget {
  const MatchRowCard({
    super.key,
    required this.match,
    required this.selected,
    required this.onTap,
  });

  final LiveMatch match;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final home = match.contenders.isNotEmpty ? match.contenders[0] : null;
    final away = match.contenders.length > 1 ? match.contenders[1] : null;
    final start = DateTime.fromMillisecondsSinceEpoch(match.startDateMs);
    final time =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    final date = '${start.day.toString().padLeft(2, '0')} ${_month(start.month)}';
    final today = DateTime.now();
    final isToday =
        start.year == today.year && start.month == today.month && start.day == today.day;

    return Material(
      color: selected
          ? const Color(0x22FFAE01)
          : FctvColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        focusColor: FctvColors.accent.withValues(alpha: 0.2),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? FctvColors.accent : Colors.white10,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  RemoteLogo(url: match.leagueLogoUrl, name: match.leagueName, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      match.leagueName.isEmpty ? match.region : match.leagueName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: FctvColors.textMuted, fontSize: 12),
                    ),
                  ),
                  if (match.isLive && !match.isFinished) const LiveDot(),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Column(
                      children: [
                        if (!isToday)
                          Text(date, style: const TextStyle(fontSize: 11, color: FctvColors.textTertiary)),
                        Text(
                          match.isLive && match.liveClock != null
                              ? match.liveClock!
                              : match.isFinished
                                  ? 'FT'
                                  : time,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: match.isLive ? FctvColors.clock : FctvColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        _teamLine(home?.name ?? match.name, home?.logoUrl),
                        const SizedBox(height: 6),
                        _teamLine(away?.name ?? '', away?.logoUrl),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${match.homeScore ?? '–'}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: match.isFinished ? FctvColors.textTertiary : Colors.white,
                        ),
                      ),
                      Text(
                        '${match.awayScore ?? '–'}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: match.isFinished ? FctvColors.textTertiary : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _teamLine(String name, String? logo) {
    if (name.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        RemoteLogo(url: logo, name: name, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  static String _month(int m) =>
      const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1];
}
