import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_version.dart';
import 'package:elarni/elarni_app.dart';
import 'package:elarni/elarni_widgets.dart';
import 'package:elarni/headless_transport.dart' show windowsPowerShell;
import 'elarni_app_test.dart' show openSettings, selectCategory;
import 'support/fake_tunnel_control.dart';

class VersionedControl extends FakeTunnelControl {
  VersionedControl(this.version);
  final String? version;

  @override
  Future<Map<String, Object?>> systemInfo() async => {
    'os': 'Fixture OS',
    'appVersion': ?version,
    'coreVersion': '26.7.28',
    'physicalMemoryBytes': 34230763520,
  };
}

void main() {
  for (final version in ['0.2.0+2', null]) {
    testWidgets('System info shows the build version ($version)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ElarniApp(tunnelControl: VersionedControl(version), windows: true),
      );
      await tester.pumpAndSettle();
      await openSettings(tester);
      await selectCategory(tester, SettingsCategory.system);
      await tester.pumpAndSettle();
      expect(find.text('Fixture OS'), findsOneWidget);
      expect(find.text('31.9 GB'), findsOneWidget);
      // A platform that reports no app version shows no placeholder for it.
      expect(
        find.text(
          version == null
              ? 'Xray core 26.7.28'
              : 'Elarni $version · Xray core 26.7.28',
        ),
        findsOneWidget,
      );
    });
  }

  // Regression: System info and diagnostics named Windows 11 "Windows 10".
  test('Windows 11 is named by its build number', () {
    expect(
      desktopOSVersion('"Windows 10 Pro" 10.0 (Build 26200)'),
      '"Windows 11 Pro" 10.0 (Build 26200)',
    );
    expect(
      desktopOSVersion('"Windows 10 Home" 10.0 (Build 22000)'),
      '"Windows 11 Home" 10.0 (Build 22000)',
    );
    for (final unchanged in [
      '"Windows 10 Pro" 10.0 (Build 19045)',
      '"Windows Server 2025 Standard" 10.0 (Build 26100)',
      'Linux 6.8.0-45-generic #45-Ubuntu SMP',
    ])
      expect(desktopOSVersion(unchanged), unchanged);
  });

  test(
    'a Linux bundle reports the version Flutter writes beside its assets',
    () async {
      final bundle = await Directory.systemTemp.createTemp('elarni-version-');
      addTearDown(() => bundle.delete(recursive: true));
      final assets = await Directory(
        '${bundle.path}/data/flutter_assets',
      ).create(recursive: true);
      await File('${assets.path}/version.json').writeAsString(
        '{"app_name":"elarni","version":"0.2.0","build_number":"2","package_name":"elarni"}',
      );
      expect(linuxBundleVersion(bundle.path), '0.2.0+2');
    },
  );

  test(
    'Windows reads the product version from the version resource',
    () async {
      final library =
          '${Platform.environment['SystemRoot']}\\System32\\kernel32.dll';
      final expected = await Process.run(windowsPowerShell, [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-Item -LiteralPath '$library').VersionInfo.ProductVersion",
      ]);
      final version = (expected.stdout as String).trim();
      expect(version, isNotEmpty);
      expect(windowsProductVersion(library), version);
      // The test runner is built without a version resource.
      expect(windowsProductVersion(Platform.resolvedExecutable), isNull);
    },
    skip: !Platform.isWindows,
  );
}
