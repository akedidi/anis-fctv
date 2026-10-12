import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../shared/widgets.dart';
import '../../web_boot.dart' if (dart.library.io) '../../web_boot_stub.dart';
import '../player/stream_player.dart';
import '../player/web_hls_surface_stub.dart'
    if (dart.library.html) '../player/web_hls_surface_web.dart';

enum HomeFilter { all, live, finished }

/// Mirrors iOS phone / split presentation.
enum _ShellLayout { phone, split }

_ShellLayout _shellLayoutFor(double width) => width < 840 ? _ShellLayout.phone : _ShellLayout.split;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = FctvApi();
  final _searchCtrl = TextEditingController();
  final _playerKey = GlobalKey<StreamPlayerState>();

  /// Football first — "All" fans out many upstream calls and can return empty under rate limits.
  int _sportType = 1;
  HomeFilter _filter = HomeFilter.all;
  String _query = '';
  bool _loading = true;
  int _loadGen = 0;
  String? _error;
  List<LiveMatch> _matches = [];
  LiveMatch? _selected;
  List<StreamServer> _servers = [];
  String? _activeServerId;
  String? _playableUrl;
  int _playGen = 0;
  /// Incremented on every successful resolve so [StreamPlayer] always reopens HLS.
  int _loadToken = 0;
  bool _resolving = false;
  bool _mini = false;
  bool _fullscreen = false;
  int _tab = 0;
  List<MatchEvent> _events = [];
  List<LineupPlayer> _homeLineup = [];
  List<LineupPlayer> _awayLineup = [];
  List<MatchStatRow> _stats = [];
  H2HSummary _h2h = const H2HSummary();
  bool _detailLoading = false;
  /// Cancels in-flight historical/live highlight + detail polls when leaving a match.
  int _detailRefreshGen = 0;
  /// Per-sport event counts for tab / More badges (sportType → count).
  final Map<int, int> _sportCounts = {};
  int _countsGen = 0;

  /// Extra sports merged after primary tabs when browsing "All".
  static const _allExtraSports = [7, 9, 8, 4, 6, 11, 13, 14, 15, 16, 5, 10, 12, 17];
  static const _primaryBadgeTypes = {1, 2, 3, 90};

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
    // First paint = shell + empty table skeleton; fetch only after that frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      dismissWebBoot();
      _load(); // sport counts start after list load — avoids Cloudflare 429 fan-out
    });
  }

  int _countForSport(int type) {
    if (type == 0) {
      var sum = 0;
      for (final e in _sportCounts.entries) {
        if (e.key != 0) sum += e.value;
      }
      return sum;
    }
    return _sportCounts[type] ?? 0;
  }

  String? _badgeForSport(int type) {
    if (type == 0) {
      if (_sportCounts.isEmpty) return null;
      final n = _countForSport(0);
      return n > 0 ? '$n' : null;
    }
    if (!_sportCounts.containsKey(type)) return null;
    final n = _sportCounts[type]!;
    return n > 0 ? '$n' : null;
  }

  int get _moreSportsCount {
    var sum = 0;
    for (final s in allSports) {
      if (_primaryBadgeTypes.contains(s.type)) continue;
      sum += _sportCounts[s.type] ?? 0;
    }
    return sum;
  }

  void _setSportCount(int type, int count) {
    if (_sportCounts[type] == count) return;
    _sportCounts[type] = count;
  }

  /// Slow sequential counts — one request at a time so we don't 429 the live list.
  Future<void> _refreshSportCounts() async {
    final gen = ++_countsGen;
    // Primary tabs first (visible badges), then the More sheet sports.
    final seen = <int>{};
    final types = <int>[
      for (final s in primarySports)
        if (s.type != 0) s.type,
      for (final s in allSports) s.type,
    ].where(seen.add).toList();

    for (final st in types) {
      if (!mounted || gen != _countsGen) return;
      try {
        final list = await _api.fetchLive(sportType: st);
        if (!mounted || gen != _countsGen) return;
        setState(() => _setSportCount(st, list.length));
      } catch (_) {
        // Skip — keep prior count if any; don't stamp 0 on transient 429s.
      }
      // Keep spacing high — each count hits live+BS; shared API cache helps but
      // Cloudflare still rate-limits aggressive fans-out.
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
  }

  @override
  void dispose() {
    _webFsUnsub?.call();
    _webFsUnsub = null;
    _detailRefreshGen++;
    _searchCtrl.dispose();
    super.dispose();
  }

  void _sortMatches(List<LiveMatch> list) {
    list.sort((a, b) {
      final aLive = a.isLive && !a.isFinished ? 1 : 0;
      final bLive = b.isLive && !b.isFinished ? 1 : 0;
      if (aLive != bLive) return bLive - aLive;
      return a.startDateMs.compareTo(b.startDateMs);
    });
  }

  Future<void> _load() async {
    final sport = _sportType;
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (sport == 0) {
        await _loadAllProgressive(gen);
        return;
      }
      var list = await _api.fetchLive(sportType: sport);
      if (!mounted || gen != _loadGen) return;
      // Quiet retry without artificial delay — UI already visible.
      if (list.isEmpty) {
        list = await _api.fetchLive(sportType: sport);
      }
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _matches = list;
        _setSportCount(sport, list.length);
        _loading = false;
        if (list.isEmpty) _error = 'No events loaded. Tap refresh.';
      });
      // Counts after the list is usable — never race the main fetch.
      unawaited(_refreshSportCounts());
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Paint matches as soon as the first primary sport returns, then merge the rest.
  Future<void> _loadAllProgressive(int gen) async {
    final byId = <int, LiveMatch>{
      for (final m in _matches) m.matchId: m,
    };

    Future<void> mergeSport(int st) async {
      try {
        final list = await _api.fetchLive(sportType: st);
        if (!mounted || gen != _loadGen || _sportType != 0) return;
        setState(() {
          _setSportCount(st, list.length);
          for (final m in list) {
            final prev = byId[m.matchId];
            if (prev == null || m.streams.length > prev.streams.length) {
              byId[m.matchId] = m;
            }
          }
          final next = byId.values.toList();
          _sortMatches(next);
          _matches = next;
          _loading = false;
          if (next.isEmpty) {
            _error = 'No events loaded. Tap refresh.';
          } else {
            _error = null;
          }
        });
      } catch (_) {
        // Keep going — other sports may still succeed.
      }
    }

    // Football first for a fast first paint, then the other primary tabs.
    await mergeSport(1);
    if (!mounted || gen != _loadGen || _sportType != 0) return;
    await Future.wait([2, 3, 90].map(mergeSport));
    if (!mounted || gen != _loadGen || _sportType != 0) return;
    // Background extras — UI already interactive.
    for (final st in _allExtraSports) {
      if (!mounted || gen != _loadGen || _sportType != 0) return;
      await mergeSport(st);
    }
    if (!mounted || gen != _loadGen) return;
    setState(() => _loading = false);
    unawaited(_refreshSportCounts());
  }

  List<LiveMatch> get _filtered {
    Iterable<LiveMatch> list = _matches;
    if (_filter == HomeFilter.live) {
      list = list.where((m) => m.isCurrentlyLive);
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
    // Invalidate any in-flight resolve / detail polls from the previous match.
    _playGen++;
    final refreshGen = ++_detailRefreshGen;
    setState(() {
      _selected = match;
      _mini = false;
      _playableUrl = null;
      _activeServerId = null;
      _tab = 0;
      _resolving = false;
      _detailLoading = true;
      _error = null;
      // Seed like iOS until `/api/match/event` returns the full timeline.
      _events = _seedHighlights(match);
      _homeLineup = [];
      _awayLineup = [];
      _stats = [];
      _h2h = const H2HSummary();
      // Live list already carries channels (iOS field-2) — show them before detail returns.
      _servers = match.streams;
    });

    // Historical timeline must not wait on stream resolve (iOS loads it on appear).
    unawaited(_loadHistoricalHighlights(match, refreshGen));
    unawaited(_loadSecondaryTabs(match, refreshGen));

    try {
      var detail = await _api.fetchMatchDetail(
        matchId: match.matchId,
        sportType: match.sportType,
      );
      // List said streams exist but detail came back empty — one client-side retry
      // (API also clears rb-session / signatures on empty Success).
      if (detail.streams.isEmpty && match.hasStreams) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!mounted || _selected?.matchId != match.matchId || refreshGen != _detailRefreshGen) {
          return;
        }
        detail = await _api.fetchMatchDetail(
          matchId: match.matchId,
          sportType: match.sportType,
        );
      }
      if (!mounted || _selected?.matchId != match.matchId || refreshGen != _detailRefreshGen) {
        return;
      }
      final merged = (detail.match ?? match).copyWith(
        streams: detail.streams.isNotEmpty ? detail.streams : match.streams,
        hasStreams: detail.streams.isNotEmpty || match.hasStreams,
      );
      final list = _preferServers(merged.streams);
      setState(() {
        _selected = merged;
        _servers = list;
        _detailLoading = false;
      });
      // Re-fetch H2H once home name is known from detail (perspective may improve).
      if (_h2h.isEmpty || _homeNameFor(merged).isNotEmpty) {
        unawaited(_loadH2H(merged, refreshGen));
      }
      if (_stats.isEmpty) unawaited(_loadStats(merged, refreshGen));
      // Don't await playback — keep Overview events / polls responsive.
      if (list.isNotEmpty) {
        unawaited(_playServer(merged, list.first));
      } else if (match.hasStreams || merged.hasStreams) {
        unawaited(_recoverServersLater(match, refreshGen));
      }
      _startDetailAutoRefresh(match, refreshGen);
    } catch (e) {
      if (!mounted || _selected?.matchId != match.matchId || refreshGen != _detailRefreshGen) {
        return;
      }
      setState(() {
        _error = e.toString();
        _servers = match.streams;
        _detailLoading = false;
      });
      if (match.hasStreams) unawaited(_recoverServersLater(match, refreshGen));
      _startDetailAutoRefresh(match, refreshGen);
    } finally {
      if (mounted &&
          _selected?.matchId == match.matchId &&
          refreshGen == _detailRefreshGen &&
          _detailLoading) {
        setState(() => _detailLoading = false);
      }
    }
  }

  List<StreamServer> _preferServers(List<StreamServer> streams) {
    final named = streams.where((s) => s.hasReliableName).toList();
    if (named.isNotEmpty) return named;
    return streams.where((s) => s.isPlayable).toList();
  }

  /// iOS `seedHighlights` — placeholder until `/api/match/event` hydrates.
  List<MatchEvent> _seedHighlights(LiveMatch match) {
    final clock = match.liveClock ?? '';
    final rows = <MatchEvent>[
      MatchEvent(
        id: 'seed-kick-${match.matchId}',
        minute: clock.isEmpty ? null : clock,
        text: '${match.name} · kick-off',
        kind: 'info',
      ),
    ];
    final h = match.homeScore;
    final a = match.awayScore;
    if (h != null && a != null && h + a > 0) {
      rows.insert(
        0,
        MatchEvent(
          id: 'seed-score-${match.matchId}',
          minute: clock.isEmpty ? null : clock,
          text: 'Score $h-$a',
          kind: 'status',
        ),
      );
    }
    return rows;
  }

  Future<void> _loadHistoricalHighlights(LiveMatch match, int refreshGen) async {
    try {
      final rows = await _api.fetchEvents(
        matchId: match.matchId,
        sportType: match.sportType,
      );
      if (!mounted ||
          refreshGen != _detailRefreshGen ||
          _selected?.matchId != match.matchId ||
          rows.isEmpty) {
        return;
      }
      setState(() => _events = rows.take(40).toList());
    } catch (_) {
      // Keep seed rows until the next poll succeeds.
    }
  }

  Future<void> _loadSecondaryTabs(LiveMatch match, int refreshGen) async {
    // Independent loads — do NOT Future.wait heterogeneous records (dynamic cast
    // can throw and wipe stats/H2H even when those requests succeeded).
    unawaited(_loadLineup(match, refreshGen));
    unawaited(_loadStats(match, refreshGen));
    unawaited(_loadH2H(match, refreshGen));
  }

  String _homeNameFor(LiveMatch match) {
    final sides = (_selected ?? match).meaningfulContenders;
    if (sides.isNotEmpty) return sides.first.name;
    return '';
  }

  Future<void> _loadLineup(LiveMatch match, int refreshGen) async {
    try {
      final lineup = await _api.fetchLineup(
        matchId: match.matchId,
        sportType: match.sportType,
      );
      if (!_stillSelected(match, refreshGen)) return;
      setState(() {
        _homeLineup = lineup.home.where((p) => p.isStarter).toList()
          ..sort((a, b) => a.positionOrder.compareTo(b.positionOrder));
        _awayLineup = lineup.away.where((p) => p.isStarter).toList()
          ..sort((a, b) => a.positionOrder.compareTo(b.positionOrder));
      });
    } catch (_) {}
  }

  Future<void> _loadStats(LiveMatch match, int refreshGen) async {
    try {
      var stats = await _api.fetchStats(
        matchId: match.matchId,
        sportType: match.sportType,
      );
      if (stats.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!_stillSelected(match, refreshGen)) return;
        stats = await _api.fetchStats(
          matchId: match.matchId,
          sportType: match.sportType,
        );
      }
      if (!_stillSelected(match, refreshGen) || stats.isEmpty) return;
      setState(() => _stats = stats);
    } catch (_) {}
  }

  Future<void> _loadH2H(LiveMatch match, int refreshGen) async {
    try {
      var h2h = await _api.fetchH2H(
        matchId: match.matchId,
        sportType: match.sportType,
        homeName: _homeNameFor(match),
      );
      if (h2h.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!_stillSelected(match, refreshGen)) return;
        h2h = await _api.fetchH2H(
          matchId: match.matchId,
          sportType: match.sportType,
          homeName: _homeNameFor(match),
        );
      }
      if (!_stillSelected(match, refreshGen) || h2h.isEmpty) return;
      setState(() => _h2h = h2h);
    } catch (_) {}
  }

  bool _stillSelected(LiveMatch match, int refreshGen) =>
      mounted &&
      refreshGen == _detailRefreshGen &&
      _selected?.matchId == match.matchId;

  void _onDetailTab(int tab) {
    setState(() => _tab = tab);
    final match = _selected;
    if (match == null) return;
    final gen = _detailRefreshGen;
    // Lazy retry when user opens an empty tab (rate-limit / first-load miss).
    if (tab == 1 && _homeLineup.isEmpty && _awayLineup.isEmpty) {
      unawaited(_loadLineup(match, gen));
    } else if (tab == 2 && _stats.isEmpty) {
      unawaited(_loadStats(match, gen));
    } else if (tab == 3 && _h2h.isEmpty) {
      unawaited(_loadH2H(match, gen));
    }
  }

  /// iOS `startDetailAutoRefresh` — score/clock + full event timeline every ~20s.
  void _startDetailAutoRefresh(LiveMatch match, int refreshGen) {
    unawaited(() async {
      await Future<void>.delayed(const Duration(seconds: 3));
      while (mounted &&
          refreshGen == _detailRefreshGen &&
          _selected?.matchId == match.matchId) {
        await _refreshDisplayedMatch(match, refreshGen);
        await Future<void>.delayed(const Duration(seconds: 20));
      }
    }());
  }

  Future<void> _refreshDisplayedMatch(LiveMatch seed, int refreshGen) async {
    if (!_stillSelected(seed, refreshGen)) return;
    final previous = _selected ?? seed;
    try {
      // Independent awaits — avoid Future.wait + record cast wipe on type erase.
      final detailFut = _api.fetchMatchDetail(
        matchId: seed.matchId,
        sportType: seed.sportType,
      );
      final eventsFut = _api.fetchEvents(
        matchId: seed.matchId,
        sportType: seed.sportType,
      );
      final detail = await detailFut;
      final events = await eventsFut;
      if (!_stillSelected(seed, refreshGen)) return;
      final fresh = detail.match;
      var merged = previous;
      if (fresh != null) {
        merged = previous.copyWith(
          homeScore: fresh.homeScore ?? previous.homeScore,
          awayScore: fresh.awayScore ?? previous.awayScore,
          liveClock: fresh.liveClock ?? previous.liveClock,
          statusCode: fresh.statusCode,
          streams: detail.streams.isNotEmpty ? detail.streams : previous.streams,
          hasStreams: detail.streams.isNotEmpty || previous.hasStreams || fresh.hasStreams,
        );
      } else if (detail.streams.isNotEmpty) {
        merged = previous.copyWith(
          streams: detail.streams,
          hasStreams: true,
        );
      }

      List<MatchEvent> nextEvents;
      if (events.isNotEmpty) {
        nextEvents = events.take(40).toList();
      } else {
        final diff = _highlightsDiff(previous, merged);
        if (diff.isNotEmpty) {
          nextEvents = [...diff, ..._events].take(40).toList();
        } else {
          nextEvents = _events;
        }
      }

      final list = _preferServers(merged.streams);
      setState(() {
        _selected = merged;
        if (list.isNotEmpty) _servers = list;
        _events = nextEvents;
      });
      if (_playableUrl == null && list.isNotEmpty && _activeServerId == null) {
        unawaited(_playServer(merged, list.first));
      } else if (list.isEmpty && merged.hasStreams && _servers.isEmpty) {
        unawaited(_recoverServersLater(seed, refreshGen));
      }
    } catch (_) {
      // Soft-fail — next tick retries.
    }
  }

  /// iOS `highlightsDiff` fallback when `/api/match/event` is empty.
  List<MatchEvent> _highlightsDiff(LiveMatch previous, LiveMatch next) {
    final rows = <MatchEvent>[];
    final minute = next.liveClock ?? '';
    final ph = previous.homeScore ?? 0;
    final pa = previous.awayScore ?? 0;
    final nh = next.homeScore ?? 0;
    final na = next.awayScore ?? 0;
    if (nh != ph || na != pa) {
      final sides = next.meaningfulContenders;
      final home = sides.isNotEmpty ? sides[0].name : 'Home';
      final away = sides.length > 1 ? sides[1].name : 'Away';
      final scorer = nh > ph ? home : (na > pa ? away : next.name);
      rows.add(
        MatchEvent(
          id: 'diff-goal-$nh-$na-${next.matchId}',
          minute: minute.isEmpty ? null : minute,
          text: 'Goal — $scorer · $nh-$na',
          kind: 'goal',
        ),
      );
    }
    if (previous.statusCode != next.statusCode) {
      final label = next.isFinished ? 'Full time · $nh-$na' : 'Status update';
      rows.add(
        MatchEvent(
          id: 'diff-status-${next.statusCode}-${next.matchId}',
          minute: minute.isEmpty ? (next.isFinished ? 'FT' : null) : minute,
          text: label,
          kind: 'status',
        ),
      );
    }
    return rows;
  }

  /// Retry detail until channels appear (list often only has hasStreams, like Bo Rangers → DZ ES).
  Future<void> _recoverServersLater(LiveMatch match, int refreshGen) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      await Future<void>.delayed(Duration(milliseconds: 800 + attempt * 700));
      if (!_stillSelected(match, refreshGen)) return;
      if (_servers.isNotEmpty) return;
      try {
        final detail = await _api.fetchMatchDetail(
          matchId: match.matchId,
          sportType: match.sportType,
        );
        if (!_stillSelected(match, refreshGen)) return;
        final list = _preferServers(detail.streams);
        if (list.isEmpty) continue;
        final merged = (_selected ?? match).copyWith(
          streams: list,
          hasStreams: true,
        );
        setState(() {
          _selected = merged;
          _servers = list;
          _error = null;
        });
        if (_playableUrl == null) {
          unawaited(_playServer(merged, list.first));
        }
        return;
      } catch (_) {
        // Keep trying — upstream BS / detail flaps under load.
      }
    }
  }

  Future<void> _playServer(LiveMatch match, StreamServer server) async {
    final gen = ++_playGen;
    final streamId = (server.streamId?.isNotEmpty == true) ? server.streamId : server.id;
    final previousUrl = _playableUrl;
    final previousToken = _loadToken;
    // Drop the current URL immediately so the player tears down the old HLS session
    // before the new resolve lands (stop+open alone is unreliable on web).
    setState(() {
      _activeServerId = server.id;
      _resolving = true;
      _playableUrl = null;
      _error = null;
    });
    try {
      final url = await _api.resolvePlayback(
        matchId: match.matchId,
        sportType: match.sportType,
        streamId: streamId,
      );
      if (!mounted || gen != _playGen) return;
      setState(() {
        _playableUrl = url;
        _loadToken++;
        _resolving = false;
      });
    } catch (e) {
      if (!mounted || gen != _playGen) return;
      setState(() {
        _error = e.toString();
        _playableUrl = previousUrl;
        _loadToken = previousUrl != null ? previousToken + 1 : previousToken;
        _resolving = false;
      });
    }
  }

  VoidCallback? _webFsUnsub;

  Future<void> _enterFullscreen() async {
    if (_playableUrl == null) return;

    // Web: real browser / video Fullscreen API (not a Flutter route).
    if (kIsWeb) {
      if (webIsFullscreen()) {
        await webExitFullscreen();
        if (mounted) setState(() => _fullscreen = false);
        return;
      }
      final ok = await webEnterFullscreen();
      if (!mounted) return;
      setState(() {
        _fullscreen = ok;
        if (ok) _mini = false;
      });
      _webFsUnsub ??= webListenFullscreen((fs) {
        if (!mounted) return;
        setState(() => _fullscreen = fs);
      });
      return;
    }

    setState(() {
      _fullscreen = true;
      _mini = false;
    });
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    if (!mounted) return;
    final enterMini = await Navigator.of(context).push<bool>(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => _FullscreenRoute(
          playerKey: _playerKey,
          title: _selected?.name ?? '',
          url: _playableUrl,
          loadToken: _loadToken,
          resolving: _resolving,
        ),
      ),
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    if (mounted) {
      setState(() {
        _fullscreen = false;
        if (supportsMiniPlayer && enterMini == true) _mini = true;
      });
    }
  }

  Future<void> _showMoreSports() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: FctvColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _MoreSportsSheet(
        selectedType: _sportType,
        sportCounts: Map<int, int>.from(_sportCounts),
      ),
    );
    if (selected == null || !mounted) return;
    _selectSport(selected);
  }

  void _selectSport(int type) {
    if (type == _sportType && !_loading) {
      _load();
      return;
    }
    setState(() {
      _sportType = type;
      _matches = [];
      _selected = null;
      _error = null;
    });
    _load();
  }

  void _closeDetail() {
    _detailRefreshGen++;
    setState(() {
      _selected = null;
      _mini = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final layout = _shellLayoutFor(width);
    final phone = layout == _ShellLayout.phone;
    final list = _filtered;
    final liveCount = _matches.where((m) => m.isCurrentlyLive).length;
    final listPaneWidth = width >= 1200 ? 420.0 : 380.0;

    final left = _LeftPane(
      compact: phone,
      sportType: _sportType,
      filter: _filter,
      liveCount: liveCount,
      loading: _loading,
      error: _error,
      searchCtrl: _searchCtrl,
      matches: list,
      selectedId: phone ? null : _selected?.matchId,
      badgeForSport: _badgeForSport,
      moreBadge: _moreSportsCount > 0 ? '$_moreSportsCount' : null,
      onRefresh: _load,
      onSport: _selectSport,
      onShowMoreSports: _showMoreSports,
      onFilter: (f) => setState(() => _filter = f),
      onOpen: _openMatch,
    );

    final detail = _selected == null
        ? null
        : _DetailPane(
            match: _selected!,
            servers: _servers,
            activeServerId: _activeServerId,
            playableUrl: _playableUrl,
            loadToken: _loadToken,
            resolving: _resolving,
            detailLoading: _detailLoading,
            mini: _mini,
            fullscreen: _fullscreen,
            compact: phone,
            tab: _tab,
            events: _events,
            homeLineup: _homeLineup,
            awayLineup: _awayLineup,
            stats: _stats,
            h2h: _h2h,
            playerKey: _playerKey,
            onServer: (s) => _playServer(_selected!, s),
            onTab: _onDetailTab,
            onToggleMini: supportsMiniPlayer ? () => setState(() => _mini = !_mini) : null,
            onFullscreen: _enterFullscreen,
            onClose: phone ? _closeDetail : null,
          );

    final shell = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [FctvColors.headerStart, FctvColors.background, FctvColors.backgroundDeep],
        ),
      ),
      child: switch (layout) {
        _ShellLayout.split => Row(
            children: [
              SizedBox(width: listPaneWidth, child: left),
              const VerticalDivider(width: 1, color: Colors.white10),
              Expanded(child: detail ?? const _EmptyDetail()),
            ],
          ),
        _ShellLayout.phone => detail ?? left,
      },
    );

    return PopScope(
      canPop: !phone || _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && phone && _selected != null) _closeDetail();
      },
      child: Scaffold(
        body: shell,
        bottomNavigationBar: supportsMiniPlayer &&
                _mini &&
                !_fullscreen &&
                _playableUrl != null &&
                _selected != null
            ? Material(
                color: FctvColors.surfaceElevated,
                child: SafeArea(
                  child: ListTile(
                    leading: SizedBox(
                      width: 96,
                      child: StreamPlayer(
                        key: _playerKey,
                        url: _playableUrl,
                        loadToken: _loadToken,
                        title: _selected!.name,
                        expanded: false,
                        resolving: _resolving,
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
      ),
    );
  }
}

class _MatchListSkeleton extends StatelessWidget {
  const _MatchListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
      itemCount: 8,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, __) => const _SkeletonMatchRow(),
    );
  }
}

class _SkeletonMatchRow extends StatelessWidget {
  const _SkeletonMatchRow();

  Widget _bone({double? width, double height = 10, double radius = 6}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: FctvColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _bone(width: 18, height: 18, radius: 4),
              const SizedBox(width: 8),
              Expanded(child: _bone(height: 10)),
              const SizedBox(width: 24),
              _bone(width: 36, height: 10),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _bone(width: 36, height: 28, radius: 8),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    _bone(width: 22, height: 22, radius: 11),
                    const SizedBox(width: 8),
                    Expanded(child: _bone(height: 12)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _bone(width: 28, height: 14),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: _bone(height: 12)),
                    const SizedBox(width: 8),
                    _bone(width: 22, height: 22, radius: 11),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LeftPane extends StatelessWidget {
  const _LeftPane({
    this.compact = false,
    required this.sportType,
    required this.filter,
    required this.liveCount,
    required this.loading,
    required this.error,
    required this.searchCtrl,
    required this.matches,
    required this.selectedId,
    required this.badgeForSport,
    this.moreBadge,
    required this.onRefresh,
    required this.onSport,
    required this.onShowMoreSports,
    required this.onFilter,
    required this.onOpen,
  });

  final bool compact;
  final int sportType;
  final HomeFilter filter;
  final int liveCount;
  final bool loading;
  final String? error;
  final TextEditingController searchCtrl;
  final List<LiveMatch> matches;
  final int? selectedId;
  final String? Function(int type) badgeForSport;
  final String? moreBadge;
  final VoidCallback onRefresh;
  final ValueChanged<int> onSport;
  final VoidCallback onShowMoreSports;
  final ValueChanged<HomeFilter> onFilter;
  final ValueChanged<LiveMatch> onOpen;

  @override
  Widget build(BuildContext context) {
    final ancillarySelected = !isPrimarySportType(sportType);

    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(compact ? 14 : 16, 10, 8, 4),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    gradient: const LinearGradient(colors: [FctvColors.accent, Color(0xFFFF6B01)]),
                  ),
                  child: const Text('F', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 19)),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('FCTV33', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, letterSpacing: 1.2)),
                      Text('Live Sports · BY ANIS', style: TextStyle(color: FctvColors.textSecondary, fontSize: 12)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: loading ? null : onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 14),
          child: Row(
            children: [
              for (final s in primarySports)
                Expanded(
                  child: _SportTabButton(
                    icon: s.icon,
                    label: s.label,
                    active: sportType == s.type,
                    badge: badgeForSport(s.type),
                    onTap: () => onSport(s.type),
                  ),
                ),
              Expanded(
                child: _SportTabButton(
                  icon: Icons.more_horiz_rounded,
                  label: 'More',
                  active: ancillarySelected,
                  badge: moreBadge,
                  onTap: onShowMoreSports,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: TextField(
            controller: searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search teams, leagues…',
              prefixIcon: const Icon(Icons.search_rounded, size: 20, color: FctvColors.textMuted),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
              const Spacer(),
              Text(
                '${matches.length}',
                style: const TextStyle(color: FctvColors.textMuted, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 12)),
          ),
        Expanded(
          child: Stack(
            children: [
              if (loading && matches.isEmpty)
                const _MatchListSkeleton()
              else if (matches.isEmpty)
                const Center(
                  child: Text('No matches', style: TextStyle(color: FctvColors.textTertiary)),
                )
              else
                ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
                  itemCount: matches.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final m = matches[i];
                    return MatchRowCard(
                      match: m,
                      selected: selectedId == m.matchId,
                      onTap: () => onOpen(m),
                    );
                  },
                ),
              if (loading)
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: FctvColors.accent,
                    backgroundColor: Colors.transparent,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SportTabButton extends StatelessWidget {
  const _SportTabButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active ? FctvColors.accent : Colors.white.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 20, color: active ? Colors.black : Colors.white),
                ),
                if (badge != null)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: FctvColors.live,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badge!,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : FctvColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreSportsSheet extends StatelessWidget {
  const _MoreSportsSheet({required this.selectedType, required this.sportCounts});
  final int selectedType;
  final Map<int, int> sportCounts;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Text('Sports', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                controller: scrollController,
                padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + bottom),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.92,
                ),
                itemCount: allSports.length,
                itemBuilder: (_, i) {
                  final s = allSports[i];
                  final selected = s.type == selectedType;
                  final count = sportCounts[s.type];
                  final badge = (count != null && count > 0) ? '$count' : null;
                  return InkWell(
                    onTap: () => Navigator.pop(context, s.type),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected ? FctvColors.accent : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: selected ? FctvColors.accent : Colors.white.withValues(alpha: 0.08),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(s.icon, size: 26, color: selected ? Colors.black : Colors.white),
                              ),
                              if (badge != null)
                                Positioned(
                                  right: -4,
                                  top: -4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: FctvColors.live,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      badge,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            s.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
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
          color: active ? const Color(0x33FFAE01) : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            if (live) ...[const LiveDot(size: 6), const SizedBox(width: 6)],
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sports_soccer, size: 48, color: Colors.white.withValues(alpha: 0.2)),
          const SizedBox(height: 16),
          const Text('Select a Match', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
            'Pick an event to open streams, timeline, and lineups.',
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
    required this.loadToken,
    required this.resolving,
    required this.detailLoading,
    required this.mini,
    required this.fullscreen,
    this.compact = false,
    required this.tab,
    required this.events,
    required this.homeLineup,
    required this.awayLineup,
    required this.stats,
    required this.h2h,
    required this.playerKey,
    required this.onServer,
    required this.onTab,
    this.onToggleMini,
    required this.onFullscreen,
    this.onClose,
  });

  final LiveMatch match;
  final List<StreamServer> servers;
  final String? activeServerId;
  final String? playableUrl;
  final int loadToken;
  final bool resolving;
  final bool detailLoading;
  final bool mini;
  final bool fullscreen;
  final bool compact;
  final int tab;
  final List<MatchEvent> events;
  final List<LineupPlayer> homeLineup;
  final List<LineupPlayer> awayLineup;
  final List<MatchStatRow> stats;
  final H2HSummary h2h;
  final GlobalKey<StreamPlayerState> playerKey;
  final ValueChanged<StreamServer> onServer;
  final ValueChanged<int> onTab;
  final VoidCallback? onToggleMini;
  final VoidCallback onFullscreen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final sides = match.meaningfulContenders;
    final home = sides.isNotEmpty ? sides[0] : null;
    final away = sides.length > 1 ? sides[1] : null;
    final start = DateTime.fromMillisecondsSinceEpoch(match.startDateMs);
    final weekdays = const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final months = const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final dateLabel =
        '${weekdays[start.weekday - 1]}, ${start.day.toString().padLeft(2, '0')} ${months[start.month - 1]} · '
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    final hPad = compact ? 16.0 : 20.0;
    final playerTitle =
        servers.where((s) => s.id == activeServerId).map((s) => s.name).firstOrNull ?? match.name;

    final header = Column(
      children: [
        Row(
          children: [
            RemoteLogo(
              url: match.leagueLogoUrl,
              name: match.leagueName.isEmpty ? match.region : match.leagueName,
              size: 22,
              cornerRadius: 5,
              lightBadge: true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.leagueName.isEmpty ? 'Competition' : match.leagueName,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(dateLabel, style: const TextStyle(color: FctvColors.textMuted, fontSize: 12)),
                ],
              ),
            ),
            if (match.region.isNotEmpty)
              Text(match.region, style: const TextStyle(color: FctvColors.textMuted, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 16),
        if (match.isVersus)
          Row(
            children: [
              Expanded(
                child: _Side(
                  name: sides.isNotEmpty ? sides[0].name : '',
                  logo: sides.isNotEmpty ? sides[0].logoUrl : null,
                ),
              ),
              Column(
                children: [
                  Text(
                    // iOS MatchDetailHeader: liveClock → FT → kickoff timeLabel (never invent "LIVE").
                    match.isFinished
                        ? 'FT'
                        : (match.liveClock?.isNotEmpty == true
                            ? match.liveClock!
                            : match.timeLabel),
                    style: TextStyle(
                      fontSize: compact ? 18 : 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                      color: match.isCurrentlyLive && match.liveClock != null
                          ? FctvColors.clock
                          : FctvColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    match.scoreTextSpaced,
                    style: TextStyle(
                      fontSize: compact ? 26 : 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: _Side(
                  name: sides.length > 1 ? sides[1].name : '',
                  logo: sides.length > 1 ? sides[1].logoUrl : null,
                ),
              ),
            ],
          )
        else
          _SoloEventHeader(match: match),
      ],
    );

    // Never ClipRRect the player on web — HtmlElementView (<video>) goes black
    // while audio still plays (Flutter CanvasKit / Safari clip-path bug).
    final playerWidget = StreamPlayer(
      key: playerKey,
      url: playableUrl,
      loadToken: loadToken,
      title: playerTitle,
      resolving: resolving || detailLoading,
      isFullscreen: fullscreen,
      onTogglePiP: onToggleMini,
      onToggleFullscreen: onFullscreen,
    );
    // Web keeps the inline player mounted while browser fullscreen owns the <video>.
    final hideInline = mini || (fullscreen && !kIsWeb);
    final player = !hideInline
        ? (kIsWeb || compact
            ? playerWidget
            : ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: playerWidget,
              ))
        : const SizedBox.shrink();

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          resolving ? 'Servers · resolving…' : 'Servers',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 10),
        if (servers.isEmpty && (detailLoading || match.hasStreams))
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(minHeight: 2, color: FctvColors.accent),
                SizedBox(height: 8),
                Text(
                  'Loading servers…',
                  style: TextStyle(color: FctvColors.textTertiary, fontSize: 13),
                ),
              ],
            ),
          )
        else if (servers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No streams for this match', style: TextStyle(color: FctvColors.textTertiary)),
          )
        else
          StreamServerGrid(
            servers: servers,
            activeServerId: activeServerId,
            matchRegion: match.region,
            onServer: onServer,
          ),
        const SizedBox(height: 18),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final e in const [(0, 'Overview'), (1, 'Lineups'), (2, 'Stats'), (3, 'H2H')]) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(e.$2),
                    selected: tab == e.$1,
                    onSelected: (_) => onTab(e.$1),
                    selectedColor: FctvColors.accent,
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    side: BorderSide.none,
                    labelStyle: TextStyle(
                      color: tab == e.$1 ? Colors.black : Colors.white70,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        switch (tab) {
          1 => _DetailCard(
              child: _Lineups(home: homeLineup, away: awayLineup, homeName: home?.name, awayName: away?.name),
            ),
          2 => _StatsTab(stats: stats, homeName: home?.name ?? 'Home', awayName: away?.name ?? 'Away'),
          3 => _H2HTab(h2h: h2h, homeName: home?.name ?? 'Home'),
          _ => _Overview(match: match, events: events, serverCount: servers.length),
        },
      ],
    );

    // iOS-like phone: player chrome fixed on top, content scrolls under.
    if (compact) {
      return Column(
        children: [
          SafeArea(
            bottom: false,
            child: Stack(
              children: [
                Column(
                  children: [
                    if (!mini && !fullscreen) player,
                  ],
                ),
                if (onClose != null)
                  Positioned(
                    top: 8,
                    left: 12,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Close',
                        onPressed: onClose,
                        icon: const Icon(Icons.chevron_left_rounded, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 40),
              children: [
                header,
                const SizedBox(height: 18),
                body,
              ],
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 40),
      children: [
        header,
        const SizedBox(height: 18),
        if (!mini && !fullscreen) player,
        const SizedBox(height: 16),
        body,
      ],
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: FctvColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: child,
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.name, this.logo});
  final String name;
  final String? logo;

  @override
  Widget build(BuildContext context) {
    if (name.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        RemoteLogo(url: logo, name: name, size: 52),
        const SizedBox(height: 8),
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
      ],
    );
  }
}

class _SoloEventHeader extends StatelessWidget {
  const _SoloEventHeader({required this.match});
  final LiveMatch match;

  @override
  Widget build(BuildContext context) {
    final side = match.meaningfulContenders.isNotEmpty ? match.meaningfulContenders.first : null;
    final Widget logo;
    if (side?.logoUrl != null && side!.logoUrl!.isNotEmpty) {
      logo = RemoteLogo(url: side.logoUrl, name: side.name, size: 64);
    } else if (match.leagueLogoUrl != null && match.leagueLogoUrl!.isNotEmpty) {
      logo = RemoteLogo(
        url: match.leagueLogoUrl,
        name: match.leagueName.isEmpty ? match.displayName : match.leagueName,
        size: 64,
        cornerRadius: 16,
        lightBadge: true,
      );
    } else {
      logo = Container(
        width: 64,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.sports, size: 28, color: Colors.white70),
      );
    }

    return Column(
      children: [
        logo,
        const SizedBox(height: 12),
        Text(
          match.displayName,
          textAlign: TextAlign.center,
          maxLines: 3,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
        ),
        const SizedBox(height: 8),
        StatusBadge(match: match),
      ],
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.match, required this.events, required this.serverCount});
  final LiveMatch match;
  final List<MatchEvent> events;
  final int serverCount;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final start = DateTime.fromMillisecondsSinceEpoch(match.startDateMs);
    final time =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    final dateString =
        '${_weekdays[start.weekday - 1]}, ${start.day} ${_months[start.month - 1]} $time';
    final sides = match.meaningfulContenders;
    final home = sides.isNotEmpty ? sides[0] : null;
    final away = sides.length > 1 ? sides[1] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Match info'),
        _DetailCard(
          child: Column(
            children: [
              _InfoRow(Icons.emoji_events_rounded, 'Competition', _dash(match.leagueName)),
              _InfoRow(Icons.calendar_month_rounded, 'Date', dateString),
              _InfoRow(Icons.place_outlined, 'Region', _dash(match.region)),
              _InfoRow(
                Icons.tv_rounded,
                'Streams',
                serverCount > 0
                    ? '$serverCount server${serverCount == 1 ? '' : 's'}'
                    : (match.hasStreams ? 'Loading…' : 'None'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('Score'),
        _DetailCard(
          child: match.isVersus
              ? Row(
                  children: [
                    Expanded(child: _Side(name: home?.name ?? '', logo: home?.logoUrl)),
                    Text(
                      match.scoreTextSpaced,
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
                    ),
                    Expanded(child: _Side(name: away?.name ?? '', logo: away?.logoUrl)),
                  ],
                )
              : _SoloEventHeader(match: match),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('Highlights'),
        _DetailCard(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: EventTimeline(events: events),
          ),
        ),
      ],
    );
  }

  static String _dash(String value) {
    final t = value.trim();
    return t.isEmpty ? '—' : t;
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          letterSpacing: 0.5,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: FctvColors.textSecondary,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.icon, this.title, this.value);
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: SizedBox(
              width: 18,
              child: Icon(icon, size: 16, color: FctvColors.accent),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(
              color: FctvColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                height: 1.25,
              ),
            ),
          ),
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
        Text(
          title.toUpperCase(),
          style: const TextStyle(letterSpacing: 1, fontSize: 11, fontWeight: FontWeight.w800, color: FctvColors.textMuted),
        ),
        const SizedBox(height: 10),
        if (rows.isEmpty)
          const Text('Lineup unavailable', style: TextStyle(color: FctvColors.textTertiary))
        else
          ...rows.map(
            (p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      p.number ?? p.positionLabel,
                      style: const TextStyle(color: FctvColors.textTertiary, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Expanded(child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                  if (p.positionLabel.isNotEmpty && p.number != null)
                    Text(p.positionLabel, style: const TextStyle(color: FctvColors.textTertiary, fontSize: 11)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _StatsTab extends StatelessWidget {
  const _StatsTab({required this.stats, required this.homeName, required this.awayName});
  final List<MatchStatRow> stats;
  final String homeName;
  final String awayName;

  static const _awayColor = Color(0xFF81C784);

  MatchStatRow? get _possession {
    for (final s in stats) {
      final label = s.label.toLowerCase();
      if (s.isPercent || label.contains('possession') || label.contains('poss')) {
        return s;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) {
      return const _DetailCard(
        child: Text('Match stats unavailable for this event.', style: TextStyle(color: FctvColors.textTertiary)),
      );
    }
    final possession = _possession;
    final barStats = possession == null
        ? stats
        : stats.where((s) => s != possession).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Match stats'),
        _DetailCard(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        homeName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, height: 1.2, color: FctvColors.accent),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        awayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, height: 1.2, color: _awayColor),
                      ),
                    ),
                  ],
                ),
              ),
              if (possession != null) ...[
                _PossessionDonut(stat: possession, awayColor: _awayColor),
                const SizedBox(height: 18),
              ],
              for (var i = 0; i < barStats.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                _StatRow(stat: barStats[i], awayColor: _awayColor),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Circular possession chart (home / away) — numbers + visual like iOS detail.
class _PossessionDonut extends StatelessWidget {
  const _PossessionDonut({required this.stat, required this.awayColor});
  final MatchStatRow stat;
  final Color awayColor;

  @override
  Widget build(BuildContext context) {
    final home = stat.home.toDouble().clamp(0, 100);
    final away = stat.away.toDouble().clamp(0, 100);
    final total = (home + away).clamp(1, double.infinity);
    final homeSweep = (home / total) * 360;
    return Column(
      children: [
        Text(
          stat.label,
          style: const TextStyle(
            color: FctvColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 148,
          height: 148,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(148, 148),
                painter: _DonutPainter(
                  homeDegrees: homeSweep,
                  homeColor: FctvColors.accent,
                  awayColor: awayColor,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${home.round()}% — ${away.round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Possession',
                    style: TextStyle(color: FctvColors.textTertiary, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.homeDegrees,
    required this.homeColor,
    required this.awayColor,
  });

  final double homeDegrees;
  final Color homeColor;
  final Color awayColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final stroke = radius * 0.22;
    final rect = Rect.fromCircle(center: center, radius: radius - stroke / 2);
    final bg = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    canvas.drawArc(rect, 0, 2 * 3.141592653589793, false, bg);

    final homePaint = Paint()
      ..color = homeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    final awayPaint = Paint()
      ..color = awayColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Start at 12 o'clock.
    const start = -3.141592653589793 / 2;
    final homeRad = homeDegrees * 3.141592653589793 / 180;
    final awayRad = (360 - homeDegrees) * 3.141592653589793 / 180;
    canvas.drawArc(rect, start, homeRad, false, homePaint);
    canvas.drawArc(rect, start + homeRad, awayRad, false, awayPaint);
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.homeDegrees != homeDegrees ||
      oldDelegate.homeColor != homeColor ||
      oldDelegate.awayColor != awayColor;
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.stat, required this.awayColor});
  final MatchStatRow stat;
  final Color awayColor;

  @override
  Widget build(BuildContext context) {
    final home = stat.home.toDouble();
    final away = stat.away.toDouble();
    final total = (home + away).clamp(1, double.infinity);
    final homeRatio = home / total;
    final awayRatio = away / total;
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                stat.format(stat.home),
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
            Expanded(
              child: Text(
                stat.label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: FctvColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                stat.format(stat.away),
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        // Comparison chart bar (numbers above) — same layout as native iOS.
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0x1AFFFFFF)),
                Row(
                  children: [
                    Flexible(
                      flex: (homeRatio * 1000).round().clamp(1, 1000),
                      child: const ColoredBox(color: FctvColors.accent),
                    ),
                    Flexible(
                      flex: (awayRatio * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: awayColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _H2HTab extends StatelessWidget {
  const _H2HTab({required this.h2h, required this.homeName});
  final H2HSummary h2h;
  final String homeName;

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    if (h2h.isEmpty) {
      return const _DetailCard(
        child: Text('Head-to-head unavailable for this event.', style: TextStyle(color: FctvColors.textTertiary)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(homeName.isEmpty ? 'Head-to-head' : '$homeName record'),
        _DetailCard(
          child: Row(
            children: [
              _recordCol('${h2h.wins}', 'Wins'),
              _recordCol('${h2h.draws}', 'Draws'),
              _recordCol('${h2h.losses}', 'Losses'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionLabel('Last meetings'),
        _DetailCard(
          child: Column(
            children: [
              for (var i = 0; i < h2h.meetings.length; i++) ...[
                if (i > 0) const Divider(height: 18, color: Colors.white10),
                _meetingRow(h2h.meetings[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _recordCol(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: FctvColors.accent)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: FctvColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _meetingRow(H2HMeeting m) {
    final dt = DateTime.fromMillisecondsSinceEpoch(m.startDateMs);
    final date = '${_months[dt.month - 1]} ${dt.year}';
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(date, style: const TextStyle(color: FctvColors.textTertiary, fontSize: 11, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(
            m.homeName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              m.scoreText,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: FctvColors.accent),
            ),
          ),
        ),
        Expanded(
          child: Text(
            m.awayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _FullscreenRoute extends StatelessWidget {
  const _FullscreenRoute({
    required this.playerKey,
    required this.title,
    required this.url,
    required this.loadToken,
    required this.resolving,
  });
  final GlobalKey<StreamPlayerState> playerKey;
  final String title;
  final String? url;
  final int loadToken;
  final bool resolving;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: StreamPlayer(
          key: playerKey,
          url: url,
          loadToken: loadToken,
          title: title,
          resolving: resolving,
          isFullscreen: true,
          onToggleFullscreen: () => Navigator.of(context).pop(false),
          onTogglePiP: supportsMiniPlayer ? () => Navigator.of(context).pop(true) : null,
        ),
      ),
    );
  }
}
