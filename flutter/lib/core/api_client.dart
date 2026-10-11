import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class FctvApi {
  FctvApi({String? baseUrl})
      : baseUrl = baseUrl ??
            const String.fromEnvironment(
              'API_BASE',
              defaultValue: 'http://127.0.0.1:3000',
            );

  final String baseUrl;

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<List<LiveMatch>> fetchLive({int sportType = 0, int language = 0}) async {
    final res = await http.get(
      _u('/api/live', {
        'sportType': '$sportType',
        'language': '$language',
      }),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw Exception(body['error'] ?? 'live failed (${res.statusCode})');
    }
    final list = body['matches'] as List? ?? [];
    return list
        .whereType<Map>()
        .map((e) => LiveMatch.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<({LiveMatch? match, List<StreamServer> streams})> fetchMatchDetail({
    required int matchId,
    required int sportType,
    int language = 0,
  }) async {
    final res = await http.get(
      _u('/api/match', {
        'matchId': '$matchId',
        'sportType': '$sportType',
        'language': '$language',
      }),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw Exception(body['error'] ?? 'detail failed');
    }
    final matchJson = body['match'];
    final streams = (body['streams'] as List? ?? [])
        .whereType<Map>()
        .map((e) => StreamServer.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return (
      match: matchJson is Map
          ? LiveMatch.fromJson(Map<String, dynamic>.from(matchJson))
          : null,
      streams: streams,
    );
  }

  Future<String> resolvePlayback({
    required int matchId,
    required int sportType,
    String? streamId,
  }) async {
    final q = <String, String>{
      'matchId': '$matchId',
      'sportType': '$sportType',
    };
    if (streamId != null && streamId.isNotEmpty) q['streamId'] = streamId;
    final res = await http.get(_u('/api/resolve', q));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw Exception(body['error'] ?? 'resolve failed');
    }
    final url = body['playableUrl'] as String?;
    if (url == null || url.isEmpty) throw Exception('missing playable url');
    return url;
  }

  Future<List<MatchEvent>> fetchEvents({
    required int matchId,
    required int sportType,
  }) async {
    final res = await http.get(
      _u('/api/match/events', {
        'matchId': '$matchId',
        'sportType': '$sportType',
      }),
    );
    if (res.statusCode >= 400) return const [];
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['events'] as List? ?? [])
        .whereType<Map>()
        .map((e) => MatchEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<({List<LineupPlayer> home, List<LineupPlayer> away})> fetchLineup({
    required int matchId,
    required int sportType,
  }) async {
    final res = await http.get(
      _u('/api/match/lineup', {
        'matchId': '$matchId',
        'sportType': '$sportType',
      }),
    );
    if (res.statusCode >= 400) {
      return (home: const <LineupPlayer>[], away: const <LineupPlayer>[]);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final lineup = body['lineup'] as Map<String, dynamic>? ?? {};
    List<LineupPlayer> parse(String key) => (lineup[key] as List? ?? [])
        .whereType<Map>()
        .map((e) => LineupPlayer.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return (home: parse('home'), away: parse('away'));
  }
}
