import 'package:flutter/material.dart';

class Contender {
  const Contender({required this.id, required this.name, this.logoUrl});
  final String id;
  final String name;
  final String? logoUrl;

  factory Contender.fromJson(Map<String, dynamic> json) => Contender(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        logoUrl: json['logoURL'] as String?,
      );
}

class StreamServer {
  const StreamServer({
    required this.id,
    required this.name,
    this.fullName = '',
    this.streamId,
    this.siteType,
    this.country = '',
    this.countryCode,
    this.flagUrl,
  });

  final String id;
  final String name;
  final String fullName;
  final String? streamId;
  final int? siteType;
  final String country;
  final String? countryCode;
  final String? flagUrl;

  factory StreamServer.fromJson(Map<String, dynamic> json) => StreamServer(
        id: '${json['id'] ?? json['streamId'] ?? ''}',
        name: '${json['name'] ?? 'Stream'}',
        fullName: '${json['fullName'] ?? ''}',
        streamId: json['streamId']?.toString(),
        siteType: json['siteType'] is int ? json['siteType'] as int : int.tryParse('${json['siteType']}'),
        country: '${json['country'] ?? ''}',
        countryCode: json['countryCode'] as String?,
        flagUrl: json['flagURL'] as String?,
      );

  bool get hasReliableName {
    final n = name.trim();
    if (n.isEmpty) return false;
    if (RegExp(r'^stream\s*\d*$', caseSensitive: false).hasMatch(n)) return false;
    if (n.toLowerCase() == 'live stream') return false;
    return true;
  }

  /// Prefer named channels, but keep id-only rows so we never drop a real feed (e.g. DZ ES).
  bool get isPlayable =>
      hasReliableName || (streamId != null && streamId!.trim().isNotEmpty) || id.trim().isNotEmpty;
}

class LiveMatch {
  const LiveMatch({
    required this.matchId,
    required this.sportType,
    required this.name,
    this.leagueName = '',
    this.leagueLogoUrl,
    this.region = '',
    this.contenders = const [],
    this.homeScore,
    this.awayScore,
    this.statusCode = 0,
    required this.startDateMs,
    this.liveClock,
    this.hot = false,
    this.hasStreams = false,
    this.streams = const [],
  });

  final int matchId;
  final int sportType;
  final String name;
  final String leagueName;
  final String? leagueLogoUrl;
  final String region;
  final List<Contender> contenders;
  final int? homeScore;
  final int? awayScore;
  final int statusCode;
  final int startDateMs;
  final String? liveClock;
  final bool hot;
  final bool hasStreams;
  final List<StreamServer> streams;

  /// In-play only (`statusCode` 1…9999). Scheduled = 0; finished ≥ 10000.
  bool get isLive => statusCode > 0 && statusCode < 10000;
  bool get isFinished => statusCode >= 10000 || statusCode == -1;
  bool get isCurrentlyLive => isLive && !isFinished;

  /// Display score — protobuf drops 0, so treat missing as 0 once the match has started.
  String get scoreText {
    if (!isVersus) return '';
    if (!isLive && !isFinished && homeScore == null && awayScore == null) return 'VS';
    final home = homeScore ?? ((isLive || isFinished) ? 0 : null);
    final away = awayScore ?? ((isLive || isFinished) ? 0 : null);
    if (home == null && away == null) return 'VS';
    return '${home ?? '–'}-${away ?? '–'}';
  }

  String get scoreTextSpaced {
    if (!isVersus) return '';
    if (!isLive && !isFinished && homeScore == null && awayScore == null) return '–';
    final home = homeScore ?? ((isLive || isFinished) ? 0 : null);
    final away = awayScore ?? ((isLive || isFinished) ? 0 : null);
    if (home == null && away == null) return '–';
    return '${home ?? '–'} - ${away ?? '–'}';
  }

  /// Kickoff clock (`18:30`) from protobuf `matchDate` — same role as iOS `timeLabel`.
  String get timeLabel {
    final start = DateTime.fromMillisecondsSinceEpoch(startDateMs);
    return '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
  }

  /// Calendar day when kickoff is not today (`10 Oct`) — iOS `dateLabel`.
  String get dateLabel {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final start = DateTime.fromMillisecondsSinceEpoch(startDateMs);
    return '${start.day.toString().padLeft(2, '0')} ${months[start.month - 1]}';
  }

  bool get isKickoffToday {
    final start = DateTime.fromMillisecondsSinceEpoch(startDateMs);
    final now = DateTime.now();
    return start.year == now.year && start.month == now.month && start.day == now.day;
  }

  /// Contenders with a real display name (empty / Home / Away placeholders ignored).
  List<Contender> get meaningfulContenders => contenders.where((c) {
        final n = c.name.trim();
        if (n.isEmpty) return false;
        final lower = n.toLowerCase();
        if (lower == 'home' || lower == 'away' || lower == 'tbd') return false;
        return true;
      }).toList();

  /// Classic A vs B layout — false for court feeds, races, solo titles (iOS `isVersusLayout`).
  bool get isVersus => meaningfulContenders.length >= 2;

  String get displayName {
    final sides = meaningfulContenders;
    if (sides.length >= 2) return '${sides[0].name} vs ${sides[1].name}';
    if (sides.isNotEmpty) return sides.first.name;
    final trimmed = name.trim();
    if (trimmed.isNotEmpty &&
        trimmed.toLowerCase() != leagueName.trim().toLowerCase()) {
      return trimmed;
    }
    final league = leagueName.trim();
    if (league.isNotEmpty) return league;
    return trimmed.isEmpty ? 'Live event' : trimmed;
  }

  factory LiveMatch.fromJson(Map<String, dynamic> json) {
    final contenders = (json['contenders'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Contender.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final streams = (json['streams'] as List? ?? [])
        .whereType<Map>()
        .map((e) => StreamServer.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return LiveMatch(
      matchId: (json['matchId'] as num).toInt(),
      sportType: (json['sportType'] as num).toInt(),
      name: '${json['name'] ?? ''}',
      leagueName: '${json['leagueName'] ?? ''}',
      leagueLogoUrl: json['leagueLogoURL'] as String?,
      region: '${json['region'] ?? ''}',
      contenders: contenders,
      homeScore: (json['homeScore'] as num?)?.toInt(),
      awayScore: (json['awayScore'] as num?)?.toInt(),
      statusCode: (json['statusCode'] as num?)?.toInt() ?? 0,
      startDateMs: (json['startDate'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      liveClock: json['liveClock'] as String?,
      hot: json['hot'] == true,
      hasStreams: json['hasStreams'] == true || streams.isNotEmpty,
      streams: streams,
    );
  }

  LiveMatch copyWith({
    List<StreamServer>? streams,
    String? liveClock,
    int? homeScore,
    int? awayScore,
    int? statusCode,
    bool? hasStreams,
  }) {
    return LiveMatch(
      matchId: matchId,
      sportType: sportType,
      name: name,
      leagueName: leagueName,
      leagueLogoUrl: leagueLogoUrl,
      region: region,
      contenders: contenders,
      homeScore: homeScore ?? this.homeScore,
      awayScore: awayScore ?? this.awayScore,
      statusCode: statusCode ?? this.statusCode,
      startDateMs: startDateMs,
      liveClock: liveClock ?? this.liveClock,
      hot: hot,
      hasStreams: hasStreams ?? this.hasStreams,
      streams: streams ?? this.streams,
    );
  }
}

class MatchEvent {
  const MatchEvent({required this.id, required this.text, this.minute, this.kind = 'info'});
  final String id;
  final String text;
  final String? minute;
  final String kind;

  factory MatchEvent.fromJson(Map<String, dynamic> json) => MatchEvent(
        id: '${json['id']}',
        text: '${json['text'] ?? ''}',
        minute: json['minute'] as String?,
        kind: '${json['kind'] ?? 'info'}',
      );

  IconData get icon {
    final t = text.toLowerCase();
    if (kind == 'goal' || t.contains('goal') || t.contains('penalty')) {
      return Icons.sports_soccer;
    }
    if (t.contains('yellow')) return Icons.style;
    if (t.contains('red') || t.contains('second yellow')) return Icons.square_rounded;
    if (t.contains('sub')) return Icons.swap_vert_rounded;
    if (kind == 'status') return Icons.flag_rounded;
    return Icons.circle;
  }

  Color get accent {
    final t = text.toLowerCase();
    if (kind == 'goal' || t.contains('goal') || t.contains('penalty')) {
      return const Color(0xFFFFAE01);
    }
    if (t.contains('yellow')) return const Color(0xFFFFEB3B);
    if (t.contains('red') || t.contains('second yellow')) return const Color(0xFFE53935);
    if (kind == 'status') return const Color(0xFF82B1FF);
    return const Color(0x99FFFFFF);
  }
}

class LineupPlayer {
  const LineupPlayer({
    required this.id,
    required this.name,
    this.number,
    this.positionLabel = '',
    this.positionOrder = 0,
    this.isStarter = true,
  });
  final String id;
  final String name;
  final String? number;
  final String positionLabel;
  final int positionOrder;
  final bool isStarter;

  factory LineupPlayer.fromJson(Map<String, dynamic> json) => LineupPlayer(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        number: json['number'] as String?,
        positionLabel: '${json['positionLabel'] ?? ''}',
        positionOrder: (json['positionOrder'] as num?)?.toInt() ?? 0,
        isStarter: json['isStarter'] != false,
      );
}

class MatchStatRow {
  const MatchStatRow({
    required this.type,
    required this.label,
    required this.home,
    required this.away,
    this.isPercent = false,
  });

  final int type;
  final String label;
  final num home;
  final num away;
  final bool isPercent;

  factory MatchStatRow.fromJson(Map<String, dynamic> json) => MatchStatRow(
        type: (json['type'] as num?)?.toInt() ?? 0,
        label: '${json['label'] ?? 'Stat'}',
        home: (json['home'] as num?) ?? 0,
        away: (json['away'] as num?) ?? 0,
        isPercent: json['isPercent'] == true,
      );

  String format(num value) {
    if (isPercent) return '${value.round()}%';
    if (value == value.roundToDouble()) return '${value.round()}';
    return value.toString();
  }
}

class H2HMeeting {
  const H2HMeeting({
    required this.matchId,
    required this.startDateMs,
    required this.homeName,
    required this.awayName,
    required this.homeScore,
    required this.awayScore,
    this.leagueName = '',
  });

  final int matchId;
  final int startDateMs;
  final String homeName;
  final String awayName;
  final int homeScore;
  final int awayScore;
  final String leagueName;

  factory H2HMeeting.fromJson(Map<String, dynamic> json) => H2HMeeting(
        matchId: (json['matchId'] as num?)?.toInt() ?? 0,
        startDateMs: (json['startDate'] as num?)?.toInt() ?? 0,
        homeName: '${json['homeName'] ?? ''}',
        awayName: '${json['awayName'] ?? ''}',
        homeScore: (json['homeScore'] as num?)?.toInt() ?? 0,
        awayScore: (json['awayScore'] as num?)?.toInt() ?? 0,
        leagueName: '${json['leagueName'] ?? ''}',
      );

  String get scoreText => '$homeScore-$awayScore';
}

class H2HSummary {
  const H2HSummary({
    this.wins = 0,
    this.draws = 0,
    this.losses = 0,
    this.meetings = const [],
  });

  final int wins;
  final int draws;
  final int losses;
  final List<H2HMeeting> meetings;

  factory H2HSummary.fromJson(Map<String, dynamic> json) => H2HSummary(
        wins: (json['wins'] as num?)?.toInt() ?? 0,
        draws: (json['draws'] as num?)?.toInt() ?? 0,
        losses: (json['losses'] as num?)?.toInt() ?? 0,
        meetings: (json['meetings'] as List? ?? [])
            .whereType<Map>()
            .map((e) => H2HMeeting.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  bool get isEmpty => meetings.isEmpty && wins == 0 && draws == 0 && losses == 0;
}

class SportTab {
  const SportTab(this.type, this.label, this.icon);
  final int type;
  final String label;
  final IconData icon;
}

/// Primary header tabs — same order as iOS `Sport.primaryTabs`.
const primarySports = <SportTab>[
  SportTab(0, 'All', Icons.grid_view_rounded),
  SportTab(1, 'Football', Icons.sports_soccer),
  SportTab(2, 'Basketball', Icons.sports_basketball),
  SportTab(3, 'Tennis', Icons.sports_tennis),
  SportTab(90, 'Others', Icons.more_horiz),
];

/// Full list for the More sheet — same as iOS `Sport.allSports` (+ types).
const allSports = <SportTab>[
  SportTab(1, 'Football', Icons.sports_soccer),
  SportTab(2, 'Basketball', Icons.sports_basketball),
  SportTab(3, 'Tennis', Icons.sports_tennis),
  SportTab(17, 'Golf', Icons.sports_golf),
  SportTab(9, 'AM. Football', Icons.sports_football),
  SportTab(8, 'Rugby', Icons.sports_rugby),
  SportTab(10, 'Aussie rules', Icons.sports),
  SportTab(6, 'Cricket', Icons.sports_cricket),
  SportTab(11, 'Hockey', Icons.sports_hockey),
  SportTab(12, 'Badminton', Icons.sports_tennis),
  SportTab(4, 'Baseball', Icons.sports_baseball),
  SportTab(13, 'Volleyball', Icons.sports_volleyball),
  SportTab(14, 'Fighting', Icons.sports_mma),
  SportTab(15, 'Cycling', Icons.directions_bike),
  SportTab(16, 'Handball', Icons.sports_handball),
  SportTab(7, 'Motorsport', Icons.sports_motorsports),
  SportTab(90, 'Others', Icons.more_horiz),
];

SportTab? sportByType(int type) {
  for (final s in allSports) {
    if (s.type == type) return s;
  }
  for (final s in primarySports) {
    if (s.type == type) return s;
  }
  return null;
}

bool isPrimarySportType(int type) => primarySports.any((s) => s.type == type);
