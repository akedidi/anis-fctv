import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/country.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import 'tv_focus.dart';

/// Headers required by rblive logo CDNs (same as iOS Kingfisher modifier).
const logoHeaders = <String, String>{
  'User-Agent': 'rbapp/--dg-snd-app-33/3.3.0/ios/FCTV33',
  'Referer': 'https://www.rbtv77.com/',
  'Origin': 'https://www.rbtv77.com',
};

class RemoteLogo extends StatelessWidget {
  const RemoteLogo({
    super.key,
    this.url,
    required this.name,
    this.size = 22,
    this.cornerRadius,
    this.lightBadge = false,
    this.fit = BoxFit.contain,
  });
  final String? url;
  final String name;
  final double size;
  final double? cornerRadius;
  final bool lightBadge;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final radius = cornerRadius ?? size / 2;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: lightBadge ? Colors.white.withValues(alpha: 0.92) : FctvColors.surfaceMuted,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
          color: lightBadge ? Colors.black54 : Colors.white,
        ),
      ),
    );
    if (url == null || url!.isEmpty) return fallback;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: lightBadge ? Colors.white.withValues(alpha: 0.92) : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(size * 0.12),
        child: Image.network(
          url!,
          width: size,
          height: size,
          fit: fit,
          headers: logoHeaders,
          errorBuilder: (_, __, ___) => fallback,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return SizedBox(
              width: size * 0.4,
              height: size * 0.4,
              child: const CircularProgressIndicator(strokeWidth: 1.5, color: FctvColors.accent),
            );
          },
        ),
      ),
    );
  }
}

class CountryFlag extends StatelessWidget {
  const CountryFlag({super.key, this.code, this.url, this.width = 28, this.height = 20});
  final String? code;
  final String? url;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final flagUrl = url ?? CountryHelper.flagCDNURL(code, width: 80);
    final emoji = CountryHelper.flagEmoji(code);

    Widget content;
    if (flagUrl != null) {
      content = Image.network(
        flagUrl,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _emojiOrTv(emoji),
      );
    } else {
      content = _emojiOrTv(emoji);
    }

    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }

  Widget _emojiOrTv(String? emoji) {
    if (emoji != null) {
      return Text(emoji, style: TextStyle(fontSize: height * 0.85, height: 1));
    }
    return Icon(Icons.tv_rounded, size: height * 0.75, color: FctvColors.textMuted);
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
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

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

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.match});
  final LiveMatch match;

  @override
  Widget build(BuildContext context) {
    if (match.isFinished) {
      return const _Pill(label: 'FT', color: FctvColors.textMuted);
    }
    if (match.isLive) {
      // Compact chip only — kickoff / minute live in the time column (iOS StatusBadge).
      final label = (match.liveClock != null && match.liveClock!.isNotEmpty) ? match.liveClock! : 'LIVE';
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LiveDot(size: 6),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: FctvColors.clock,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      );
    }
    if (match.hasStreams || match.streams.isNotEmpty) {
      return const Icon(Icons.play_circle_outline, size: 16, color: FctvColors.accent);
    }
    return const SizedBox.shrink();
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 10),
      ),
    );
  }
}

class MatchRowCard extends StatefulWidget {
  const MatchRowCard({
    super.key,
    required this.match,
    required this.selected,
    required this.onTap,
    this.compact = false,
    this.onMoveToFullscreen,
  });

  final LiveMatch match;
  final bool selected;
  final VoidCallback onTap;
  /// Right from this row. Returns true when focus moved to the video fullscreen button.
  final bool Function()? onMoveToFullscreen;
  /// Denser row for Android TV / leanback — more matches visible.
  final bool compact;

  @override
  State<MatchRowCard> createState() => _MatchRowCardState();
}

class _MatchRowCardState extends State<MatchRowCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    final selected = widget.selected;
    final compact = widget.compact;
    final sides = match.meaningfulContenders;
    final home = sides.isNotEmpty ? sides[0] : null;
    final away = sides.length > 1 ? sides[1] : null;
    final time = match.timeLabel;
    final date = match.dateLabel;
    final isToday = match.isKickoffToday;
    final radius = compact ? 10.0 : 14.0;
    final pad = compact ? const EdgeInsets.fromLTRB(8, 6, 8, 6) : const EdgeInsets.fromLTRB(12, 10, 12, 10);
    final tv = isAndroidTv || compact;

    final body = Container(
      padding: pad,
      decoration: BoxDecoration(
        color: _focused
            ? FctvColors.accent.withValues(alpha: 0.18)
            : selected
                ? const Color(0x28FFAE01)
                : FctvColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: _focused
              ? FctvColors.accent
              : selected
                  ? FctvColors.accent.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.06),
          width: _focused ? 3 : 1,
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: FctvColors.accent.withValues(alpha: 0.45),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RemoteLogo(
                url: match.leagueLogoUrl,
                name: match.leagueName,
                size: compact ? 14 : 18,
                cornerRadius: 4,
                lightBadge: true,
              ),
              SizedBox(width: compact ? 6 : 8),
              Expanded(
                child: Text(
                  match.leagueName.isEmpty
                      ? (match.region.isEmpty ? 'Competition' : match.region)
                      : match.leagueName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: FctvColors.textSecondary,
                    fontSize: compact ? 10 : 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              StatusBadge(match: match),
            ],
          ),
          SizedBox(height: compact ? 5 : 10),
          if (match.isVersus)
            Row(
              children: [
                _TimeCol(
                  date: isToday ? null : date,
                  kickoff: time,
                  clock: match.isCurrentlyLive ? match.liveClock : null,
                  finished: match.isFinished,
                  compact: compact,
                ),
                SizedBox(width: compact ? 6 : 8),
                Expanded(
                  child: _VersusTeam(
                    name: home?.name ?? '',
                    logo: home?.logoUrl,
                    alignEnd: false,
                    compact: compact,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 6),
                  child: Text(
                    match.scoreText,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: compact ? 12 : 14,
                      color: match.isFinished ? FctvColors.textTertiary : Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  child: _VersusTeam(
                    name: away?.name ?? '',
                    logo: away?.logoUrl,
                    alignEnd: true,
                    compact: compact,
                  ),
                ),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _TimeCol(
                  date: isToday ? null : date,
                  kickoff: time,
                  clock: match.isCurrentlyLive ? match.liveClock : null,
                  finished: match.isFinished,
                  compact: compact,
                ),
                SizedBox(width: compact ? 8 : 12),
                _SoloEventLogo(match: match, compact: compact),
                SizedBox(width: compact ? 8 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        match.displayName,
                        maxLines: compact ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: compact ? 12 : 16),
                      ),
                      if (match.scoreText.isNotEmpty && match.scoreText != 'VS') ...[
                        SizedBox(height: compact ? 2 : 4),
                        Text(
                          match.scoreText,
                          style: TextStyle(
                            color: FctvColors.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontSize: compact ? 10 : 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );

    if (tv) {
      return TvFocusable(
        onActivate: widget.onTap,
        borderRadius: radius,
        scale: 1.06,
        onKey: (event) {
          if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowRight) {
            return KeyEventResult.ignored;
          }
          if (widget.onMoveToFullscreen?.call() == true) return KeyEventResult.handled;
          return KeyEventResult.ignored;
        },
        child: body,
      );
    }

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: widget.onTap,
        onFocusChange: (v) => setState(() => _focused = v),
        focusColor: FctvColors.accent.withValues(alpha: 0.28),
        hoverColor: FctvColors.accent.withValues(alpha: 0.12),
        child: body,
      ),
    );
  }
}

class _TimeCol extends StatelessWidget {
  const _TimeCol({
    this.date,
    required this.kickoff,
    this.clock,
    this.finished = false,
    this.compact = false,
  });
  final String? date;
  final String kickoff;
  final String? clock;
  final bool finished;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final kickSize = compact ? 10.0 : 12.0;
    final clockSize = compact ? 11.0 : 13.0;
    return SizedBox(
      width: compact ? 40 : 52,
      child: Column(
        children: [
          if (date != null)
            Text(
              date!,
              style: TextStyle(
                fontSize: compact ? 8 : 10,
                fontWeight: FontWeight.w600,
                color: FctvColors.textTertiary,
              ),
            ),
          Text(
            kickoff,
            style: TextStyle(
              fontSize: kickSize,
              fontWeight: FontWeight.w600,
              color: FctvColors.textSecondary,
            ),
          ),
          if (finished)
            Text('FT', style: TextStyle(fontSize: clockSize, fontWeight: FontWeight.w800, color: FctvColors.textTertiary))
          else if (clock != null && clock!.isNotEmpty)
            Text(
              clock!,
              style: TextStyle(fontSize: clockSize, fontWeight: FontWeight.w800, color: FctvColors.clock),
            ),
        ],
      ),
    );
  }
}

class _VersusTeam extends StatelessWidget {
  const _VersusTeam({
    required this.name,
    this.logo,
    this.alignEnd = false,
    this.compact = false,
  });
  final String name;
  final String? logo;
  final bool alignEnd;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (name.isEmpty) return SizedBox(height: compact ? 22 : 44);
    final logoSize = compact ? 18.0 : 28.0;
    final nameStyle = TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: compact ? 11 : 13,
    );
    if (compact) {
      // Single-line: logo + name — much shorter rows on TV.
      final logoW = RemoteLogo(url: logo, name: name, size: logoSize);
      final nameW = Expanded(
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignEnd ? TextAlign.end : TextAlign.start,
          style: nameStyle,
        ),
      );
      return Row(
        children: alignEnd
            ? [nameW, const SizedBox(width: 5), logoW]
            : [logoW, const SizedBox(width: 5), nameW],
      );
    }
    final kids = <Widget>[
      RemoteLogo(url: logo, name: name, size: logoSize),
      const SizedBox(height: 6),
      Text(
        name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: alignEnd ? TextAlign.end : TextAlign.start,
        style: nameStyle,
      ),
    ];
    return Column(
      crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: kids,
    );
  }
}

class _SoloEventLogo extends StatelessWidget {
  const _SoloEventLogo({required this.match, this.compact = false});
  final LiveMatch match;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 26.0 : 36.0;
    final side = match.meaningfulContenders.isNotEmpty ? match.meaningfulContenders.first : null;
    if (side?.logoUrl != null && side!.logoUrl!.isNotEmpty) {
      return RemoteLogo(url: side.logoUrl, name: side.name, size: size);
    }
    if (match.leagueLogoUrl != null && match.leagueLogoUrl!.isNotEmpty) {
      return RemoteLogo(
        url: match.leagueLogoUrl,
        name: match.leagueName.isEmpty ? match.displayName : match.leagueName,
        size: size,
        cornerRadius: 10,
        lightBadge: true,
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.sports, size: compact ? 14 : 20, color: FctvColors.textSecondary),
    );
  }
}

class EventTimeline extends StatelessWidget {
  const EventTimeline({super.key, required this.events});
  final List<MatchEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No timeline events for this match yet.',
          style: TextStyle(color: FctvColors.textTertiary, fontSize: 13),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < events.length; i++) ...[
          _EventRow(event: events[i], last: i == events.length - 1),
        ],
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.last});
  final MatchEvent event;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final accent = event.accent;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(
              event.minute?.isEmpty == true ? '—' : (event.minute ?? '—'),
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(event.icon, size: 12, color: accent),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: Colors.white12,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 14),
              child: Text(
                event.text,
                style: TextStyle(
                  color: event.kind == 'goal' ? FctvColors.accent : Colors.white.withValues(alpha: 0.9),
                  fontWeight: event.kind == 'goal' ? FontWeight.w700 : FontWeight.w500,
                  height: 1.3,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StreamServerTile extends StatelessWidget {
  const StreamServerTile({
    super.key,
    required this.server,
    required this.active,
    required this.onTap,
    this.matchRegion = '',
    this.expand = false,
    /// When false, parent (e.g. [TvFocusable]) owns focus — avoids nested focus nodes.
    this.canRequestFocus = true,
  });

  final StreamServer server;
  final bool active;
  final VoidCallback onTap;
  final String matchRegion;
  /// When true, fill the grid cell width (used in multi-column Wrap).
  final bool expand;
  final bool canRequestFocus;

  @override
  Widget build(BuildContext context) {
    final hint = CountryHelper.infer(
      streamName: '${server.name} ${server.fullName}',
      matchRegion: matchRegion,
    );
    final code = server.countryCode ?? hint.code;
    final flagUrl = server.flagUrl ?? CountryHelper.flagCDNURL(code);

    final chip = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        canRequestFocus: canRequestFocus,
        borderRadius: BorderRadius.circular(10),
        focusColor: FctvColors.accent.withValues(alpha: 0.28),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: expand ? double.infinity : null,
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
          decoration: BoxDecoration(
            color: active ? const Color(0x2EFFAE01) : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? FctvColors.accent.withValues(alpha: 0.55) : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              CountryFlag(code: code, url: flagUrl, width: 22, height: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: active ? Colors.white : Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Prevent InkWell from eating the full Wrap row width.
    if (expand) return chip;
    return Align(alignment: Alignment.centerLeft, widthFactor: 1, heightFactor: 1, child: chip);
  }
}

/// Horizontal server rail for TV — pick a stream without vertical scroll.
class StreamServerRail extends StatelessWidget {
  const StreamServerRail({
    super.key,
    required this.servers,
    required this.activeServerId,
    required this.onServer,
    this.matchRegion = '',
    this.firstFocus,
  });

  final List<StreamServer> servers;
  final String? activeServerId;
  final ValueChanged<StreamServer> onServer;
  final String matchRegion;
  final FocusNode? firstFocus;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: servers.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (context, i) {
        final s = servers[i];
        return SizedBox(
          width: 168,
          child: TvFocusable(
            focusNode: i == 0 ? firstFocus : null,
            onActivate: () => onServer(s),
            borderRadius: 10,
            scale: 1.06,
            child: StreamServerTile(
              server: s,
              active: s.id == activeServerId,
              matchRegion: matchRegion,
              expand: true,
              canRequestFocus: false,
              onTap: () => onServer(s),
            ),
          ),
        );
      },
    );
  }
}

/// Multi-column server chips — 2–4 per row depending on width.
class StreamServerGrid extends StatelessWidget {
  const StreamServerGrid({
    super.key,
    required this.servers,
    required this.activeServerId,
    required this.onServer,
    this.matchRegion = '',
  });

  final List<StreamServer> servers;
  final String? activeServerId;
  final ValueChanged<StreamServer> onServer;
  final String matchRegion;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final width = constraints.maxWidth;
        final cols = width >= 720
            ? 4
            : width >= 520
                ? 3
                : 2;
        final tileW = (width - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final s in servers)
              SizedBox(
                width: tileW,
                child: StreamServerTile(
                  server: s,
                  active: s.id == activeServerId,
                  matchRegion: matchRegion,
                  expand: true,
                  onTap: () => onServer(s),
                ),
              ),
          ],
        );
      },
    );
  }
}
