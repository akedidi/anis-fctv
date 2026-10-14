import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/tv_focus.dart';
import '../../shared/widgets.dart';

/// Leanback detail: video + server rail stay visible; tab content scrolls only in the side panel.
class TvDetailLayout extends StatelessWidget {
  const TvDetailLayout({
    super.key,
    required this.match,
    required this.servers,
    required this.activeServerId,
    required this.player,
    required this.resolving,
    required this.tab,
    required this.tabBody,
    required this.onServer,
    required this.onTab,
  });

  final LiveMatch match;
  final List<StreamServer> servers;
  final String? activeServerId;
  final Widget player;
  final bool resolving;
  final int tab;
  final Widget tabBody;
  final ValueChanged<StreamServer> onServer;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    final sides = match.meaningfulContenders;
    final home = sides.isNotEmpty ? sides[0].name : match.name;
    final away = sides.length > 1 ? sides[1].name : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TvScoreStrip(match: match, home: home, away: away),
                const SizedBox(height: 6),
                Expanded(
                  child: Center(child: player),
                ),
                const SizedBox(height: 8),
                Text(
                  resolving ? 'Servers · resolving…' : 'Servers',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: FctvColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 54,
                  child: servers.isEmpty
                      ? const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Loading servers…',
                            style: TextStyle(color: FctvColors.textTertiary, fontSize: 13),
                          ),
                        )
                      : StreamServerRail(
                          servers: servers,
                          activeServerId: activeServerId,
                          matchRegion: match.region,
                          onServer: onServer,
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TvDetailTabRow(tab: tab, onTab: onTab),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.zero,
                    child: tabBody,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TvDetailTabRow extends StatelessWidget {
  const TvDetailTabRow({super.key, required this.tab, required this.onTab});
  final int tab;
  final ValueChanged<int> onTab;

  static const _tabs = [(0, 'Overview'), (1, 'Lineups'), (2, 'Stats'), (3, 'H2H')];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _tabs.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: TvFocusable(
              onActivate: () => onTab(_tabs[i].$1),
              borderRadius: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tab == _tabs[i].$1
                      ? FctvColors.accent
                      : Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _tabs[i].$2,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: tab == _tabs[i].$1 ? Colors.black : Colors.white70,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _TvScoreStrip extends StatelessWidget {
  const _TvScoreStrip({required this.match, required this.home, required this.away});
  final LiveMatch match;
  final String home;
  final String away;

  @override
  Widget build(BuildContext context) {
    final clock = match.isFinished
        ? 'FT'
        : (match.liveClock?.isNotEmpty == true ? match.liveClock! : match.timeLabel);
    return Row(
      children: [
        Expanded(
          child: Text(
            home,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            children: [
              Text(
                clock,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: match.isCurrentlyLive ? FctvColors.clock : FctvColors.textSecondary,
                ),
              ),
              Text(
                match.scoreTextSpaced,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
              ),
            ],
          ),
        ),
        Expanded(
          child: Text(
            away,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
        ),
      ],
    );
  }
}
