import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/tv_focus.dart';
import '../../shared/widgets.dart';

/// Leanback detail: event title stretches full width; player + Overview sit
/// below it (player frame pushed down).
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
    this.firstServerFocus,
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
  final FocusNode? firstServerFocus;

  @override
  Widget build(BuildContext context) {
    final sides = match.meaningfulContenders;
    final home = sides.isNotEmpty ? sides[0] : null;
    final away = sides.length > 1 ? sides[1] : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Full-width title / score — spreads across the whole detail pane.
          _TvScoreStrip(match: match, home: home, away: away),
          const SizedBox(height: 12),
          // Player (left) sits lower; Overview tabs align with it on the right.
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 12,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        player,
                        const SizedBox(height: 8),
                        Text(
                          resolving ? 'Servers · resolving…' : 'Servers',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: FctvColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 52,
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
                                  firstFocus: firstServerFocus,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 10,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 72),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TvDetailTabRow(tab: tab, onTab: onTab),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _TvTabBodyScroll(tab: tab, child: tabBody),
                        ),
                      ],
                    ),
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

/// Focusable viewport under the tab row. Down from the tabs lands here;
/// Up/Down then scroll, and Up at the top returns to the tabs.
class _TvTabBodyScroll extends StatefulWidget {
  const _TvTabBodyScroll({required this.tab, required this.child});

  final int tab;
  final Widget child;

  @override
  State<_TvTabBodyScroll> createState() => _TvTabBodyScrollState();
}

class _TvTabBodyScrollState extends State<_TvTabBodyScroll> {
  final _controller = ScrollController();
  final _focus = FocusNode(debugLabel: 'tv tab body');
  bool _focused = false;

  @override
  void didUpdateWidget(covariant _TvTabBodyScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab != widget.tab && _controller.hasClients) {
      _controller.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    if (!_controller.hasClients) {
      return up ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    final pos = _controller.position;
    if (up && pos.pixels <= pos.minScrollExtent + 1) {
      return KeyEventResult.ignored;
    }
    if (down && pos.pixels >= pos.maxScrollExtent - 1) {
      return KeyEventResult.handled;
    }
    final step = (pos.viewportDimension * 0.42).clamp(80.0, 240.0);
    final target = (pos.pixels + (down ? step : -step)).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (event is KeyRepeatEvent) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: _onKey,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? FctvColors.accent : Colors.transparent,
            width: 3,
          ),
        ),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: _focused,
          child: SingleChildScrollView(
            controller: _controller,
            padding: const EdgeInsets.all(4),
            child: widget.child,
          ),
        ),
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
              scale: 1,
              fillOnFocus: tab != _tabs[i].$1,
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
  const _TvScoreStrip({required this.match, this.home, this.away});
  final LiveMatch match;
  final Contender? home;
  final Contender? away;

  @override
  Widget build(BuildContext context) {
    final clock = match.isFinished
        ? 'FT'
        : (match.liveClock?.isNotEmpty == true ? match.liveClock! : match.timeLabel);
    final clockColor = match.isCurrentlyLive && match.liveClock != null
        ? FctvColors.clock
        : FctvColors.textSecondary;

    if (!match.isVersus) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                match.displayName,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 34,
                  height: 1.12,
                ),
              ),
            ),
            const SizedBox(width: 20),
            Text(
              clock,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: clockColor,
              ),
            ),
          ],
        ),
      );
    }

    final homeName = home?.name ?? match.name;
    final awayName = away?.name ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (home != null) ...[
            RemoteLogo(url: home!.logoUrl, name: homeName, size: 48),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Text(
              homeName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 28,
                height: 1.12,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  clock,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: clockColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  match.scoreTextSpaced,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 36,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              awayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 28,
                height: 1.12,
              ),
            ),
          ),
          if (away != null) ...[
            const SizedBox(width: 14),
            RemoteLogo(url: away!.logoUrl, name: awayName, size: 48),
          ],
        ],
      ),
    );
  }
}
