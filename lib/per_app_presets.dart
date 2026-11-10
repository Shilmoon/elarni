/// Groups of apps that are often listed together. Each app is found in the
/// host's app list, by the names the systems give it or by a rule that names
/// it wherever it is installed, so it takes the rule this computer gives it,
/// which follows the app through updates, rather than a guessed path.
final class AppPreset {
  const AppPreset(this.id, this.apps);

  /// Also the key of the preset's label.
  final String id;
  final List<PresetApp> apps;

  /// Each app's rules among the host's apps. A host app goes to one app only:
  /// to one whose rule or folder names it before one that shares its name, as
  /// Claude Code, in a folder named claude, would otherwise be the Claude app.
  List<({PresetApp app, List<String> rules})> find(
    Iterable<({String name, String process})> hosted,
  ) {
    final taken = <String>{};
    final named = [
      for (final app in apps)
        [
          for (final host in hosted)
            if (app._rules(host.process) && taken.add(host.process))
              host.process,
        ],
    ];
    final called = [
      for (final app in apps)
        [
          for (final host in hosted)
            if (app._called(host.name) && taken.add(host.process)) host.process,
        ],
    ];
    return [
      for (final (index, app) in apps.indexed)
        (
          app: app,
          rules: [
            for (final process in [...named[index], ...called[index]])
              app.children ? 'children:$process' : process,
          ],
        ),
    ];
  }
}

final class PresetApp {
  const PresetApp(
    this.name, {
    this.names = const [],
    this.rules = const [],
    this.folder,
    this.children = false,
  });

  final String name;

  /// Names the hosts give the app, compared without case, spaces or punctuation.
  final List<String> names;

  /// Rules that name the app in any folder: Flatpak app IDs and Snap folders.
  final List<String> rules;

  /// A pattern, without case, for the rule of its folder of versions, such as
  /// Claude Code's.
  final String? folder;

  /// Whether its rule also takes the programs the app starts.
  final bool children;

  bool _rules(String process) =>
      rules.contains(process) ||
      (folder != null &&
          RegExp(folder!, caseSensitive: false).hasMatch(process));

  bool _called(String name) => names.any((known) => _key(known) == _key(name));

  static String _key(String name) => name.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );
}

const appPresets = [
  AppPreset('discord', [
    PresetApp(
      'Discord',
      names: ['Discord'],
      rules: ['flatpak:com.discordapp.Discord', '/snap/discord/'],
    ),
  ]),
  AppPreset('telegram', [
    PresetApp(
      'Telegram',
      names: ['Telegram', 'Telegram Desktop'],
      rules: ['flatpak:org.telegram.desktop', '/snap/telegram-desktop/'],
    ),
  ]),
  // Claude Code runs from a folder of versions: ~/.local/share/claude/versions/
  // when installed on its own, and claude-code/ in the Claude app's folder,
  // which also starts it.
  AppPreset('claude', [
    PresetApp('Claude', names: ['Claude'], children: true),
    PresetApp(
      'Claude Code',
      names: ['Claude Code'],
      folder: r'[\\/](claude[\\/]versions|claude-code)[\\/]$',
    ),
  ]),
  // Steam starts the games it installs.
  AppPreset('steam', [
    PresetApp(
      'Steam',
      names: ['Steam'],
      rules: ['flatpak:com.valvesoftware.Steam', '/snap/steam/'],
      children: true,
    ),
  ]),
  AppPreset('browsers', [
    PresetApp(
      'Google Chrome',
      names: ['Google Chrome'],
      rules: ['flatpak:com.google.Chrome'],
    ),
    PresetApp(
      'Microsoft Edge',
      names: ['Microsoft Edge'],
      rules: ['flatpak:com.microsoft.Edge'],
    ),
    PresetApp(
      'Firefox',
      names: ['Firefox', 'Mozilla Firefox', 'Firefox Web Browser'],
      rules: ['flatpak:org.mozilla.firefox', '/snap/firefox/'],
    ),
    PresetApp(
      'Brave',
      names: ['Brave', 'Brave Browser', 'Brave Web Browser'],
      rules: ['flatpak:com.brave.Browser', '/snap/brave/'],
    ),
    PresetApp(
      'Opera',
      names: ['Opera', 'Opera Browser'],
      rules: ['flatpak:com.opera.Opera'],
    ),
    PresetApp(
      'Vivaldi',
      names: ['Vivaldi'],
      rules: ['flatpak:com.vivaldi.Vivaldi'],
    ),
    PresetApp(
      'Yandex Browser',
      names: ['Yandex', 'Yandex Browser', 'Яндекс Браузер'],
    ),
  ]),
];
