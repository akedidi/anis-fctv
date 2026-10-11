import 'dart:convert';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'models.dart';

class FctvApi {
  FctvApi({String? baseUrl})
      : baseUrl = baseUrl ??
            const String.fromEnvironment(
              'API_BASE',
              // Prefer localhost so browser pages opened as http://localhost:8080/ hit the same host family.
              defaultValue: 'http://localhost:3000',
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
    Future<({LiveMatch? match, List<StreamServer> streams})> once() async {
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
      var streams = (body['streams'] as List? ?? [])
          .whereType<Map>()
          .map((e) => StreamServer.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      // Some payloads only embed servers on `match.streams`.
      if (streams.isEmpty && matchJson is Map) {
        streams = (matchJson['streams'] as List? ?? [])
            .whereType<Map>()
            .map((e) => StreamServer.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      return (
        match: matchJson is Map
            ? LiveMatch.fromJson(Map<String, dynamic>.from(matchJson))
            : null,
        streams: streams,
      );
    }

    try {
      return await once();
    } catch (_) {
      // Brief pause then one more hit — API also clears rb-session / signatures on empty/auth.
      await Future<void>.delayed(const Duration(milliseconds: 450));
      return once();
    }
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
    // iOS sends Locale region for stream/detail — not the API server's IP geo.
    final country = ui.PlatformDispatcher.instance.locale.countryCode?.toUpperCase();
    if (country != null && country.length == 2) q['country'] = country;
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
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    // Surface failures (401 Vercel protection, 502 cold start) instead of silent [].
    if (res.statusCode >= 400) {
      throw Exception(body['error'] ?? 'events failed (${res.statusCode})');
    }
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

  Future<List<MatchStatRow>> fetchStats({
    required int matchId,
    required int sportType,
  }) async {
    final res = await http.get(
      _u('/api/match/stats', {
        'matchId': '$matchId',
        'sportType': '$sportType',
      }),
    );
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      if (res.statusCode >= 400) return const [];
      rethrow;
    }
    if (res.statusCode >= 400) return const [];
    return (body['stats'] as List? ?? [])
        .whereType<Map>()
        .map((e) => MatchStatRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<H2HSummary> fetchH2H({
    required int matchId,
    required int sportType,
    String homeName = '',
  }) async {
    final q = <String, String>{
      'matchId': '$matchId',
      'sportType': '$sportType',
    };
    if (homeName.isNotEmpty) q['homeName'] = homeName;
    final res = await http.get(_u('/api/match/h2h', q));
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      if (res.statusCode >= 400) return const H2HSummary();
      rethrow;
    }
    if (res.statusCode >= 400) return const H2HSummary();
    final h2h = body['h2h'];
    if (h2h is! Map) return const H2HSummary();
    return H2HSummary.fromJson(Map<String, dynamic>.from(h2h));
  }
}
