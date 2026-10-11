/// Mirrors iOS `CountryHelper` for stream/channel flags.
class CountryHint {
  const CountryHint({required this.label, this.code});
  final String label;
  final String? code;
}

class CountryHelper {
  static const _accepted = {
    'FR', 'DE', 'ES', 'IT', 'PT', 'NL', 'PL', 'SE', 'NO', 'DK', 'FI',
    'GB', 'US', 'CA', 'BR', 'AR', 'MX', 'AU', 'NZ', 'JP', 'KR', 'CN',
    'IN', 'SA', 'AE', 'QA', 'TR', 'RU', 'UA', 'BE', 'CH', 'AT', 'IE', 'ZA',
    'PY', 'BD', 'PK', 'LK', 'JM', 'GR', 'CZ', 'RO', 'HU', 'HR',
    'CL', 'CO', 'PE', 'UY', 'EC', 'VE', 'BO', 'CR', 'PA',
    'DZ', 'MA', 'TN', 'EG', 'NG', 'GH', 'SN', 'CI', 'KE',
    'TH', 'VN', 'ID', 'PH', 'MY', 'SG', 'TW', 'HK', 'KH',
    'IL', 'IQ', 'KW', 'BH', 'OM', 'JO', 'LB',
    'BG', 'RS', 'SI', 'SK', 'LT', 'LV', 'EE',
  };

  static const _banned = {'HD', 'SD', 'UHD', 'LQ', 'HQ', 'OK', 'TV', 'FC', 'AI', 'NOW', 'TYR'};

  static const _names = {
    'FR': 'France', 'DE': 'Germany', 'ES': 'Spain', 'IT': 'Italy', 'PT': 'Portugal',
    'NL': 'Netherlands', 'PL': 'Poland', 'SE': 'Sweden', 'GB': 'United Kingdom',
    'US': 'United States', 'CA': 'Canada', 'BR': 'Brazil', 'AR': 'Argentina',
    'MX': 'Mexico', 'CL': 'Chile', 'CO': 'Colombia', 'SA': 'Saudi Arabia',
    'AE': 'United Arab Emirates', 'QA': 'Qatar', 'TR': 'Turkey', 'DZ': 'Algeria',
    'MA': 'Morocco', 'TN': 'Tunisia', 'EG': 'Egypt', 'AU': 'Australia',
    'JP': 'Japan', 'KR': 'Korea', 'CN': 'China', 'IN': 'India', 'TH': 'Thailand',
    'VN': 'Vietnam', 'ID': 'Indonesia', 'PH': 'Philippines', 'MY': 'Malaysia',
    'SG': 'Singapore', 'TW': 'Taiwan', 'HK': 'Hong Kong', 'BE': 'Belgium',
    'CH': 'Switzerland', 'AT': 'Austria', 'IE': 'Ireland', 'ZA': 'South Africa',
    'RU': 'Russia', 'UA': 'Ukraine', 'NO': 'Norway', 'DK': 'Denmark', 'FI': 'Finland',
  };

  static const _regionToCode = {
    'england': 'GB', 'united kingdom': 'GB', 'uk': 'GB', 'great britain': 'GB',
    'scotland': 'GB', 'wales': 'GB', 'france': 'FR', 'spain': 'ES', 'germany': 'DE',
    'italy': 'IT', 'portugal': 'PT', 'netherlands': 'NL', 'holland': 'NL',
    'belgium': 'BE', 'switzerland': 'CH', 'austria': 'AT', 'ireland': 'IE',
    'usa': 'US', 'united states': 'US', 'america': 'US', 'brazil': 'BR',
    'argentina': 'AR', 'mexico': 'MX', 'chile': 'CL', 'colombia': 'CO',
    'japan': 'JP', 'korea': 'KR', 'china': 'CN', 'australia': 'AU',
    'new zealand': 'NZ', 'turkey': 'TR', 'saudi arabia': 'SA', 'uae': 'AE',
    'qatar': 'QA', 'europe': 'EU', 'asia': 'AS', 'africa': 'AF',
    'paraguay': 'PY', 'algeria': 'DZ', 'morocco': 'MA', 'tunisia': 'TN',
    'egypt': 'EG', 'south africa': 'ZA', 'thailand': 'TH', 'vietnam': 'VN',
    'indonesia': 'ID', 'philippines': 'PH', 'malaysia': 'MY', 'singapore': 'SG',
  };

  static const _brands = [
    ('bein sports fr', 'FR'), ('bein sport fr', 'FR'), ('canal+', 'FR'),
    ('tf1', 'FR'), ('m6', 'FR'), ('rmc sport', 'FR'), ('eurosport fr', 'FR'),
    ('sky sport de', 'DE'), ('dazn de', 'DE'), ('sky uk', 'GB'),
    ('bt sport', 'GB'), ('tnt sports', 'GB'), ('espn', 'US'), ('fox sports', 'US'),
    ('fubo', 'US'), ('raisport', 'IT'), ('sky italia', 'IT'), ('dazn it', 'IT'),
    ('now it', 'IT'), ('movistar', 'ES'), ('dazn es', 'ES'), ('sport tv', 'PT'),
    ('viaplay', 'SE'), ('polsat', 'PL'), ('ssc', 'SA'), ('abu dhabi', 'AE'),
    ('td en', 'GB'), ('tnt cl', 'CL'), ('dz fr', 'DZ'), ('dz es', 'DZ'),
    ('dz pt', 'PT'), ('ai en', 'GB'), ('ai th', 'TH'), ('tv vn', 'VN'),
  ];

  static String _normalize(String raw) {
    final u = raw.toUpperCase();
    if (u == 'UK' || u == 'EN') return 'GB';
    return u;
  }

  static String? trailingIso(String streamName) {
    final trimmed = streamName.trim();
    if (trimmed.isEmpty) return null;
    for (final re in [RegExp(r'\b([A-Za-z]{2})$'), RegExp(r'[-_/]([A-Za-z]{2})$')]) {
      final m = re.firstMatch(trimmed);
      if (m == null) continue;
      final code = _normalize(m.group(1)!);
      if (_banned.contains(code)) continue;
      if (_accepted.contains(code)) return code;
    }
    return null;
  }

  static String labelFor(String code) => _names[code] ?? code;

  static CountryHint infer({required String streamName, String matchRegion = ''}) {
    final blob = '$streamName $matchRegion'.trim();
    if (blob.isEmpty) return const CountryHint(label: '');
    final lower = blob.toLowerCase();

    final trailing = trailingIso(streamName);
    if (trailing != null) {
      return CountryHint(label: labelFor(trailing), code: trailing);
    }

    for (final (needle, code) in _brands) {
      if (lower.contains(needle)) {
        final n = _normalize(code);
        return CountryHint(label: labelFor(n), code: n);
      }
    }

    for (final re in [RegExp(r'\(([A-Za-z]{2})\)'), RegExp(r'\[([A-Za-z]{2})\]')]) {
      final m = re.firstMatch(blob);
      if (m == null) continue;
      final n = _normalize(m.group(1)!);
      if (_accepted.contains(n)) return CountryHint(label: labelFor(n), code: n);
    }

    final region = matchRegion.trim();
    if (region.isNotEmpty) {
      final code = _regionToCode[region.toLowerCase()];
      if (code != null) {
        if (code == 'EU' || code == 'AS' || code == 'AF') {
          return CountryHint(label: region);
        }
        return CountryHint(label: labelFor(code), code: code);
      }
      return CountryHint(label: region);
    }
    return const CountryHint(label: '');
  }

  static String? flagCDNURL(String? code, {int width = 40}) {
    if (code == null || code.isEmpty) return null;
    final c = code.toLowerCase();
    if (c.length != 2 || c == 'eu' || c == 'as' || c == 'af') return null;
    return 'https://flagcdn.com/w$width/$c.png';
  }

  static String? flagEmoji(String? code) {
    if (code == null || code.length != 2) return null;
    final upper = code.toUpperCase();
    if (upper == 'EU' || upper == 'AS' || upper == 'AF') return null;
    const base = 0x1F1E6;
    return String.fromCharCodes([
      base + (upper.codeUnitAt(0) - 0x41),
      base + (upper.codeUnitAt(1) - 0x41),
    ]);
  }
}
