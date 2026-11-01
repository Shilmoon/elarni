import 'package:country_flags/country_flags.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:l10n_countries/l10n_countries.dart';

import 'strings.dart';

/// A provider's location label, not a measured or geolocated server position.
final class ServerLocation {
  const ServerLocation(this.code, this._englishName);

  final String code;
  final String _englishName;

  /// The country in the interface language.
  String get name => appLocale.languageCode == 'ru'
      ? _russianNames[code] ?? _englishName
      : _englishName;

  static final _english = EnCountriesL10N().map;
  static final _russian = RuCountriesL10N().map;
  static final Map<String, ServerLocation> _locations = {
    for (final entry in _english.entries)
      if (entry.key.length == 3)
        if (FlagCode.fromCountryCode(entry.key) case final String code)
          if (code.length == 2)
            code.toUpperCase(): ServerLocation(code.toUpperCase(), entry.value),
    'EU': const ServerLocation('EU', 'European Union'),
  };
  static final Map<String, String> _russianNames = {
    for (final entry in _russian.entries)
      if (entry.key.length == 3)
        if (FlagCode.fromCountryCode(entry.key) case final String code)
          if (code.length == 2) code.toUpperCase(): entry.value,
    'EU': 'Европейский союз',
  };
  // Common abbreviations and the EU names the localization tables lack.
  static const _aliases = {
    'uk': 'GB',
    'uae': 'AE',
    'оаэ': 'AE',
    'european union': 'EU',
    'евросоюз': 'EU',
    'европейский союз': 'EU',
  };
  // CF labels Cloudflare in provider names, not the Central African Republic.
  static const _ignoredPrefixes = {'CF'};
  // US places whose names contain a country or territory name.
  static final _places = RegExp(
    r'(^|[^\p{L}\p{N}])(new jersey|jersey city|new mexico|нью-джерси|нью-мексико)(?=$|[^\p{L}\p{N}])',
    caseSensitive: false,
    unicode: true,
  );
  static final Map<String, Set<String>> _names = _countryNames();
  static Map<String, Set<String>> _countryNames() {
    final names = <String, Set<String>>{};
    for (final table in [_english, _russian]) {
      for (final entry in table.entries) {
        final code = FlagCode.fromCountryCode(
          entry.key.replaceAll('+', ''),
        )?.toUpperCase();
        if (!_locations.containsKey(code)) continue;
        (names[entry.value.toLowerCase()] ??= {}).add(code!);
      }
    }
    for (final MapEntry(:key, :value) in _aliases.entries) {
      (names[key] ??= {}).add(value);
    }
    return names;
  }

  static final _namePattern = RegExp(
    r'(^|[^\p{L}\p{N}])(' +
        (_names.keys.toList()..sort((a, b) => b.length.compareTo(a.length)))
            .map(RegExp.escape)
            .join('|') +
        r')(?=$|[^\p{L}\p{N}])',
    caseSensitive: false,
    unicode: true,
  );
  static final _flagPattern = RegExp(
    r'[\u{1F1E6}-\u{1F1FF}]{2}',
    unicode: true,
  );
  // Country codes need an explicit leading label. Ordinary words such as
  // "in", "at" and "no" elsewhere in provider names are not country evidence.
  static final _prefixPattern = RegExp(
    r'^(?:\[|\()?([A-Z]{2,3})(?=$|[\s\]\)\-_|•])',
  );

  // Rows ask on every rebuild, and the name pattern is large.
  static final _fromNameCache = <String, ServerLocation?>{};

  /// An ISO country code, such as the exit country a trace reports.
  static ServerLocation? fromCode(String code) => _locations[code];

  static ServerLocation? fromName(String name) {
    // shortcut: drops the whole cache at a cap, enough for provider lists.
    if (_fromNameCache.length >= 8192) _fromNameCache.clear();
    return _fromNameCache.putIfAbsent(name, () => _parseName(name));
  }

  /// A Russian label anywhere, a chain's entry included.
  static bool russianEntry(String name) => _codes(name).contains('RU');

  static ServerLocation? _parseName(String name) {
    final codes = _codes(name);
    // Conflicting country labels can describe chains; do not invent an exit.
    return codes.length == 1 ? _locations[codes.single] : null;
  }

  static Set<String> _codes(String name) {
    final codes = <String>{};
    for (final flag in _flagPattern.allMatches(name)) {
      final code = String.fromCharCodes(
        flag.group(0)!.runes.map((rune) => rune - 0x1f1e6 + 65),
      );
      if (_locations.containsKey(code)) codes.add(code);
    }
    final text = name.replaceAllMapped(_places, (match) => '${match[1]} ');
    for (final match in _namePattern.allMatches(text)) {
      codes.addAll(_names[match.group(2)!.toLowerCase()] ?? {});
    }
    final prefix = _prefixPattern.firstMatch(name.trim())?.group(1);
    if (prefix != null && !_ignoredPrefixes.contains(prefix)) {
      final code =
          _aliases[prefix.toLowerCase()] ??
          FlagCode.fromCountryCode(prefix)?.toUpperCase() ??
          prefix;
      if (_locations.containsKey(code)) codes.add(code);
    }
    // The EU flag often accompanies a member country, which is more specific.
    if (codes.length > 1) codes.remove('EU');
    return codes;
  }

  static String displayName(String name) {
    if (fromName(name) == null) return name;
    final label = name.replaceAll(_flagPattern, '').trim();
    return label.isEmpty ? fromName(name)!.name : label;
  }
}

class LocationFlag extends StatelessWidget {
  const LocationFlag({required this.location, super.key});
  final ServerLocation? location;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 30,
      height: 22,
      child: location == null
          ? Icon(
              CupertinoIcons.globe,
              size: 24,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : switch (location!.code) {
              // The flag package files the EU flag under the euro.
              'EU' => CountryFlag.fromCurrencyCode('EUR', theme: _theme),
              final code => CountryFlag.fromCountryCode(code, theme: _theme),
            },
    ),
  );

  static const _theme = ImageTheme(
    width: 30,
    height: 22,
    shape: RoundedRectangle(3),
  );
}
