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
  });

  final String id;
  final String name;
  final String fullName;
  final String? streamId;
  final int? siteType;
  final String country;

  factory StreamServer.fromJson(Map<String, dynamic> json) => StreamServer(
        id: '${json['id'] ?? json['streamId'] ?? ''}',
        name: '${json['name'] ?? 'Stream'}',
        fullName: '${json['fullName'] ?? ''}',
        streamId: json['streamId']?.toString(),
        siteType: json['siteType'] is int ? json['siteType'] as int : int.tryParse('${json['siteType']}'),
        country: '${json['country'] ?? ''}',
      );

  bool get hasReliableName {
    final n = name.trim();
    if (n.isEmpty) return false;
    if (RegExp(r'^stream\s*\d*$', caseSensitive: false).hasMatch(n)) return false;
    if (n.toLowerCase() == 'live stream') return false;
    return true;
  }
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
  final List<StreamServer> streams;

  bool get isLive => statusCode > 0 && statusCode < 10000;
  bool get isFinished => statusCode >= 10000 || statusCode == -1;

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
      streams: streams,
    );
  }

  LiveMatch copyWith({List<StreamServer>? streams, String? liveClock, int? homeScore, int? awayScore}) {
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
      statusCode: statusCode,
      startDateMs: startDateMs,
      liveClock: liveClock ?? this.liveClock,
      hot: hot,
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

class SportTab {
  const SportTab(this.type, this.label, this.icon);
  final int type;
  final String label;
  final IconData icon;
}

const primarySports = <SportTab>[
  SportTab(0, 'All', Icons.grid_view_rounded),
  SportTab(1, 'Football', Icons.sports_soccer),
  SportTab(2, 'Basketball', Icons.sports_basketball),
  SportTab(3, 'Tennis', Icons.sports_tennis),
  SportTab(90, 'Others', Icons.more_horiz),
];

const moreSports = <SportTab>[
  SportTab(5, 'Golf', Icons.sports_golf),
  SportTab(9, 'Am. Football', Icons.sports_football),
  SportTab(8, 'Rugby', Icons.sports_rugby),
  SportTab(6, 'Cricket', Icons.sports_cricket),
  SportTab(11, 'Hockey', Icons.sports_hockey),
  SportTab(4, 'Baseball', Icons.sports_baseball),
  SportTab(12, 'Volleyball', Icons.sports_volleyball),
  SportTab(7, 'Motorsport', Icons.sports_motorsports),
];
