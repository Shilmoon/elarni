import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_integration.dart';
import 'elarni_widgets.dart';
import 'per_app_presets.dart';
import 'tunnel_channel.dart';
import 'strings.dart';

/// The rule inside "children:<rule>", which also takes the programs that its
/// program starts; else the rule itself.
String innerRule(String rule) =>
    rule.startsWith('children:') ? rule.substring(9) : rule;

/// A routing-only exchange format. Runtime settings and credentials never enter it.
final class PerAppProfile {
  const PerAppProfile(
    this.platform,
    this.mode,
    this.processes, [
    this.targets = const <String, String>{},
  ]);

  final String platform, mode;
  final List<String> processes;
  final Map<String, String> targets;

  // Server IDs belong to this device's catalog.
  Map<String, String> get portableTargets => {
    for (final MapEntry(:key, :value) in targets.entries)
      if (!value.startsWith('node:')) key: value,
  };

  static String platformLabel(String platform) => switch (platform) {
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'android' => 'Android',
    _ => platform,
  };

  String get platformName => platformLabel(platform);

  String? get validationError {
    if (!{'macos', 'windows', 'linux', 'android'}.contains(platform)) {
      return l10n.perAppUnsupportedPlatform;
    }
    if (!TunnelSettings(
      xrayTunEnabled: true,
      perAppMode: mode,
      perAppProcesses: processes,
      perAppTargets: targets,
    ).validPerApp) {
      return l10n.perAppInvalidProfile;
    }
    // A "children:" rule is checked as the rule it wraps.
    final rules = processes.map(innerRule).toList();
    // Flatpak and AppImage rules name Linux apps, service rules Windows services.
    if (platform != 'linux' &&
        rules.any(
          (rule) => rule.startsWith('flatpak:') || rule.startsWith('appimage:'),
        )) {
      return l10n.perAppLinuxRulesElsewhere(platformName);
    }
    if (platform != 'windows' &&
        rules.any((rule) => rule.startsWith('service:'))) {
      return l10n.perAppServiceRulesElsewhere(platformName);
    }
    // Android routes by package; its apps' processes share the package's user ID.
    if (platform == 'android' &&
        processes.any(
          (package) => !RegExp(
            r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$',
          ).hasMatch(package),
        )) {
      return l10n.perAppAndroidPackages;
    }
    // Names can be shared deliberately; absolute paths belong to their OS.
    final windowsPath = RegExp(r'^[A-Za-z]:[\\/]');
    if (platform != 'windows' &&
        rules.any(
          (path) => windowsPath.hasMatch(path) || path.startsWith(r'\\'),
        )) {
      return l10n.perAppWindowsPathsElsewhere(platformName);
    }
    if (platform == 'linux' &&
        rules.any(
          (path) => path.split('/').any((part) => part.endsWith('.app')),
        )) {
      return l10n.perAppMacBundlesOnLinux;
    }
    if (platform == 'windows' &&
        rules.any((path) => path.startsWith('/') && !path.startsWith('//'))) {
      return l10n.perAppUnixPathsOnWindows;
    }
    return null;
  }

  String encode() {
    final error = validationError;
    if (error != null) throw FormatException(error);
    final shared = portableTargets;
    // Without targets the profile keeps the format older versions read.
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'elarni-per-app',
      'version': shared.isEmpty ? 1 : 2,
      'platform': platform,
      'mode': mode,
      'processes': processes,
      if (shared.isNotEmpty) 'targets': shared,
    });
  }

  static PerAppProfile decode(String text, {required String platform}) {
    if (text.length > 512 * 1024 || utf8.encode(text).length > 512 * 1024) {
      throw FormatException(l10n.perAppProfileTooLarge);
    }
    final value = jsonDecode(text);
    final targets = value is Map ? value['targets'] : null;
    if (value is! Map<String, dynamic> ||
        value.length != (value['version'] == 2 ? 6 : 5) ||
        value['format'] != 'elarni-per-app' ||
        !{1, 2}.contains(value['version']) ||
        value['platform'] is! String ||
        value['mode'] is! String ||
        value['processes'] is! List ||
        !(value['processes'] as List).every((item) => item is String) ||
        value['version'] == 2 &&
            (targets is! Map ||
                !targets.values.every(
                  (target) => target is String && !target.startsWith('node:'),
                ))) {
      throw FormatException(l10n.perAppUnsupportedProfile);
    }
    final profile = PerAppProfile(
      value['platform'] as String,
      value['mode'] as String,
      List<String>.from(value['processes'] as List),
      Map<String, String>.from(targets as Map? ?? const <String, String>{}),
    );
    if (profile.platform != platform) {
      throw FormatException(
        l10n.perAppOtherPlatformProfile(
          profile.platformName,
          platformLabel(platform),
        ),
      );
    }
    final error = profile.validationError;
    if (error != null) throw FormatException(error);
    return profile;
  }
}

// The dialog owns its field, which its closing animation still builds.
class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog({required this.initial, required this.settings});
  final String initial;
  final TunnelSettings settings;

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  late final address = TextEditingController(text: widget.initial);
  String? error;

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(l10n.localProxy),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.localProxyHelp),
          const SizedBox(height: 12),
          TextField(
            controller: address,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.proxyAddress,
              errorText: error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(l10n.cancel),
      ),
      FilledButton(
        onPressed: () {
          final text = address.text.trim();
          final problem = TunnelSettings.perAppProxyError(
            text,
            widget.settings,
          );
          if (problem != null) {
            setState(
              () => error = switch (problem) {
                'scheme' => l10n.proxyNeedsScheme,
                'notLocal' => l10n.proxyNotLocal,
                'noPort' => l10n.proxyNeedsPort,
                'extra' => l10n.proxyAddressOnly,
                _ => l10n.proxyIsOwnPort,
              },
            );
          } else {
            Navigator.pop(context, 'proxy:$text');
          }
        },
        child: Text(l10n.useProxy),
      ),
    ],
  );
}

/// Native metadata is optional. Rules remain usable when an app is not running
/// or its icon cannot be read, and metadata never enters a routing profile.
final class _RoutingApp {
  const _RoutingApp(this.name, this.process, [this.icon, this.suggested]);
  final String name, process;
  final Uint8List? icon;

  /// The host's update-proof rule for a saved rule that names one version.
  final String? suggested;
}

/// The rule for traffic whose app the lookup could not find: WSL, virtual
/// machines and containers, and connections that closed before routing.
const unknownOwnerRule = '-1';

enum _AppView { selected, picker, rules, paste, help, connections }

// Owned by the settings screen, so switching pages does not discard edits.
// Only this form's fields are merged into the latest saved settings.
class PerAppRoutingDraft {
  PerAppRoutingDraft(TunnelSettings saved) {
    reset(saved);
  }

  late TunnelSettings settings;
  late TunnelSettings _saved;
  String search = '', input = '';
  _AppView view = _AppView.selected;
  bool toolsExpanded = false;

  void reset(TunnelSettings saved) {
    _saved = saved;
    settings = saved.copyWith(
      perAppProcesses: List.of(saved.perAppProcesses),
      perAppTargets: Map.of(saved.perAppTargets),
    );
  }

  void rebase(TunnelSettings saved) {
    if (identical(_saved, saved)) return;
    settings = applyTo(saved);
    _saved = saved;
  }

  TunnelSettings applyTo(TunnelSettings saved) {
    final mode = settings.perAppMode == _saved.perAppMode
        ? saved.perAppMode
        : settings.perAppMode;
    final processes = List.of(
      listEquals(settings.perAppProcesses, _saved.perAppProcesses)
          ? saved.perAppProcesses
          : settings.perAppProcesses,
    );
    final targets = mapEquals(settings.perAppTargets, _saved.perAppTargets)
        ? saved.perAppTargets
        : settings.perAppTargets;
    return saved.copyWith(
      perAppMode: mode,
      perAppProcesses: processes,
      // A removed app takes its target with it.
      perAppTargets: {
        for (final MapEntry(:key, :value) in targets.entries)
          if (processes.contains(key)) key: value,
      },
      xrayTunEnabled: mode == 'off' ? saved.xrayTunEnabled : true,
      enforceRoutes: settings.enforceRoutes == _saved.enforceRoutes
          ? saved.enforceRoutes
          : settings.enforceRoutes,
      includeAllNetworks:
          settings.includeAllNetworks == _saved.includeAllNetworks
          ? saved.includeAllNetworks
          : settings.includeAllNetworks,
      hideVPNIcon: settings.hideVPNIcon == _saved.hideVPNIcon
          ? saved.hideVPNIcon
          : settings.hideVPNIcon,
      includedRoutes: listEquals(settings.includedRoutes, _saved.includedRoutes)
          ? saved.includedRoutes
          : settings.includedRoutes,
      excludedRoutes: listEquals(settings.excludedRoutes, _saved.excludedRoutes)
          ? saved.excludedRoutes
          : settings.excludedRoutes,
    );
  }
}

class PerAppRoutingEditor extends StatefulWidget {
  const PerAppRoutingEditor({
    super.key,
    required this.settings,
    required this.windows,
    required this.onSave,
    this.linux = false,
    this.enabled = true,
    this.advancedRoutes,
    this.draft,
    this.onCancel,
    this.servers = const [],
    this.checkRules,
    this.readConnections,
  });

  final TunnelSettings settings;
  final bool windows, linux, enabled;

  /// The servers an app can be sent through, as (ID, name).
  final List<(String, String)> servers;
  final Future<void> Function(TunnelSettings) onSave;
  final Widget? advancedRoutes;
  final PerAppRoutingDraft? draft;
  final VoidCallback? onCancel;

  /// Counts running programs per rule and explains rules that match nothing.
  final Future<ProcessRuleChecks> Function(List<String>)? checkRules;

  /// The running core's recent connections, for the connections view.
  final Future<RecentConnections> Function({int epoch, int after})?
  readConnections;

  @override
  State<PerAppRoutingEditor> createState() => _PerAppRoutingEditorState();
}

class _PerAppRoutingEditorState extends State<PerAppRoutingEditor> {
  late final draft = widget.draft ?? PerAppRoutingDraft(widget.settings);
  String get mode => draft.settings.perAppMode;
  set mode(String value) =>
      draft.settings = draft.settings.copyWith(perAppMode: value);
  List<String> get selections => draft.settings.perAppProcesses;
  set selections(List<String> value) =>
      draft.settings = draft.settings.copyWith(perAppProcesses: value);
  Map<String, String> get targets => draft.settings.perAppTargets;
  set targets(Map<String, String> value) =>
      draft.settings = draft.settings.copyWith(perAppTargets: value);
  late final search = TextEditingController(text: draft.search);
  late final input = TextEditingController(text: draft.input);
  List<_RoutingApp> apps = [];
  _AppView get view => draft.view;
  set view(_AppView value) => draft.view = value;
  String? notice;
  bool loading = true, working = false, appListFailed = false;
  ProcessRuleChecks? checks;
  List<String>? _checkedRules;
  bool _checking = false;
  // The connections view's list by key, in the order of their last change.
  final _connections = <int, RecentConnection>{};
  final connectionSearch = TextEditingController();
  int _connectionsEpoch = 0, _connectionsSeq = 0;
  bool _connectionsRead = false, _readingConnections = false;
  Timer? _connectionsTimer;
  // The open preset and the rules chosen from it.
  String? _preset;
  Set<String>? _presetChosen;
  bool get toolsExpanded => draft.toolsExpanded;
  set toolsExpanded(bool value) => draft.toolsExpanded = value;

  String get platform => widget.linux
      ? 'linux'
      : widget.windows
      ? 'windows'
      : 'macos';
  String get platformName => PerAppProfile.platformLabel(platform);
  bool get enabled => widget.enabled && !working;
  String identity(String process) =>
      widget.windows ? process.toLowerCase() : process;
  PerAppProfile get profile => PerAppProfile(platform, mode, selections, {
    for (final MapEntry(:key, :value) in targets.entries)
      if (selections.contains(key)) key: value,
  });

  @override
  void initState() {
    super.initState();
    search.addListener(() => draft.search = search.text);
    input.addListener(() => draft.input = input.text);
    _loadApps();
    if (view == _AppView.connections) _watchConnections();
  }

  @override
  void didUpdateWidget(covariant PerAppRoutingEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.draft == null &&
        (oldWidget.settings.perAppMode != widget.settings.perAppMode ||
            oldWidget.settings.perAppProcesses.join('\n') !=
                widget.settings.perAppProcesses.join('\n'))) {
      draft.reset(widget.settings);
    }
  }

  @override
  void dispose() {
    _connectionsTimer?.cancel();
    search.dispose();
    input.dispose();
    connectionSearch.dispose();
    super.dispose();
  }

  List<String> _rules(String text) {
    final seen = <String>{};
    return text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && seen.add(identity(s)))
        .toList();
  }

  // Unidentified traffic leads the list; apps follow by name.
  static int _byName(_RoutingApp a, _RoutingApp b) =>
      a.process == unknownOwnerRule || b.process == unknownOwnerRule
      ? (b.process == unknownOwnerRule ? 1 : 0) -
            (a.process == unknownOwnerRule ? 1 : 0)
      : a.name.toLowerCase().compareTo(b.name.toLowerCase());

  // A "children:" rule is its program's app, with that app's name and icon.
  _RoutingApp _app(String process) {
    final inner = innerRule(process);
    final hosted = apps
        .where((app) => identity(app.process) == identity(inner))
        .firstOrNull;
    if (hosted == null) return _RoutingApp(_name(process), process);
    if (inner == process) return hosted;
    final suggested = hosted.suggested;
    return _RoutingApp(
      hosted.name,
      process,
      hosted.icon,
      suggested == null ? null : 'children:$suggested',
    );
  }

  String _name(String process) {
    if (process == unknownOwnerRule) return l10n.perAppUnknownOwner;
    if (process != innerRule(process)) return _name(innerRule(process));
    for (final kind in ['flatpak:', 'service:']) {
      if (process.startsWith(kind)) return process.substring(kind.length);
    }
    if (process.startsWith('appimage:')) {
      // An image, or a folder of images, is named after its file.
      final parts = process
          .substring(9)
          .split('/')
          .where((part) => part.isNotEmpty)
          .toList();
      final file = parts.lastOrNull ?? process;
      return file.toLowerCase().endsWith('.appimage') && file.length > 9
          ? file.substring(0, file.length - 9)
          : file;
    }
    final parts = process
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    // A folder of versions, such as Claude Code's .../claude/versions/, is named after its owner.
    if (parts.length > 1 && parts.last == 'versions') parts.removeLast();
    final name = parts.lastOrNull ?? process;
    return name.endsWith('.app') ? name.substring(0, name.length - 4) : name;
  }

  /// What kind of app a rule names, when its path does not.
  String? _kind(String rule) => _innerKind(innerRule(rule));

  String? _innerKind(String process) => process.startsWith('flatpak:')
      ? 'Flatpak'
      : process.startsWith('appimage:')
      ? 'AppImage'
      : process.startsWith('service:')
      ? l10n.perAppKindService
      : null;

  String _ruleKind(String rule) => rule == innerRule(rule)
      ? _innerRuleKind(rule)
      : '${_innerRuleKind(innerRule(rule))} · ${l10n.perAppWithChildren}';

  String _innerRuleKind(String process) => process.startsWith('flatpak:')
      ? l10n.perAppFlatpakRule
      : process.startsWith('appimage:')
      ? l10n.perAppAppImageRule
      : process.startsWith('service:')
      ? l10n.perAppServiceRule
      : process.endsWith('.app/')
      ? l10n.appBundleIncludesHelpers
      : l10n.executableRule;

  Future<List<_RoutingApp>> _nativeApps(
    String method, {
    List<String>? processes,
  }) async {
    final raw = await DesktopIntegration.channel.invokeListMethod<Object?>(
      method,
      method == 'routingApplications'
          // Hosts know programs: a "children:" rule is asked as its program's.
          ? {
              'processes':
                  processes ?? selections.map(innerRule).toSet().toList(),
            }
          : null,
    );
    final result = <_RoutingApp>[];
    for (final item in raw ?? []) {
      if (item is! Map || item['process'] is! String) continue;
      final process = item['process'] as String;
      if (process.isEmpty) continue;
      final bytes = item['iconPng'];
      final suggested = item['suggested'];
      result.add(
        _RoutingApp(
          item['name'] is String && (item['name'] as String).isNotEmpty
              ? item['name'] as String
              : _name(process),
          process,
          bytes is Uint8List && bytes.isNotEmpty && bytes.length <= 65536
              ? bytes
              : null,
          suggested is String && suggested.isNotEmpty && suggested != process
              ? suggested
              : null,
        ),
      );
    }
    return result;
  }

  Future<void> _loadApps() async {
    setState(() {
      loading = true;
      notice = null;
      appListFailed = false;
      _checkedRules = null; // a refresh counts the running programs again
    });
    final unknown = _RoutingApp(l10n.perAppUnknownOwner, unknownOwnerRule);
    try {
      // Hosts list saved rules too, "-1" among them.
      final values = (await _nativeApps(
        'routingApplications',
      )).where((app) => app.process != unknownOwnerRule).toList();
      values.sort(_byName);
      if (mounted) setState(() => apps = [unknown, ...values]);
    } on Object {
      if (mounted) {
        setState(() {
          apps = [unknown];
          appListFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // Checks follow the list after each change; one runs at a time.
  void _ensureChecks() {
    if (widget.checkRules == null ||
        _checking ||
        listEquals(_checkedRules, selections))
      return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _runChecks());
  }

  Future<void> _runChecks() async {
    final check = widget.checkRules;
    final rules = List.of(selections);
    if (check == null || _checking || !mounted) return;
    if (listEquals(rules, _checkedRules)) return;
    _checking = true;
    _checkedRules = rules;
    try {
      final asked = rules.where((rule) => rule != unknownOwnerRule).toList();
      final result = asked.isEmpty
          ? const ProcessRuleChecks({})
          : await check(asked);
      if (mounted && listEquals(rules, _checkedRules)) {
        setState(() => checks = result);
      }
    } on Object {
      if (mounted) setState(() => checks = null);
    } finally {
      _checking = false;
      if (mounted) _ensureChecks();
    }
  }

  /// Replaces a rule in place; its target moves with it.
  void _replaceRule(String old, String rule) {
    final index = selections.indexWhere(
      (value) => identity(value) == identity(old),
    );
    if (index < 0) return;
    final present = selections.any(
      (value) => identity(value) == identity(rule),
    );
    setState(() {
      final next = List.of(selections);
      if (present) {
        next.removeAt(index);
      } else {
        next[index] = rule;
      }
      final target = targets[old];
      targets = {
        for (final MapEntry(:key, :value) in targets.entries)
          if (key != old) key: value,
        if (target != null && !targets.containsKey(rule)) rule: target,
      };
      selections = next;
    });
  }

  String _warningText(String code) => switch (code) {
    'missing' => l10n.perAppWarningMissing,
    'folder' => l10n.perAppWarningFolder,
    'notFolder' => l10n.perAppWarningNotFolder,
    'script' => l10n.perAppWarningScript,
    'symlink' => l10n.perAppWarningSymlink,
    'case' => l10n.perAppWarningCase,
    'launcher' => l10n.perAppWarningLauncher,
    'bundleName' => l10n.perAppWarningBundleName,
    'versioned' => l10n.perAppWarningVersioned,
    _ => l10n.perAppWarningUnknown,
  };

  Widget _ruleStatus(_RoutingApp app) {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    if (app.process == unknownOwnerRule) {
      return Text(l10n.perAppUnknownOwnerHelp, style: muted);
    }
    final check = checks?.rules[app.process];
    final running = checks?.listed == true && check != null
        ? check.running > 0
              ? l10n.perAppRunningNow(check.running)
              : l10n.perAppNotRunning
        : null;
    final warnings = <(String, String?)>[
      if (app.suggested != null) ('versioned', app.suggested),
      ...?check?.warnings,
    ];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final warningColor = dark
        ? const Color(0xFFF5D08A)
        : const Color(0xFF6B4300);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text([_ruleKind(app.process), ?running].join(' · ')),
        for (final (code, suggestion) in warnings)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    CupertinoIcons.exclamationmark_triangle,
                    size: 14,
                    color: warningColor,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _warningText(code),
                        key: Key('per-app-warning:${app.process}:$code'),
                        style: TextStyle(color: warningColor),
                      ),
                      if (suggestion != null)
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              l10n.perAppSuggestedRule(suggestion),
                              style: muted,
                            ),
                            TextButton(
                              key: Key('per-app-use:${app.process}:$code'),
                              onPressed: enabled
                                  ? () => _replaceRule(app.process, suggestion)
                                  : null,
                              child: Text(l10n.perAppUseSuggested),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _operation(Future<void> Function() action) async {
    setState(() {
      working = true;
      notice = null;
    });
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => notice = error.message);
    } on PlatformException catch (error) {
      if (mounted)
        setState(
          () => notice = error.code == 'launcher_application'
              ? l10n.perAppLauncherRule
              : l10n.perAppOperationFailed,
        );
    } on Object {
      if (mounted) setState(() => notice = l10n.perAppOperationFailed);
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void _show(_AppView next) {
    setState(() {
      view = next;
      notice = null;
    });
    if (next == _AppView.connections) {
      _watchConnections();
    } else {
      _connectionsTimer?.cancel();
      _connectionsTimer = null;
    }
  }

  // The list follows the core once a second while it is shown.
  void _watchConnections() {
    _connectionsTimer?.cancel();
    _readConnections();
    _connectionsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _readConnections(),
    );
  }

  Future<void> _readConnections() async {
    final read = widget.readConnections;
    if (read == null || _readingConnections) return;
    _readingConnections = true;
    try {
      final result = await read(
        epoch: _connectionsEpoch,
        after: _connectionsSeq,
      );
      if (!mounted) return;
      setState(() {
        if (result.epoch != _connectionsEpoch) _connections.clear();
        _connectionsEpoch = result.epoch;
        _connectionsSeq = result.seq;
        for (final connection in result.connections) {
          _connections.remove(connection.key);
          _connections[connection.key] = connection;
        }
        while (_connections.length > 500) {
          _connections.remove(_connections.keys.first);
        }
        _connectionsRead = true;
      });
    } on Object {
      // No running tunnel answers on macOS and Android.
      if (mounted) {
        setState(() {
          _connections.clear();
          _connectionsEpoch = _connectionsSeq = 0;
          _connectionsRead = true;
        });
      }
    } finally {
      _readingConnections = false;
    }
  }

  String _connectionApp(RecentConnection connection) =>
      switch (connection.owner) {
        // A sandbox, a mount or a shared service host names its app by rule.
        'found' when connection.app.isNotEmpty => _app(connection.app).name,
        // A program in a folder of versions, such as Claude Code's
        // .../claude/versions/2.1.300, is named after the folder's owner.
        'found' when connection.path.isNotEmpty => _name(
          RegExp(r'[\\/]versions[\\/][^\\/]+$').hasMatch(connection.path)
              ? connection.path.substring(
                  0,
                  connection.path.lastIndexOf(RegExp(r'[\\/]')) + 1,
                )
              : connection.path,
        ),
        'found' => connection.name,
        'unknown' => l10n.perAppUnknownOwner,
        _ => l10n.perAppConnectionNoApp,
      };

  // The rule a connection's program gets: the app's rule when its path does
  // not name it, the host's update-proof rule, as for a picked app, else the
  // program's bundle on macOS, else its path.
  Future<String> _connectionRule(RecentConnection connection) async {
    if (connection.app.isNotEmpty) return connection.app;
    final path = connection.path;
    final rule = widget.windows ? path.replaceAll('/', r'\') : path;
    try {
      final hosted = await _nativeApps(
        'routingApplications',
        processes: [...selections, rule],
      );
      final suggested = hosted
          .where((app) => identity(app.process) == identity(rule))
          .firstOrNull
          ?.suggested;
      if (suggested != null) return suggested;
    } on Object {
      // The path still names the program.
    }
    if (platform == 'macos') {
      final bundle = rule.indexOf('.app/');
      if (bundle > 0) return rule.substring(0, bundle + 5);
    }
    return rule;
  }

  Future<void> _addConnectionApp(RecentConnection connection) =>
      _operation(() async {
        final rule = await _connectionRule(connection);
        if (!mounted) return;
        setState(() {
          selections = _rules([...selections, rule].join('\n'));
          if (!apps.any((app) => identity(app.process) == identity(rule))) {
            apps = [...apps, _RoutingApp(_name(rule), rule)]..sort(_byName);
          }
        });
        if (mounted) {
          setState(() => notice = l10n.perAppConnectionAdded(_name(rule)));
        }
      });

  // Whether a listed rule already names the program: its app's rule, its
  // path, a folder holding it, or its file name. The core's own matcher
  // decides routing.
  bool _covers(String listed, RecentConnection connection) {
    final rule = innerRule(listed);
    final app = connection.app;
    if (app.isNotEmpty) {
      if (identity(rule) == identity(app)) return true;
      // A folder of AppImages holds the image.
      if (app.startsWith('appimage:') &&
          rule.startsWith('appimage:') &&
          rule.endsWith('/') &&
          app.startsWith(rule)) {
        return true;
      }
    }
    return _coversPath(rule, connection.path);
  }

  bool _coversPath(String rule, String path) {
    if (path.isEmpty) return false;
    final windows = widget.windows;
    String normal(String value) =>
        identity(windows ? value.replaceAll('/', r'\') : value);
    final program = normal(path), named = normal(rule);
    if (named == program) return true;
    if (named.endsWith('/') || named.endsWith(r'\')) {
      return program.startsWith(named);
    }
    if (named.contains('/') || named.contains(r'\')) return false;
    final file = program.substring(
      program.lastIndexOf(windows ? r'\' : '/') + 1,
    );
    return file == named || windows && file == '$named.exe';
  }

  // The listed app whose program started a connection's program.
  String _startedBy(String via) =>
      selections
          .map(_app)
          .where((app) => _coversPath(innerRule(app.process), via))
          .firstOrNull
          ?.name ??
      _name(via);

  String _connectionRoute(RecentConnection connection) =>
      switch (connection.kind) {
        'direct' => l10n.perAppConnectionDirect,
        'block' => l10n.perAppConnectionBlocked,
        'dns' => l10n.perAppConnectionDns,
        'routing' => l10n.perAppConnectionRouting,
        _ => l10n.perAppConnectionProxy,
      };

  Widget _connectionRow(RecentConnection connection) {
    final subtle = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final time = connection.time;
    String two(int value) => value.toString().padLeft(2, '0');
    final canAdd =
        connection.owner == 'found' &&
        (connection.path.isNotEmpty || connection.app.isNotEmpty) &&
        !connection.listed &&
        !selections.any((rule) => _covers(rule, connection));
    final address = connection.host.contains(':')
        ? '[${connection.host}]:${connection.port}'
        : '${connection.host}:${connection.port}';
    return Column(
      children: [
        ListTile(
          key: Key('per-app-connection-${connection.key}'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(switch (connection.owner) {
            'found' => CupertinoIcons.app,
            'unknown' => CupertinoIcons.question_square,
            _ => CupertinoIcons.globe,
          }, size: 22),
          title: Text(_connectionApp(connection)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$address · ${connection.network.toUpperCase()}',
                style: subtle,
              ),
              Text(switch (connection.before) {
                'reset' => l10n.perAppConnectionOpenedReset,
                'kept' => l10n.perAppConnectionOpenedKept,
                _ => [
                  _connectionRoute(connection),
                  if (connection.listed) l10n.perAppConnectionListed,
                  if (connection.unlisted) l10n.perAppConnectionNotListed,
                ].join(' · '),
              }, style: subtle),
              if (connection.via.isNotEmpty)
                Text(
                  l10n.perAppConnectionStartedBy(_startedBy(connection.via)),
                  style: subtle,
                ),
              if (connection.path.isNotEmpty)
                Text(
                  connection.path,
                  style: subtle.copyWith(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
          trailing: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(
                '${two(time.hour)}:${two(time.minute)}:${two(time.second)}',
                style: subtle,
              ),
              if (canAdd)
                TextButton(
                  key: Key('per-app-add-connection-${connection.key}'),
                  onPressed: enabled
                      ? () => _addConnectionApp(connection)
                      : null,
                  child: Text(l10n.perAppConnectionAdd),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _connectionsView() {
    final query = connectionSearch.text.trim().toLowerCase();
    final visible =
        _connections.values
            .where(
              (connection) =>
                  '${_connectionApp(connection)} ${connection.path} ${connection.host}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList()
          ..sort((a, b) => b.key.compareTo(a.key));
    final subtle = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    // Listed apps whose connections from before connecting skip per-app
    // routing: on macOS all of them, elsewhere those the system kept.
    final restart = {
      for (final connection in _connections.values)
        if (connection.before == 'kept')
          selections
                  .where((rule) => _covers(rule, connection))
                  .map((rule) => _app(rule).name)
                  .firstOrNull ??
              _connectionApp(connection),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(l10n.perAppConnections),
        const SizedBox(height: 8),
        Text(l10n.perAppConnectionsHelp, style: subtle),
        if (restart.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            l10n.perAppConnectionsRestart(restart.join(', ')),
            key: const Key('per-app-connections-restart'),
          ),
        ],
        if (widget.settings.perAppMode == 'off') ...[
          const SizedBox(height: 8),
          Text(
            l10n.perAppConnectionsOff,
            key: const Key('per-app-connections-off'),
            style: subtle,
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: const Key('per-app-connections-search'),
          controller: connectionSearch,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: l10n.perAppConnectionsSearch,
            prefixIcon: const Icon(CupertinoIcons.search),
          ),
        ),
        const SizedBox(height: 8),
        if (!_connectionsRead)
          const LinearProgressIndicator()
        else if (_connectionsEpoch == 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(l10n.perAppConnectionsDisconnected, style: subtle),
          )
        else if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(l10n.perAppConnectionsEmpty, style: subtle),
          )
        else
          SizedBox(
            height: 420,
            child: ListView(
              children: [
                for (final connection in visible.take(200))
                  _connectionRow(connection),
              ],
            ),
          ),
        _footer([
          FilledButton(
            onPressed: () => _show(_AppView.selected),
            child: Text(l10n.done),
          ),
        ]),
      ],
    );
  }

  Future<void> _chooseFile() => _operation(() async {
    final values = await _nativeApps('pickRoutingApplications');
    if (!mounted) return;
    setState(() {
      selections = _rules(
        [...selections, ...values.map((app) => app.process)].join('\n'),
      );
      final known = apps.map((app) => identity(app.process)).toSet();
      apps.addAll(values.where((app) => known.add(identity(app.process))));
      apps.sort(_byName);
    });
  });

  Future<void> _paste() => _operation(() async {
    final data = await Clipboard.getData('text/plain');
    if (!mounted) return;
    setState(() {
      input.text = data?.text ?? '';
      view = _AppView.paste;
    });
  });

  void _updateRules() {
    final values = _rules(input.text);
    final error = PerAppProfile(platform, mode, values).validationError;
    if (error != null) {
      setState(() => notice = error);
      return;
    }
    setState(() {
      selections = values;
      view = _AppView.picker;
      notice = null;
    });
  }

  // An app without a target of its own follows the mode.
  String get _modeTarget => mode == 'bypass' ? 'direct' : 'routing';
  static const _askProxy = 'ask-proxy';

  String _targetLabel(String target) => switch (target) {
    'direct' => l10n.targetDirect,
    'routing' => l10n.targetFollowRouting,
    'block' => l10n.targetBlock,
    final value when value.startsWith('proxy:') => l10n.targetLocalProxy(
      Uri.tryParse(value.substring(6))?.authority ?? value.substring(6),
    ),
    final value when value.startsWith('node:') =>
      widget.servers
              .where((server) => server.$1 == value.substring(5))
              .map((server) => l10n.targetServer(server.$2))
              .firstOrNull ??
          l10n.targetMissingServer,
    _ => target,
  };

  Widget _targetSelect(String process) {
    final current = targets[process] ?? _modeTarget;
    final values = [
      'direct',
      'routing',
      'block',
      for (final server in widget.servers) 'node:${server.$1}',
      if (current.startsWith('proxy:')) current,
      // A deleted server stays visible until another target replaces it.
      if (current.startsWith('node:') &&
          !widget.servers.any((server) => 'node:${server.$1}' == current))
        current,
    ];
    return SizedBox(
      width: 240,
      child: ElarniSelect<String>(
        key: Key('per-app-target:$process'),
        value: current,
        isExpanded: true,
        items: [
          for (final value in values)
            DropdownMenuItem(value: value, child: Text(_targetLabel(value))),
          DropdownMenuItem(
            value: _askProxy,
            child: Text(l10n.localProxyEllipsis),
          ),
        ],
        onChanged: enabled && mode != 'off'
            ? (value) async {
                final target = value == _askProxy
                    ? await _proxyTarget(targets[process])
                    : value;
                if (target == null || !mounted) return;
                setState(
                  () => targets = {
                    for (final MapEntry(:key, :value) in targets.entries)
                      if (key != process) key: value,
                    if (target != _modeTarget) process: target,
                  },
                );
              }
            : null,
      ),
    );
  }

  Future<String?> _proxyTarget(String? current) => showDialog<String>(
    context: context,
    builder: (context) => _ProxyDialog(
      initial: current != null && current.startsWith('proxy:')
          ? current.substring(6)
          : 'socks5://127.0.0.1:1080',
      settings: draft.settings,
    ),
  );

  Future<void> _save() => _operation(() async {
    final error = profile.validationError;
    if (error != null) throw FormatException(error);
    await widget.onSave(draft.applyTo(widget.settings));
  });

  Widget _icon(_RoutingApp app) {
    // A plain rounded square read as a checkbox beside each rule.
    Widget fallback() => Icon(
      app.process == unknownOwnerRule
          ? CupertinoIcons.question_square
          : CupertinoIcons.macwindow,
      size: 28,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: 36,
        height: 36,
        child: app.icon == null
            ? fallback()
            : Image.memory(
                app.icon!,
                width: 36,
                height: 36,
                cacheWidth: 72,
                cacheHeight: 72,
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }

  Widget _heading(String title, {bool back = false}) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      IconButton(
        tooltip: back ? l10n.backToApps : l10n.closeAppChooser,
        onPressed: enabled
            ? () => _show(back ? _AppView.picker : _AppView.selected)
            : null,
        icon: Icon(
          back ? CupertinoIcons.arrow_left : CupertinoIcons.xmark,
          size: 18,
        ),
      ),
    ],
  );

  Widget _appListNotice() {
    if (!appListFailed) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? const Color(0xFFF5D08A) : const Color(0xFF6B4300);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF3A2E14) : const Color(0xFFFBF2E4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_triangle,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  l10n.appListUnavailable,
                  style: TextStyle(color: color),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notice() => notice == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Semantics(
            liveRegion: true,
            child: Text(notice!, key: const Key('per-app-notice')),
          ),
        );

  Widget _footer(List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      children: [
        const Divider(height: 1),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(spacing: 8, runSpacing: 8, children: children),
        ),
      ],
    ),
  );

  void _details(_RoutingApp app) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(app.name),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(platformName, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 12),
              SelectableText(app.process),
              const SizedBox(height: 12),
              Text(
                widget.linux
                    ? l10n.linuxRulesCaseSensitive
                    : widget.windows
                    ? l10n.windowsRulesCaseInsensitive
                    : app.process.endsWith('.app/')
                    ? l10n.macBundleRuleHelp
                    : l10n.macRulesCaseSensitive,
              ),
              if (app.process != unknownOwnerRule) ...[
                const SizedBox(height: 12),
                StatefulBuilder(
                  builder: (context, update) {
                    final current = selections.firstWhere(
                      (rule) =>
                          identity(innerRule(rule)) ==
                          identity(innerRule(app.process)),
                      orElse: () => app.process,
                    );
                    final included = current != innerRule(current);
                    return SwitchListTile(
                      key: const Key('per-app-include-children'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.perAppIncludeChildren),
                      subtitle: Text(l10n.perAppIncludeChildrenHelp),
                      value: included,
                      onChanged: enabled
                          ? (value) {
                              final inner = innerRule(current);
                              _replaceRule(
                                current,
                                value ? 'children:$inner' : inner,
                              );
                              update(() {});
                            }
                          : null,
                    );
                  },
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.done),
          ),
        ],
      ),
    );
  }

  Widget _selected() {
    _ensureChecks();
    final selectedApps =
        [for (final process in selections) (process, _app(process))]..sort(
          (a, b) => a.$2.name.toLowerCase().compareTo(b.$2.name.toLowerCase()),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ElarniHelpLabel(
          l10n.perAppRouting,
          help: switch (mode) {
            'bypass' => l10n.perAppBypassHelp,
            'proxyOnly' => l10n.perAppOnlyHelp,
            _ => l10n.perAppOffHelp,
          },
        ),
        // The help label above names the control for screen readers too.
        Semantics(
          label: l10n.perAppRouting,
          child: ElarniSelect<String>(
            key: const Key('per-app-routing-mode'),
            value: mode,
            isExpanded: true,
            items: [
              DropdownMenuItem(value: 'off', child: Text(l10n.off)),
              DropdownMenuItem(
                value: 'bypass',
                child: Text(l10n.perAppBypassSelected),
              ),
              DropdownMenuItem(
                value: 'proxyOnly',
                child: Text(l10n.perAppOnlySelected),
              ),
            ],
            onChanged: enabled
                ? (value) => setState(() => mode = value!)
                : null,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.selectedApps,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.readConnections != null) ...[
              TextButton(
                key: const Key('per-app-connections'),
                onPressed: enabled ? () => _show(_AppView.connections) : null,
                child: Text(l10n.perAppConnections),
              ),
              const SizedBox(width: 8),
            ],
            OutlinedButton(
              onPressed: enabled
                  ? () {
                      search.clear();
                      _show(_AppView.picker);
                    }
                  : null,
              child: Text(l10n.addApps),
            ),
          ],
        ),
        _appListNotice(),
        const SizedBox(height: 12),
        if (selectedApps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              l10n.noAppsSelected,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final (process, app) in selectedApps)
          Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                leading: _icon(app),
                title: Text(app.name),
                subtitle: _ruleStatus(app),
                trailing: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _targetSelect(process),
                    TextButton(
                      onPressed: enabled ? () => _details(app) : null,
                      child: Text(l10n.details),
                    ),
                    IconButton(
                      tooltip: l10n.removeApp(app.name),
                      icon: const Icon(CupertinoIcons.xmark, size: 16),
                      onPressed: enabled
                          ? () => setState(
                              () => selections.removeWhere(
                                (value) =>
                                    identity(value) == identity(app.process),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
          ),
        if (selectedApps.isNotEmpty)
          ListTile(
            key: const Key('per-app-other-apps'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 4,
            ),
            title: Text(l10n.otherApps),
            trailing: Text(
              mode == 'proxyOnly'
                  ? l10n.targetDirect
                  : l10n.targetFollowRouting,
            ),
          ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              CupertinoIcons.info,
              size: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.perAppTargetsHelp,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        if (widget.advancedRoutes != null) ...[
          const SizedBox(height: 20),
          widget.advancedRoutes!,
        ],
        _footer([
          TextButton(
            onPressed: enabled
                ? () => setState(() {
                    draft.reset(widget.settings);
                    notice = null;
                    widget.onCancel?.call();
                  })
                : null,
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: enabled ? _save : null,
            child: Text(l10n.saveChanges),
          ),
        ]),
      ],
    );
  }

  Widget _picker() {
    final query = search.text.trim().toLowerCase();
    final catalog = [...apps];
    final known = catalog.map((app) => identity(app.process)).toSet();
    catalog.addAll(selections.where((p) => known.add(identity(p))).map(_app));
    final visible = catalog
        .where(
          (app) => '${app.name} ${app.process}'.toLowerCase().contains(query),
        )
        .toList();
    final selected = selections.map(identity).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(l10n.addApps),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: search,
                enabled: enabled,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l10n.searchApps,
                  prefixIcon: Icon(CupertinoIcons.search),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: l10n.refreshAppList,
              onPressed: enabled && !loading ? _loadApps : null,
              icon: const Icon(CupertinoIcons.arrow_clockwise),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          l10n.installedAndRunningApps,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        if (loading) const LinearProgressIndicator(),
        SizedBox(
          height: 300,
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    loading
                        ? l10n.loadingApps
                        : query.isEmpty
                        ? l10n.noAppsFound
                        : l10n.noMatchingApps,
                  ),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final app = visible[index];
                    final kind = _kind(app.process);
                    return CheckboxListTile(
                      secondary: _icon(app),
                      title: Text(app.name),
                      subtitle: kind == null ? null : Text(kind),
                      controlAffinity: ListTileControlAffinity.trailing,
                      value: selected.contains(identity(app.process)),
                      onChanged: enabled
                          ? (checked) => setState(() {
                              selections.removeWhere(
                                (p) => identity(p) == identity(app.process),
                              );
                              if (checked == true) selections.add(app.process);
                            })
                          : null,
                    );
                  },
                ),
        ),
        const SizedBox(height: 16),
        _presets(),
        ExpansionTile(
          key: const Key('per-app-tools'),
          title: Text(l10n.profileAndExecutableTools),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: toolsExpanded,
          onExpansionChanged: (value) => toolsExpanded = value,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    onPressed: enabled
                        ? () {
                            input.text = selections.join('\n');
                            _show(_AppView.rules);
                          }
                        : null,
                    child: Text(l10n.editExecutableRules),
                  ),
                  TextButton(
                    onPressed: enabled ? _paste : null,
                    child: Text(l10n.pasteRoutingProfile),
                  ),
                  TextButton(
                    onPressed: enabled
                        ? () => _operation(() async {
                            await Clipboard.setData(
                              ClipboardData(text: profile.encode()),
                            );
                            if (mounted)
                              setState(
                                () => notice = l10n.perAppProfileCopied(
                                  platformName,
                                ),
                              );
                          })
                        : null,
                    child: Text(l10n.copyRoutingProfile),
                  ),
                  TextButton(
                    onPressed: enabled ? () => _show(_AppView.help) : null,
                    child: Text(l10n.howAppRoutingWorks),
                  ),
                ],
              ),
            ),
          ],
        ),
        _footer([
          TextButton.icon(
            onPressed: enabled ? _chooseFile : null,
            icon: const Icon(CupertinoIcons.folder, size: 18),
            label: Text(l10n.chooseAppFile),
          ),
          FilledButton(
            onPressed: enabled ? () => _show(_AppView.selected) : null,
            child: Text(l10n.done),
          ),
        ]),
      ],
    );
  }

  String _presetName(String id) => switch (id) {
    'steam' => l10n.perAppPresetSteam,
    'browsers' => l10n.perAppPresetBrowsers,
    _ => appPresets.firstWhere((preset) => preset.id == id).apps.first.name,
  };

  // A preset offers the apps of its group that the app list has, with the
  // list's rules; an app the list lacks is shown as not found.
  Widget _presets() {
    final listed = selections.map((rule) => identity(innerRule(rule))).toSet();
    final hosted = [
      for (final app in apps)
        if (app.process != unknownOwnerRule)
          (name: app.name, process: app.process),
    ];
    final open = appPresets.where((preset) => preset.id == _preset).firstOrNull;
    final found = open?.find(hosted) ?? const [];
    final candidates = {
      for (final entry in found)
        for (final rule in entry.rules)
          if (!listed.contains(identity(innerRule(rule)))) rule,
    };
    final chosen = (_presetChosen ?? candidates).intersection(candidates);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.perAppPresets, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final preset in appPresets)
              FilterChip(
                key: Key('per-app-preset:${preset.id}'),
                label: Text(_presetName(preset.id)),
                selected: preset.id == _preset,
                onSelected: enabled && !loading
                    ? (on) => setState(() {
                        _preset = on ? preset.id : null;
                        _presetChosen = null;
                      })
                    : null,
              ),
          ],
        ),
        if (open != null) ...[
          const SizedBox(height: 8),
          for (final (:app, :rules) in found)
            if (rules.isEmpty)
              ListTile(
                key: Key('per-app-preset-missing:${app.name}'),
                enabled: false,
                title: Text(app.name),
                trailing: Text(l10n.perAppPresetNotFound),
              )
            else
              for (final rule in rules)
                CheckboxListTile(
                  key: Key('per-app-preset-app:$rule'),
                  secondary: _icon(_app(rule)),
                  title: Text(_app(rule).name),
                  subtitle: listed.contains(identity(innerRule(rule)))
                      ? Text(l10n.perAppPresetAdded)
                      : rule != innerRule(rule)
                      ? Text(l10n.perAppPresetWithChildren)
                      : null,
                  controlAffinity: ListTileControlAffinity.trailing,
                  value: !candidates.contains(rule) || chosen.contains(rule),
                  onChanged: enabled && candidates.contains(rule)
                      ? (checked) => setState(
                          () => _presetChosen = checked == true
                              ? {...chosen, rule}
                              : ({...chosen}..remove(rule)),
                        )
                      : null,
                ),
          const SizedBox(height: 8),
          Text(
            l10n.perAppPresetsHelp,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('per-app-preset-add'),
              onPressed: enabled && chosen.isNotEmpty
                  ? () => setState(() {
                      selections = [
                        ...selections,
                        ...candidates.where(chosen.contains),
                      ];
                      _preset = null;
                      _presetChosen = null;
                    })
                  : null,
              child: Text(l10n.perAppAddPresetApps(chosen.length)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _tool() {
    final rules = view == _AppView.rules;
    final help = view == _AppView.help;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          help
              ? l10n.howAppRoutingWorks
              : rules
              ? l10n.editExecutableRules
              : l10n.pasteRoutingProfile,
          back: true,
        ),
        const SizedBox(height: 12),
        if (help) ...[
          Text(
            widget.linux
                ? l10n.linuxMatchingHelp
                : widget.windows
                ? l10n.windowsMatchingHelp
                : l10n.macMatchingHelp,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.appRoutingUses(
              widget.windows || widget.linux ? l10n.systemWideVpn : 'Xray TUN',
            ),
          ),
          const SizedBox(height: 16),
          Text(l10n.appRoutingNotFirewall),
          const SizedBox(height: 16),
          Text(l10n.routingProfileContents(platformName)),
        ] else ...[
          Text(
            rules
                ? l10n.executableRulesHelp
                : l10n.loadRoutingProfileHelp(platformName),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: input,
            enabled: enabled,
            minLines: 5,
            maxLines: 10,
            maxLength: rules ? 262400 : 524288,
            decoration: InputDecoration(
              labelText: rules
                  ? l10n.executableNamesOrPaths
                  : l10n.routingProfileJson,
              hintText: rules
                  ? widget.linux
                        ? '/usr/bin/example'
                        : widget.windows
                        ? r'C:\Apps\Example.exe'
                        : '/Applications/Example.app/'
                  : null,
            ),
          ),
        ],
        _footer([
          TextButton(
            onPressed: enabled ? () => _show(_AppView.picker) : null,
            child: Text(l10n.backToApps),
          ),
          if (!help)
            FilledButton(
              onPressed: enabled
                  ? rules
                        ? _updateRules
                        : () => _operation(() async {
                            final imported = PerAppProfile.decode(
                              input.text,
                              platform: platform,
                            );
                            setState(() {
                              mode = imported.mode;
                              selections = _rules(
                                imported.processes.join('\n'),
                              );
                              targets = Map.of(imported.targets);
                              view = _AppView.picker;
                              notice = l10n.perAppProfileLoaded(platformName);
                            });
                          })
                  : null,
              child: Text(rules ? l10n.updateDraft : l10n.loadProfile),
            ),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        switch (view) {
          _AppView.selected => _selected(),
          _AppView.picker => _picker(),
          _AppView.connections => _connectionsView(),
          _ => _tool(),
        },
        // The selected-apps view shows it next to Add apps.
        if (view != _AppView.selected) _appListNotice(),
        _notice(),
      ],
    ),
  );
}
