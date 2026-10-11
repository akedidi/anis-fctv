import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../player/stream_player.dart';

enum HomeFilter { all, live, finished }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = FctvApi();
  final _searchCtrl = TextEditingController();
  final _playerKey = GlobalKey<StreamPlayerState>();

  int _sportType = 0;
  HomeFilter _filter = HomeFilter.all;
  String _query = '';
  bool _loading = true;
  String? _error;
  List<LiveMatch> _matches = [];
  LiveMatch? _selected;
  List<StreamServer> _servers = [];
  String? _activeServerId;
  String? _playableUrl;
  bool _resolving = false;
  bool _showMore = false;
  bool _mini = false;
  bool _fullscreen = false;
  int _tab = 0;
  List<MatchEvent> _events = [];
  List<LineupPlayer> _homeLineup = [];
  List<LineupPlayer> _awayLineup = [];

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _api.fetchLive(sportType: _sportType);
      setState(() => _matches = list);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  List<LiveMatch> get _filtered {
    Iterable<LiveMatch> list = _matches;
    if (_filter == HomeFilter.live) {
      list = list.where((m) => !m.isFinished);
    } else if (_filter == HomeFilter.finished) {
      list = list.where((m) => m.isFinished);
    }
    if (_query.isNotEmpty) {
      list = list.where((m) {
        final hay = [
          m.name,
          m.leagueName,
          m.region,
          ...m.contenders.map((c) => c.name),
        ].join(' ').toLowerCase();
        return hay.contains(_query);
      });
    }
    return list.toList();
  }

  Future<void> _openMatch(LiveMatch match) async {
    setState(() {
      _selected = match;
      _mini = false;
      _playableUrl = null;
      _activeServerId = null;
      _tab = 0;
      _resolving = true;
      _events = [];
      _homeLineup = [];
      _awayLineup = [];
    });
    try {
      final detail = await _api.fetchMatchDetail(
        matchId: match.matchId,
        sportType: match.sportType,
      );
      final merged = (detail.match ?? match).copyWith(
        streams: detail.streams.isNotEmpty ? detail.streams : match.streams,
      );
      final servers = merged.streams.where((s) => s.hasReliableName).toList();
      final list = servers.isNotEmpty ? servers : merged.streams;
      setState(() {
        _selected = merged;
        _servers = list;
      });
      if (list.isNotEmpty) await _playServer(merged, list.first);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _servers = match.streams;
      });
    } finally {
      setState(() => _resolving = false);
    }

    final events = await _api.fetchEvents(matchId: match.matchId, sportType: match.sportType);
    final lineup = await _api.fetchLineup(matchId: match.matchId, sportType: match.sportType);
    if (!mounted || _selected?.matchId != match.matchId) return;
    setState(() {
      _events = events;
      _homeLineup = lineup.home.where((p) => p.isStarter).toList()
        ..sort((a, b) => a.positionOrder.compareTo(b.positionOrder));
      _awayLineup = lineup.away.where((p) => p.isStarter).toList()
        ..sort((a, b) => a.positionOrder.compareTo(b.positionOrder));
    });
  }

  Future<void> _playServer(LiveMatch match, StreamServer server) async {
    setState(() {
      _activeServerId = server.id;
      _resolving = true;
      _error = null;
    });
    try {
      final url = await _api.resolvePlayback(
        matchId: match.matchId,
        sportType: match.sportType,
        streamId: server.streamId,
      );
      setState(() => _playableUrl = url);
    } catch (e) {
      setState(() {
        _playableUrl = null;
        _error = e.toString();
      });
    } finally {
      setState(() => _resolving = false);
    }
  }

  Future<void> _enterFullscreen() async {
    if (_playableUrl == null) return;
    // Unmount inline player first so the same GlobalKey can host fullscreen without audio tear-down races.
    setState(() {
      _fullscreen = true;
      _mini = false;
    });
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => _FullscreenRoute(
          playerKey: _playerKey,
          title: _selected?.name ?? '',
          url: _playableUrl,
        ),
      ),
    );
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    if (mounted) setState(() => _fullscreen = false);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final list = _filtered;
    final liveCount = _matches.where((m) => m.isLive && !m.isFinished).length;

    final left = _LeftPane(
      sportType: _sportType,
      showMore: _showMore,
      filter: _filter,
      liveCount: liveCount,
      loading: _loading,
      error: _error,
      searchCtrl: _searchCtrl,
      matches: list,
      selectedId: _selected?.matchId,
      onRefresh: _load,
      onSport: (t) {
        setState(() {
          _sportType = t;
          _showMore = false;
        });
        _load();
      },
      onToggleMore: () => setState(() => _showMore = !_showMore),
      onFilter: (f) => setState(() => _filter = f),
      onOpen: _openMatch,
    );

    final right = _selected == null
        ? const _EmptyDetail()
        : _DetailPane(
            match: _selected!,
            servers: _servers,
            activeServerId: _activeServerId,
            playableUrl: _playableUrl,
            resolving: _resolving,
            mini: _mini,
            fullscreen: _fullscreen,
            tab: _tab,
            events: _events,
            homeLineup: _homeLineup,
            awayLineup: _awayLineup,
            playerKey: _playerKey,
            onServer: (s) => _playServer(_selected!, s),
            onTab: (t) => setState(() => _tab = t),
            onToggleMini: () => setState(() => _mini = !_mini),
            onFullscreen: _enterFullscreen,
          );

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [FctvColors.headerStart, FctvColors.background, FctvColors.backgroundDeep],
          ),
        ),
        child: wide
            ? Row(
                children: [
                  SizedBox(width: 400, child: left),
                  const VerticalDivider(width: 1, color: Colors.white10),
                  Expanded(child: right),
                ],
              )
            : _selected == null
                ? left
                : Column(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => _selected = null),
                          icon: const Icon(Icons.arrow_back),
                          label: const Text('Events'),
                        ),
                      ),
                      Expanded(child: right),
                    ],
                  ),
      ),
      bottomNavigationBar: _mini && !_fullscreen && _playableUrl != null && _selected != null
          ? Material(
              color: FctvColors.surfaceElevated,
              child: SafeArea(
                child: ListTile(
                  leading: SizedBox(
                    width: 96,
                    child: StreamPlayer(
                      key: _playerKey,
                      url: _playableUrl,
                      title: _selected!.name,
                      expanded: false,
                    ),
                  ),
                  title: Text(_selected!.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    _servers.where((s) => s.id == _activeServerId).map((s) => s.name).firstOrNull ?? 'Live',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _mini = false;
                      _playableUrl = null;
                    }),
                  ),
                  onTap: () => setState(() => _mini = false),
                ),
              ),
            )
          : null,
    );
  }
}

class _LeftPane extends StatelessWidget {
  const _LeftPane({
    required this.sportType,
    required this.showMore,
    required this.filter,
    required this.liveCount,
    required this.loading,
    required this.error,
    required this.searchCtrl,
    required this.matches,
    required this.selectedId,
    required this.onRefresh,
    required this.onSport,
    required this.onToggleMore,
    required this.onFilter,
    required this.onOpen,
  });

  final int sportType;
  final bool showMore;
  final HomeFilter filter;
  final int liveCount;
  final bool loading;
  final String? error;
  final TextEditingController searchCtrl;
  final List<LiveMatch> matches;
  final int? selectedId;
  final VoidCallback onRefresh;
  final ValueChanged<int> onSport;
  final VoidCallback onToggleMore;
  final ValueChanged<HomeFilter> onFilter;
  final ValueChanged<LiveMatch> onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(colors: [FctvColors.accent, Color(0xFFFF6B01)]),
                ),
                child: const Text('F', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 20)),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('FCTV33', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, letterSpacing: 1.5)),
                    Text('Live Sports · Anywhere', style: TextStyle(color: FctvColors.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              TextButton(onPressed: onRefresh, child: const Text('Refresh')),
            ],
          ),
        ),
        SizedBox(
          height: 84,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              ...primarySports.map((s) => _SportChip(
                    tab: s,
                    active: sportType == s.type && !showMore,
                    onTap: () => onSport(s.type),
                  )),
              _SportChip(
                tab: const SportTab(-1, 'More', Icons.add),
                active: showMore,
                onTap: onToggleMore,
              ),
            ],
          ),
        ),
        if (showMore)
          SizedBox(
            height: 84,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: moreSports
                  .map((s) => _SportChip(tab: s, active: sportType == s.type, onTap: () => onSport(s.type)))
                  .toList(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search teams, leagues, events…',
              filled: true,
              fillColor: Colors.white10,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              _FilterChip(label: 'All', active: filter == HomeFilter.all, onTap: () => onFilter(HomeFilter.all)),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Live $liveCount',
                active: filter == HomeFilter.live,
                live: true,
                onTap: () => onFilter(HomeFilter.live),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Finished',
                active: filter == HomeFilter.finished,
                onTap: () => onFilter(HomeFilter.finished),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(error!, style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 12)),
          ),
        if (loading) const LinearProgressIndicator(minHeight: 2, color: FctvColors.accent),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
            itemCount: matches.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final m = matches[i];
              return Focus(
                child: MatchRowCard(
                  match: m,
                  selected: selectedId == m.matchId,
                  onTap: () => onOpen(m),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SportChip extends StatelessWidget {
  const _SportChip({required this.tab, required this.active, required this.onTap});
  final SportTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 72,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? FctvColors.accent : Colors.white10,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Icon(tab.icon, color: active ? Colors.black : Colors.white70, size: 22),
              const SizedBox(height: 4),
              Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.black : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.active, required this.onTap, this.live = false});
  final String label;
  final bool active;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? const Color(0x33FFAE01) : Colors.white10,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            if (live) ...[const LiveDot(), const SizedBox(width: 6)],
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: active ? FctvColors.accent : FctvColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Select a Match', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          SizedBox(height: 8),
          Text(
            'Pick an event on the left to open servers, lineup, and live playback.',
            textAlign: TextAlign.center,
            style: TextStyle(color: FctvColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _DetailPane extends StatelessWidget {
  const _DetailPane({
    required this.match,
    required this.servers,
    required this.activeServerId,
    required this.playableUrl,
    required this.resolving,
    required this.mini,
    required this.fullscreen,
    required this.tab,
    required this.events,
    required this.homeLineup,
    required this.awayLineup,
    required this.playerKey,
    required this.onServer,
    required this.onTab,
    required this.onToggleMini,
    required this.onFullscreen,
  });

  final LiveMatch match;
  final List<StreamServer> servers;
  final String? activeServerId;
  final String? playableUrl;
  final bool resolving;
  final bool mini;
  final bool fullscreen;
  final int tab;
  final List<MatchEvent> events;
  final List<LineupPlayer> homeLineup;
  final List<LineupPlayer> awayLineup;
  final GlobalKey<StreamPlayerState> playerKey;
  final ValueChanged<StreamServer> onServer;
  final ValueChanged<int> onTab;
  final VoidCallback onToggleMini;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final home = match.contenders.isNotEmpty ? match.contenders[0] : null;
    final away = match.contenders.length > 1 ? match.contenders[1] : null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        Row(
          children: [
            RemoteLogo(url: match.leagueLogoUrl, name: match.leagueName, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                match.leagueName.isEmpty ? 'Competition' : match.leagueName,
                style: const TextStyle(color: FctvColors.textMuted),
              ),
            ),
            if (match.region.isNotEmpty)
              Text(match.region, style: const TextStyle(color: FctvColors.textMuted, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _Side(name: home?.name ?? match.name, logo: home?.logoUrl)),
            Column(
              children: [
                Text(
                  '${match.homeScore ?? '–'} : ${match.awayScore ?? '–'}',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                ),
                if (match.isLive && !match.isFinished)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0x33E53935),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const LiveDot(),
                        const SizedBox(width: 6),
                        Text(match.liveClock ?? 'LIVE', style: const TextStyle(color: Color(0xFFFF8A80), fontWeight: FontWeight.w800, fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            ),
            Expanded(child: _Side(name: away?.name ?? '', logo: away?.logoUrl)),
          ],
        ),
        const SizedBox(height: 16),
        if (!mini && !fullscreen)
          StreamPlayer(
            key: playerKey,
            url: playableUrl,
            title: servers.where((s) => s.id == activeServerId).map((s) => s.name).firstOrNull ?? match.name,
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              resolving ? 'SERVERS · resolving…' : 'SERVERS',
              style: const TextStyle(
                letterSpacing: 1.2,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: FctvColors.textMuted,
              ),
            ),
            const Spacer(),
            if (playableUrl != null) ...[
              TextButton(onPressed: onToggleMini, child: Text(mini ? 'Expand' : 'Mini')),
              TextButton.icon(
                onPressed: onFullscreen,
                icon: const Icon(Icons.fullscreen),
                label: const Text('Full'),
              ),
            ],
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: servers.map((s) {
            final active = s.id == activeServerId;
            return InkWell(
              onTap: () => onServer(s),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 180,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: active ? const Color(0x22FFAE01) : FctvColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: active ? FctvColors.accent : Colors.transparent),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          if (s.country.isNotEmpty || s.fullName.isNotEmpty)
                            Text(
                              s.country.isNotEmpty ? s.country : s.fullName,
                              style: const TextStyle(color: FctvColors.textTertiary, fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                    Icon(active ? Icons.check : Icons.play_arrow, size: 18),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            for (final e in const [(0, 'Overview'), (1, 'Lineups'), (2, 'Stats'), (3, 'H2H')])
              ChoiceChip(
                label: Text(e.$2),
                selected: tab == e.$1,
                onSelected: (_) => onTab(e.$1),
                selectedColor: FctvColors.accent,
                labelStyle: TextStyle(
                  color: tab == e.$1 ? Colors.black : Colors.white70,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: FctvColors.surface.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: switch (tab) {
            1 => _Lineups(home: homeLineup, away: awayLineup, homeName: home?.name, awayName: away?.name),
            2 => const Text('Sample stats shell (same as iOS until API is wired).',
                style: TextStyle(color: FctvColors.textTertiary)),
            3 => const Text('Sample H2H shell (same as iOS until API is wired).',
                style: TextStyle(color: FctvColors.textTertiary)),
            _ => _Overview(match: match, events: events, serverCount: servers.length),
          },
        ),
      ],
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.name, this.logo});
  final String name;
  final String? logo;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        RemoteLogo(url: logo, name: name, size: 56),
        const SizedBox(height: 8),
        Text(name, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.match, required this.events, required this.serverCount});
  final LiveMatch match;
  final List<MatchEvent> events;
  final int serverCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Info('Competition', match.leagueName.isEmpty ? '—' : match.leagueName),
            _Info('Region', match.region.isEmpty ? '—' : match.region),
            _Info('Streams', '$serverCount'),
            _Info('Clock', match.liveClock ?? '—'),
          ],
        ),
        const SizedBox(height: 16),
        const Text('HIGHLIGHTS', style: TextStyle(letterSpacing: 1, fontSize: 12, fontWeight: FontWeight.w800, color: FctvColors.textMuted)),
        const SizedBox(height: 8),
        if (events.isEmpty)
          const Text('No events yet', style: TextStyle(color: FctvColors.textTertiary))
        else
          ...events.map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(e.minute ?? '', style: const TextStyle(color: FctvColors.clock, fontWeight: FontWeight.w800)),
                  ),
                  Expanded(
                    child: Text(
                      e.text,
                      style: TextStyle(color: e.kind == 'goal' ? FctvColors.accent : Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: FctvColors.textTertiary, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _Lineups extends StatelessWidget {
  const _Lineups({required this.home, required this.away, this.homeName, this.awayName});
  final List<LineupPlayer> home;
  final List<LineupPlayer> away;
  final String? homeName;
  final String? awayName;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _team(homeName ?? 'Home', home)),
        const SizedBox(width: 16),
        Expanded(child: _team(awayName ?? 'Away', away)),
      ],
    );
  }

  Widget _team(String title, List<LineupPlayer> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: const TextStyle(letterSpacing: 1, fontSize: 12, fontWeight: FontWeight.w800, color: FctvColors.textMuted)),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          const Text('Lineup unavailable', style: TextStyle(color: FctvColors.textTertiary))
        else
          ...rows.map(
            (p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(width: 28, child: Text(p.positionLabel.isEmpty ? (p.number ?? '') : p.positionLabel, style: const TextStyle(color: FctvColors.textTertiary, fontSize: 11))),
                  Expanded(child: Text(p.name)),
                  Text(p.number ?? '', style: const TextStyle(color: FctvColors.textTertiary)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Fullscreen keeps the same [StreamPlayer] key/player instance when possible.
/// Fallback: reopen same URL without tearing audio session aggressively.
class _FullscreenRoute extends StatelessWidget {
  const _FullscreenRoute({required this.playerKey, required this.title, required this.url});
  final GlobalKey<StreamPlayerState> playerKey;
  final String title;
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: StreamPlayer(
                key: playerKey,
                url: url,
                title: title,
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
