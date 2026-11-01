import 'dart:convert';
import 'dart:io';

import 'package:elarni/elarni_app.dart';
import 'package:elarni/tunnel_channel.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _messages(String locale) => {
  for (final MapEntry(:key, :value)
      in (jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
              as Map<String, Object?>)
          .entries)
    if (!key.startsWith('@')) key: value! as String,
};

// ICU arguments, such as {count} inside a plural; selector words are not ASCII
// words followed by a comma or brace.
Set<String> _placeholders(String message) => RegExp(
  r'\{(\w+)[,}]',
).allMatches(message).map((match) => match[1]!).toSet();

void main() {
  test('every English message has a Russian one with the same arguments', () {
    final english = _messages('en');
    final russian = _messages('ru');
    expect(russian.keys.toSet(), english.keys.toSet());
    for (final MapEntry(:key, :value) in english.entries) {
      expect(russian[key]!.trim(), isNotEmpty, reason: key);
      expect(_placeholders(russian[key]!), _placeholders(value), reason: key);
    }
  });

  test('the interface words every subscription download failure', () {
    for (final MapEntry(:key, :value) in subscriptionFailures.entries)
      expect(subscriptionFailureText(key, 'The provider'), value, reason: key);
  });

  // Text for people goes through lib/l10n; these names read the same in Russian.
  test('the interface has no new hard-coded labels', () {
    const allowed = {'Elarni', 'IPv4', 'IPv6', 'Keep-alive', 'Xray JSON'};
    final label = RegExp(
      r'''(?:Text\(\s*|(?:label|tooltip|hintText|labelText|helperText|semanticLabel|message|title): )['"]([A-Z][^'"]*)['"]''',
    );
    final found = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            !file.uri.pathSegments.contains('l10n'))
          for (final match in label.allMatches(file.readAsStringSync()))
            if (!allowed.contains(match[1])) '${file.path}: ${match[1]}',
    ];
    expect(found, isEmpty);
  });

  group('Android', () {
    const res = 'android/app/src/main/res';
    // name -> placeholders; a plural's quantities appear as name/quantity.
    Map<String, Set<String>> resources(String folder) {
      final xml = File('$res/$folder/strings.xml').readAsStringSync();
      final format = RegExp(r'%(?:\d+\$)?[sd]');
      Set<String> args(String text) => format
          .allMatches(text.replaceAll('%%', ''))
          .map((match) => match[0]!)
          .toSet();
      return {
        for (final match in RegExp(
          r'<string name="(\w+)"[^>]*>(.*?)</string>',
        ).allMatches(xml))
          match[1]!: args(match[2]!),
        for (final plural in RegExp(
          r'<plurals name="(\w+)">(.*?)</plurals>',
          dotAll: true,
        ).allMatches(xml))
          for (final item in RegExp(
            r'<item quantity="(\w+)">(.*?)</item>',
          ).allMatches(plural[2]!))
            '${plural[1]}/${item[1]}': args(item[2]!),
      };
    }

    test('every English string has a Russian one with the same arguments', () {
      final english = resources('values');
      final russian = resources('values-ru');
      expect(english, isNotEmpty);
      final strings = {
        for (final key in english.keys)
          if (!key.contains('/')) key,
      };
      expect({
        for (final key in russian.keys)
          if (!key.contains('/')) key,
      }, strings);
      for (final key in strings) {
        expect(russian[key], english[key], reason: key);
      }
      // Russian counts need one, few and many; every form takes the same arguments.
      for (final plural in {
        for (final key in english.keys)
          if (key.contains('/')) key.split('/').first,
      }) {
        final forms = english['$plural/other']!;
        for (final quantity in ['one', 'few', 'many', 'other']) {
          expect(
            russian['$plural/$quantity'],
            forms,
            reason: '$plural/$quantity',
          );
        }
        expect(english['$plural/one'], forms, reason: '$plural/one');
      }
    });

    // Text for people goes through res/values; these names read the same in Russian.
    test('the app has no new hard-coded labels', () {
      const allowed = {
        'Elarni',
        'IPv4',
        'IPv6',
        'Xray',
        'Xray JSON',
        'Clash',
        'Tor',
        'Telegram',
      };
      final label = RegExp(
        r'(?:Text\(|(?:title|contentDescription|notice|error|localError) = |'
        r'(?:SettingsTile|SettingsGroup|SettingsRow|SettingsHeading|SettingsText|TextField|ChoiceField|DetailValue|'
        r'confirm|setContentTitle|setContentText|showSnackbar)\()"([A-Z][^"$]*)"',
      );
      final found = [
        for (final file in Directory(
          'android/app/src/main/java/com/elarni',
        ).listSync())
          if (file is File && file.path.endsWith('.kt'))
            for (final match in label.allMatches(file.readAsStringSync()))
              if (!allowed.contains(match[1])) '${file.path}: ${match[1]}',
      ];
      expect(found, isEmpty);
    });
  });

  group('Apple', () {
    // Argument types in any order, since a translation may number them (%2$@).
    List<String> args(String text) => [
      for (final match in RegExp(
        r'%(?:\d+\$)?(@|lld|ld|d)|\$\{(\w+)\}',
      ).allMatches(text.replaceAll('%%', '')))
        match[1] ?? match[2]!,
    ]..sort();

    test('every catalog key has Russian with the same arguments', () {
      const catalogs = [
        'ios/Elarni/Elarni/Localizable.xcstrings',
        'ios/Elarni/Elarni/InfoPlist.xcstrings',
        'ios/Elarni/Elarni/AppShortcuts.xcstrings',
        'ios/Elarni/ElarniWidgets/Localizable.xcstrings',
        'ios/Elarni/ElarniPacketTunnel/Localizable.xcstrings',
        'macos/Runner/Localizable.xcstrings',
        'macos/Runner/InfoPlist.xcstrings',
      ];
      for (final path in catalogs) {
        final strings =
            (jsonDecode(File(path).readAsStringSync()) as Map)['strings']
                as Map<String, Object?>;
        expect(strings, isNotEmpty, reason: path);
        for (final MapEntry(:key, :value) in strings.entries) {
          final entry = value! as Map<String, Object?>;
          if (entry['shouldTranslate'] == false) continue;
          final ru =
              (entry['localizations'] as Map?)?['ru'] as Map<String, Object?>?;
          final plural = (ru?['variations'] as Map?)?['plural'] as Map?;
          // Russian counts need one, few and many.
          final forms = plural == null
              ? {'': ru?['stringUnit']}
              : {
                  for (final quantity in ['one', 'few', 'many', 'other'])
                    quantity: (plural[quantity] as Map?)?['stringUnit'],
                };
          for (final MapEntry(key: quantity, value: unit) in forms.entries) {
            final text = (unit as Map?)?['value'] as String? ?? '';
            final reason = '$path: $key $quantity';
            expect(text.trim(), isNotEmpty, reason: reason);
            expect(args(text), args(key), reason: reason);
          }
        }
      }
    });

    test('the macOS main menu has Russian for every titled item', () {
      final xib = File(
        'macos/Runner/Base.lproj/MainMenu.xib',
      ).readAsStringSync();
      final titled = {
        for (final match in RegExp(
          r'<(?:menuItem|menu)\b[^>]*?\btitle="([^"]*)"[^>]*?\bid="([^"]+)"',
        ).allMatches(xib))
          // APP_NAME becomes the app's name at launch; the main menu has no visible title.
          if (match[1] != 'APP_NAME' && match[1] != 'Main Menu') match[2]!,
      };
      final russian = {
        for (final match
            in RegExp(
              r'^"([^".]+)\.title" = "(.+)";\r?$',
              multiLine: true,
            ).allMatches(
              File('macos/Runner/ru.lproj/MainMenu.strings').readAsStringSync(),
            ))
          match[1]!,
      };
      expect(titled, isNotEmpty);
      expect(russian, titled);
    });
  });
}
