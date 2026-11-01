// Run after flutter pub get:
// dart --packages=.dart_tool/package_config.json scripts/export-android-locations.dart
// Uses the desktop's pinned country data; licenses are in THIRD_PARTY_NOTICES.
import 'dart:convert';
import 'dart:io';
import 'package:country_flags/src/flag_code.dart';
import 'package:l10n_countries/l10n_countries.dart';

void main() {
  final english = EnCountriesL10N().map;
  final locations = <String, Map<String, Object>>{};
  for (final entry in english.entries) {
    if (entry.key.length != 3) continue;
    final code = FlagCode.fromCountryCode(entry.key)?.toUpperCase();
    if (code == null || code.length != 2) continue;
    locations[code] = {
      'code': code,
      'name': entry.value,
      'prefixes': [code, entry.key],
      'names': <String>{},
    };
  }
  // Matches the desktop's EU group, which the country tables lack.
  locations['EU'] = {
    'code': 'EU',
    'name': 'European Union',
    'prefixes': ['EU'],
    'names': {'european union', 'евросоюз', 'европейский союз'},
  };
  for (final table in [english, RuCountriesL10N().map]) {
    for (final entry in table.entries) {
      final code = FlagCode.fromCountryCode(
        entry.key.replaceAll('+', ''),
      )?.toUpperCase();
      final record = locations[code];
      if (record != null)
        (record['names']! as Set<String>).add(entry.value.toLowerCase());
    }
  }
  // The desktop's abbreviations, which the country tables lack.
  for (final (alias, code) in [('uk', 'GB'), ('uae', 'AE'), ('оаэ', 'AE')]) {
    (locations[code]!['names']! as Set<String>).add(alias);
  }
  (locations['GB']!['prefixes']! as List<String>).add('UK');
  (locations['AE']!['prefixes']! as List<String>).add('UAE');
  // CF labels Cloudflare in provider names, not the Central African Republic.
  (locations['CF']!['prefixes']! as List<String>).remove('CF');
  final records =
      locations.values
          .map(
            (entry) => {
              ...entry,
              'names': (entry['names']! as Set<String>).toList()..sort(),
            },
          )
          .toList()
        ..sort(
          (a, b) => (a['code']! as String).compareTo(b['code']! as String),
        );
  final output = File('android/app/src/main/assets/server-locations.json');
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(records)}\n',
  );
  stdout.writeln(
    'Exported ${records.length} desktop country records to ${output.path}',
  );
}
