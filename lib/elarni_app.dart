import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tunnel_channel.dart';
import 'routing_editor.dart';
import 'desktop_integration.dart';
import 'per_app_routing.dart';
import 'update_check.dart' show isHttpsURL;
import 'logs_view.dart';
import 'elarni_widgets.dart';
import 'server_locations.dart';
import 'connection_support.dart';
import 'connection_recovery.dart';
import 'strings.dart';

part 'elarni_app_controller.dart';
part 'elarni_app_editors.dart';
part 'elarni_app_pages.dart';

bool _sameJson(Object? a, Object? b) {
  try {
    return jsonEncode(a) == jsonEncode(b);
  } on Object {
    return false;
  }
}

// Editors retain their controllers until the reverse transition has removed
// the dialog; Navigator's push future completes before that animation ends.
Future<T?> _showEditorDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) async {
  // Esc and outside clicks would silently discard the draft.
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: false,
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  return result;
}

// Cancel cannot hide a save that is still being applied.
class _EditorCancelButton extends StatelessWidget {
  const _EditorCancelButton({required this.saving, this.style});

  final ValueListenable<bool> saving;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: saving,
    builder: (context, value, _) => TextButton(
      style: style,
      onPressed: value ? null : () => Navigator.pop(context),
      child: Text(l10n.cancel),
    ),
  );
}

class _ConnectionRevealClipper extends CustomClipper<Rect> {
  const _ConnectionRevealClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) {
    final center = size.center(Offset.zero);
    return Rect.fromCircle(center: center, radius: center.distance * progress);
  }

  @override
  bool shouldReclip(_ConnectionRevealClipper oldClipper) =>
      oldClipper.progress != progress;
}

class ElarniApp extends StatefulWidget {
  const ElarniApp({
    super.key,
    this.tunnelControl,
    this.windows = false,
    this.linux = false,
    this.onDispose,
    this.navigatorKey,
  });

  final TunnelControl? tunnelControl;
  final bool windows, linux;
  bool get desktopCore => windows || linux;
  String get platformName => linux
      ? 'Linux'
      : windows
      ? 'Windows'
      : 'macOS';
  final Future<void> Function()? onDispose;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<ElarniApp> createState() => _ElarniAppState();
}

class _ElarniAppState extends State<ElarniApp> {
  final desktop = DesktopIntegration();
  late final TunnelControl control =
      widget.tunnelControl ?? NativeTunnelControl();
  @override
  void initState() {
    super.initState();
    desktop.addListener(_desktopChanged);
    unawaited(desktop.load());
  }

  void _desktopChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    desktop.dispose();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) => elarniTheme(
    brightness: brightness,
    accent: DesktopIntegration.accents[desktop.accent]!,
    windows: widget.windows,
    linux: widget.linux,
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: widget.navigatorKey,
      title: 'Elarni',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: desktop.language == 'system' ? null : Locale(desktop.language),
      localeListResolutionCallback: resolveAppLocale,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: desktop.theme,
      home: ElarniHome(
        tunnelControl: control,
        windows: widget.windows,
        linux: widget.linux,
        onDispose: widget.onDispose,
        desktop: desktop,
      ),
    );
  }
}

/// Words a [TunnelSettings.routeEnforcementError] code.
String routeEnforcementText(String code) => switch (code) {
  'includeAllNetworks' => l10n.routeEnforcementWithIncludeAll,
  'blockWithoutVPN' => l10n.routeEnforcementWithBlock,
  _ => l10n.routeEnforcementDefaultRoutes,
};

class ElarniHome extends StatefulWidget {
  const ElarniHome({
    required this.tunnelControl,
    required this.desktop,
    this.windows = false,
    this.linux = false,
    this.onDispose,
    super.key,
  });

  final TunnelControl tunnelControl;
  final DesktopIntegration desktop;
  final bool windows, linux;
  bool get desktopCore => windows || linux;
  String get platformName => linux
      ? 'Linux'
      : windows
      ? 'Windows'
      : 'macOS';
  final Future<void> Function()? onDispose;

  @override
  State<ElarniHome> createState() => _ElarniHomeState();
}

class _ElarniHomeState extends State<ElarniHome> {
  final _editorSaving = ValueNotifier<bool>(false);
  final TextEditingController _nodeSearch = TextEditingController();
  final TextEditingController _pingURL = TextEditingController(
    text: 'https://www.gstatic.com/generate_204',
  );
  final TextEditingController _pingExpectedStatus = TextEditingController(
    text: '204',
  );
  final TextEditingController _pingExpectedBody = TextEditingController();
  SubscriptionSnapshot _subscriptions = const SubscriptionSnapshot(
    subscriptions: <SubscriptionGroup>[],
  );
  RoutingSnapshot _routing = const RoutingSnapshot(
    profiles: <RoutingProfile>[],
    assignments: <String, String>{},
  );
  TunnelSettings _settings = const TunnelSettings();
  // Saving sends the whole object, so defaults shown before a load must not.
  bool _settingsLoaded = false;
  bool _importing = false;
  PerAppRoutingDraft? _perAppDraft;
  Map<String, Object?> _metrics = const <String, Object?>{};
  bool _metricsLoading = false;
  Map<String, Object?> _systemInfo = const <String, Object?>{};
  String? _systemError;
  bool _systemBusy = false;
  String? _routeTable;
  String? _routesError;
  bool _routesBusy = false;
  final Map<String, PingResult> _pingResults = <String, PingResult>{};
  final Set<String> _pingUnavailable = <String>{};
  final Set<String> _pingSkipped = <String>{};
  final Set<String> _pingPending = <String>{};
  // When each server was last tested, so a failed one is not retried by every group open.
  final Map<String, double> _pingTriedAt = <String, double>{};
  // Servers of groups opened during a test; tested when it ends.
  final Set<String> _pingQueued = <String>{};
  // Check exit replies, and the servers being checked.
  final Map<String, PingResult> _exitResults = <String, PingResult>{};
  final Set<String> _exitPending = <String>{}, _exitFailed = <String>{};
  // The subscription whose servers are being selected, and that selection.
  String? _selectingSubscription;
  final Set<String> _selectedServers = <String>{};

  /// The failure code of each subscription whose last refresh in this session failed.
  final Map<String, String> _failedRefreshes = <String, String>{};
  bool _pinging = false;
  int _pingRun = 0;
  String _pingProtocol = 'tcp';
  String _pingMethod = 'GET';
  String _pingMode = 'default';
  int _pingTimeout = 7;
  Timer? _monitorTimer;
  Timer? _localStateTimer;
  TunnelState _state = TunnelState.disconnected;
  TunnelState? _lastKnownState;
  bool _connectFailed = false;
  bool _stateAvailable = false;
  bool _statePolling = false;
  int _stateRevision = 0;
  int _healthRun = 0;
  String _health = 'unknown';
  String? _healthNodeId;
  DateTime? _healthAt;
  // Whether the connected server passes traffic: ok, noTraffic or null.
  String? _liveness;
  DateTime? _noTrafficAt;
  // The saved local proxy login, shown in Settings on request.
  Map<String, String> _inboundLogin = const {};
  bool _showInboundPassword = false, _loginNoticeHidden = false;
  Map<String, Object?> _automation = {};
  final List<ConnectionIssue> _recentIssues = [];
  String? _message;

  /// A button for the message it was made with; a later message hides it.
  ({String message, String label, VoidCallback onPressed})? _messageAction;
  bool _working = false;
  bool get _busy => _working;
  set _busy(bool value) {
    _working = value;
    if (value) {
      _stateRevision++;
      _healthRun++;
      _health = 'unknown';
      _healthAt = null;
      // User operations supersede background tests and their late replies.
      _pingRun++;
      _pingPending.clear();
    }
  }

  bool get _pingControlsDisabled => _busy || _pinging;
  bool get _profileEditsDisabled => _busy;
  String _search = '';
  final Map<String, String> _subscriptionSearches = {};
  // Loaded when a subscription's details open; the HTTP host is part of the ID.
  final Map<String, Future<String>> _deviceIDs = {};
  String _nodeFilter = 'all';
  String? _healthRevision;
  DesktopPage _page = DesktopPage.home;
  String? _expandedSubscription;
  final Set<String> _collapsedSubscriptions = {};
  final Map<String, bool> _expandedCountries = {};
  SettingsCategory _settingsCategory = SettingsCategory.general;
  // The Routing page's tab: 0 routing profiles, 1 per-app routing.
  int _routingTab = 0;
  bool get _canConnect =>
      !_busy &&
      _stateAvailable &&
      _subscriptions.selectedNodeId != null &&
      (_state == TunnelState.prepared ||
          _state == TunnelState.disconnected ||
          _state == TunnelState.failed);
  bool get _canDisconnect =>
      !(_busy &&
          !const {
            TunnelState.connecting,
            TunnelState.reconnecting,
            TunnelState.reasserting,
          }.contains(_state)) &&
      (!_stateAvailable || _state != TunnelState.disconnected);

  @override
  void initState() {
    super.initState();
    widget.desktop.onAction = (action) {
      if (action == 'settings' && mounted) {
        setState(() => _page = DesktopPage.settings);
      }
      if (action == 'connect' && _canConnect) unawaited(_connect());
      if (action == 'disconnect' && _canDisconnect) unawaited(_disconnect());
    };
    widget.tunnelControl.setImportListener((error) {
      if (!mounted) return;
      if (error != null)
        setState(() {
          _message = error;
        });
      _load();
    });
    _load(pingOnLoad: true);
    _localStateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && !_busy && timer.tick % 60 == 0) {
        unawaited(widget.desktop.remindExpiring(_subscriptions));
      }
      if (mounted &&
          !_busy &&
          // Unreadable cosmetic preferences must not stop connection status.
          (widget.desktop.hostAvailable ||
              widget.desktopCore && _state == TunnelState.connected))
        _refreshState(onlyWhenIdle: true);
      if (mounted && !_busy && timer.tick % 5 == 0) {
        unawaited(_refreshAutomation());
        unawaited(_refreshSubscriptions());
        if (!_settingsLoaded) unawaited(_refreshSettings());
        unawaited(widget.desktop.checkForUpdate());
      }
    });
  }

  @override
  void dispose() {
    widget.desktop.onAction = null;
    _editorSaving.dispose();
    _nodeSearch.dispose();
    widget.tunnelControl.setImportListener(null);
    _pingURL.dispose();
    _pingExpectedStatus.dispose();
    _pingExpectedBody.dispose();
    _monitorTimer?.cancel();
    _localStateTimer?.cancel();
    final dispose = widget.onDispose;
    if (dispose != null) unawaited(dispose().catchError((Object _) {}));
    super.dispose();
  }

  // Rows and the latency sort look nodes up repeatedly; index each snapshot once.
  SubscriptionSnapshot? _indexedSubscriptions;
  Map<String, SubscriptionNode> _nodesById = const {};

  // The open Troubleshoot dialog is its own route; it rebuilds with this state.
  StateSetter? _troubleshootRefresh;

  // setState is protected; the extensions in the part files update through this.
  void _set(VoidCallback update) {
    setState(update);
    _troubleshootRefresh?.call(() {});
  }

  @override
  Widget build(BuildContext context) {
    // The resolver skips its callback when the language returns to the system
    // one, so [appLocale] follows the Localizations scope, rebuilding with it.
    appLocale = Localizations.localeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        widget.desktop.status(
          _noTraffic ? 'connected, no traffic' : _state.name,
          canConnect: _canConnect,
          canDisconnect: _canDisconnect,
        );
    });
    final counters = Map<String, Object?>.from(
      _metrics['counters'] as Map? ?? const <String, Object?>{},
    );
    String megabytes(Object? value) =>
        (((value as num?)?.toDouble() ?? 0) / (1024 * 1024)).toStringAsFixed(1);
    final xrayMetrics = {'xrayTun', 'xrayProxy'}.contains(_metrics['backend']);
    final memoryLimit = _settings.memoryLimitMB == 0
        ? l10n.memoryLimitAutomatic
        : l10n.megabytesValue(megabytes(counters['memoryLimitBytes']));
    final extensionMemory = l10n.extensionMemory(
      megabytes(_metrics['extensionMemoryBytes']),
    );
    final memorySummary = xrayMetrics
        ? '${l10n.xrayHeap(megabytes(counters['heapAllocBytes']), memoryLimit)}${widget.desktopCore ? ' ${l10n.softLimit}' : ' · $extensionMemory'}'
        : extensionMemory;
    final sessions = l10n.sessionsSummary(
      counters['activeTcpSessions'] ?? 0,
      counters['activeUdpSessions'] ?? 0,
    );
    final activitySummary = xrayMetrics
        ? '${l10n.trafficSummary(counters['uplinkBytes'] ?? 0, counters['downlinkBytes'] ?? 0)} · $sessions'
        : '${l10n.packetsSummary(counters['packetsIn'] ?? 0, counters['packetsOut'] ?? 0)} · $sessions';
    Widget toggle(
      String title,
      bool value,
      TunnelSettings Function(bool) update, {
      String? help,
    }) => ElarniCheckboxTile(
      title: help == null ? Text(title) : ElarniHelpLabel(title, help: help),
      value: value,
      onChanged: _busy ? null : (enabled) => _saveSettings(update(enabled)),
    );
    Widget numberSetting(
      String title,
      int value,
      List<int> choices,
      TunnelSettings Function(int) update, {
      String? help,
    }) => ElarniSelectTile(
      title: help == null ? Text(title) : ElarniHelpLabel(title, help: help),
      trailing: ElarniSelect<int>(
        key: ValueKey('setting:$title'),
        value: value,
        items: [
          for (final choice in (<int>{...choices, value}.toList()..sort()))
            DropdownMenuItem(
              value: choice,
              child: Text(choice == 0 ? l10n.automatic : '$choice'),
            ),
        ],
        onChanged: _busy
            ? null
            : (choice) {
                if (choice != null) _saveSettings(update(choice));
              },
      ),
    );
    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
    Widget action({
      required Widget title,
      Widget? subtitle,
      required String label,
      required VoidCallback? onPressed,
    }) => ElarniSelectTile(
      title: title,
      subtitle: subtitle,
      onTap: onPressed,
      trailing: OutlinedButton(onPressed: onPressed, child: Text(label)),
    );
    if (_page == DesktopPage.routing) {
      _perAppDraft ??= PerAppRoutingDraft(_settings);
    }
    _perAppDraft?.rebase(_settings);
    final appRoutes = _perAppDraft?.settings ?? _settings;
    Widget routeToggle(
      String title,
      bool value,
      TunnelSettings Function(TunnelSettings, bool) update, {
      String? help,
    }) => ElarniCheckboxTile(
      title: help == null ? Text(title) : ElarniHelpLabel(title, help: help),
      value: value,
      onChanged: _busy
          ? null
          // The per-app editor changes the draft without rebuilding this row.
          : (value) => setState(
              () => _perAppDraft!.settings = update(
                _perAppDraft!.settings,
                value,
              ),
            ),
    );
    Widget perAppRouting() => PerAppRoutingEditor(
      settings: _settings,
      windows: widget.windows,
      linux: widget.linux,
      servers: [
        for (final group in _subscriptions.subscriptions)
          for (final node in group.nodes)
            if (node.isVPN) (node.id, node.name),
      ],
      enabled: !_busy,
      draft: _perAppDraft,
      onCancel: () => setState(() {}),
      onSave: (_) async {
        final settings = _perAppDraft!.applyTo(_settings);
        final routeError = settings.routeEnforcementError;
        if (routeError != null)
          throw FormatException(routeEnforcementText(routeError));
        if (!await _saveSettings(settings)) {
          throw StateError('Settings were not saved');
        }
        if (mounted) setState(() => _perAppDraft!.reset(_settings));
      },
      advancedRoutes: ExpansionTile(
        key: const Key('advanced-network-routes'),
        title: Text(l10n.advancedNetworkRoutes),
        tilePadding: EdgeInsets.zero,
        children: [
          routeToggle(
            l10n.enforceTunnelRoutes,
            appRoutes.enforceRoutes,
            (routes, value) => routes.copyWith(enforceRoutes: value),
            help: widget.desktopCore
                ? l10n.enforceRoutesDesktopHelp
                : l10n.enforceRoutesMacHelp,
          ),
          if (widget.desktopCore)
            routeToggle(
              l10n.includeAllNetworks,
              appRoutes.includeAllNetworks,
              (routes, value) => routes.copyWith(includeAllNetworks: value),
              help: l10n.includeAllNetworksHelp,
            ),
          if (!widget.linux)
            ElarniCheckboxTile(
              title: ElarniHelpLabel(
                l10n.compatibilityRouteExclusions,
                help: l10n.compatibilityRouteExclusionsHelp,
              ),
              value: appRoutes.hideVPNIcon,
              onChanged: _busy ? null : _toggleHideVPNIcon,
            ),
          ListTile(
            title: Text(l10n.includedRoutes),
            subtitle: Text(appRoutes.includedRoutes.join(', ')),
            trailing: const Icon(CupertinoIcons.chevron_right),
            onTap: _busy ? null : () => _editRoutes(included: true),
          ),
          ListTile(
            title: Text(l10n.excludedRoutes),
            subtitle: Text(
              appRoutes.excludedRoutes.isEmpty
                  ? l10n.none
                  : appRoutes.excludedRoutes.join(', '),
            ),
            trailing: const Icon(CupertinoIcons.chevron_right),
            onTap: _busy ? null : () => _editRoutes(included: false),
          ),
        ],
      ),
    );
    final settingsSections = <SettingsCategory, List<Widget>>{
      SettingsCategory.general: [
        ElarniSelectTile(
          title: Text(l10n.language),
          trailing: ElarniSelect<String>(
            key: const Key('language'),
            value: widget.desktop.language,
            items: [
              for (final language in DesktopIntegration.languages)
                DropdownMenuItem(
                  value: language,
                  // Each language in its own words, so a reader of either finds it.
                  child: Text(
                    language == 'system'
                        ? l10n.followSystem
                        : lookupAppLocalizations(Locale(language)).languageName,
                  ),
                ),
            ],
            onChanged: !widget.desktop.available || widget.desktop.saving
                ? null
                : (value) {
                    if (value != null) _saveDesktop(language: value);
                  },
          ),
        ),
        section(l10n.settingsConnection),
        action(
          label: l10n.configure,
          title: Text(l10n.connectionRecovery),
          subtitle: Text(
            _automation['enabled'] != true
                ? l10n.recoveryOffSummary
                : _automation['policy'] == 'fixed'
                ? l10n.recoveryFixedSummary
                : l10n.recoveryBackupsSummary,
          ),
          onPressed: _busy || _selectedNode == null ? null : _configureRecovery,
        ),
        toggle(
          l10n.onDemand,
          _settings.onDemandEnabled,
          (value) => _settings.copyWith(onDemandEnabled: value),
          help: widget.desktopCore
              ? l10n.onDemandDesktopHelp
              : l10n.onDemandMacHelp,
        ),
        toggle(
          l10n.connectOnUntrustedWifi,
          _settings.connectOnUntrustedWiFi,
          (value) => _settings.copyWith(connectOnUntrustedWiFi: value),
          help: widget.desktopCore
              ? l10n.untrustedWifiDesktopHelp
              : l10n.untrustedWifiMacHelp,
        ),
        if (_settings.connectOnUntrustedWiFi) ...[
          action(
            label: l10n.edit,
            title: Text(l10n.trustedWifiNetworks),
            subtitle: Text(
              _settings.trustedWiFiNetworks.isEmpty
                  ? l10n.noTrustedWifi
                  : _settings.trustedWiFiNetworks.join(', '),
            ),
            onPressed: _busy ? null : _editTrustedWiFi,
          ),
          if (_automation['wifi'] == 'locationDenied')
            ListTile(subtitle: Text(l10n.windowsWifiLocationHelp)),
        ],
        ElarniCheckboxTile(
          title: Text(l10n.launchAtLogin),
          subtitle: Text(switch (_systemInfo['launchAtLoginStatus']) {
            'enabled' => l10n.loginRegistered,
            'requiresApproval' => l10n.loginApprovalRequired,
            'notRegistered' => l10n.loginNotRegistered,
            'notFound' => l10n.loginServiceNotFound,
            _ => l10n.loginStateUnavailable,
          }),
          value: const [
            'enabled',
            'requiresApproval',
          ].contains(_systemInfo['launchAtLoginStatus']),
          onChanged: _systemBusy
              ? null
              : (value) => _refreshSystemInfo(launchAtLogin: value),
        ),
        if (_systemError != null) ListTile(subtitle: Text(_systemError!)),
        toggle(
          l10n.disconnectOnSleep,
          _settings.disconnectOnSleep,
          (value) => _settings.copyWith(disconnectOnSleep: value),
          help: widget.desktopCore
              ? l10n.disconnectsWhenSleeps(widget.platformName)
              : l10n.macDisconnectsWhenSleeping,
        ),
        section(l10n.subscriptions),
        numberSetting(
          l10n.subscriptionAutoUpdateHours,
          _settings.subscriptionAutoUpdateHours,
          const [1, 2, 4, 6, 12, 24, 48, 168],
          (value) => _settings.copyWith(subscriptionAutoUpdateHours: value),
          help: l10n.subscriptionAutoUpdateHelp,
        ),
        ElarniCheckboxTile(
          title: ElarniHelpLabel(
            l10n.subscriptionExpiryReminders,
            help: l10n.subscriptionExpiryRemindersHelp,
          ),
          value: widget.desktop.expiryReminders,
          onChanged: !widget.desktop.available || widget.desktop.saving
              ? null
              : (value) => _saveDesktop(expiryReminders: value),
        ),
        if (widget.desktop.available)
          ElarniSelectTile(
            title: Text(l10n.serverOrder),
            trailing: ElarniSelect<String>(
              value: widget.desktop.sort,
              items: [
                DropdownMenuItem(
                  value: 'provider',
                  child: Text(l10n.providerOrder),
                ),
                DropdownMenuItem(
                  value: 'alphabet',
                  child: Text(l10n.alphabetical),
                ),
                DropdownMenuItem(
                  value: 'latency',
                  child: Text(l10n.lowestLatency),
                ),
              ],
              onChanged: widget.desktop.saving
                  ? null
                  : (value) {
                      if (value != null) _saveDesktop(sort: value);
                    },
            ),
          ),
        if (widget.desktop.available)
          ElarniCheckboxTile(
            title: Text(l10n.favoritesFirst),
            value: widget.desktop.favoritesFirst,
            onChanged: widget.desktop.saving
                ? null
                : (value) => _saveDesktop(favoritesFirst: value),
          ),
        if (widget.desktop.available) ...[
          section(l10n.updates),
          action(
            title: ElarniHelpLabel(l10n.updateFeed, help: l10n.updateFeedHelp),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.desktop.updateFeedURL.isEmpty
                      ? l10n.off
                      : widget.desktop.updateFeedURL,
                ),
                if (widget.desktop.updateFeedURL.isNotEmpty &&
                    widget.desktop.updateChecked != null)
                  Text(
                    widget.desktop.availableUpdate != null
                        ? l10n.updateAvailable(
                            widget.desktop.availableUpdate!.version,
                          )
                        : widget.desktop.updateChecked!.read
                        ? l10n.upToDate
                        : l10n.feedUnreadable,
                  ),
              ],
            ),
            label: l10n.change,
            onPressed: widget.desktop.saving ? null : _editUpdateFeed,
          ),
        ],
      ],
      SettingsCategory.appearance: [
        ElarniSelectTile(
          title: Text(l10n.theme),
          trailing: ElarniSelect<ThemeMode>(
            value: widget.desktop.theme,
            items: [
              DropdownMenuItem(
                value: ThemeMode.system,
                child: Text(l10n.followSystem),
              ),
              DropdownMenuItem(value: ThemeMode.light, child: Text(l10n.light)),
              DropdownMenuItem(value: ThemeMode.dark, child: Text(l10n.dark)),
            ],
            onChanged: !widget.desktop.available || widget.desktop.saving
                ? null
                : (value) {
                    if (value != null) _saveDesktop(theme: value);
                  },
          ),
        ),
        ElarniSelectTile(
          title: Text(l10n.accentColor),
          trailing: ElarniSelect<String>(
            value: widget.desktop.accent,
            items: [
              for (final color in DesktopIntegration.accents.keys)
                DropdownMenuItem(
                  value: color,
                  child: Text('${color[0].toUpperCase()}${color.substring(1)}'),
                ),
            ],
            onChanged: !widget.desktop.available || widget.desktop.saving
                ? null
                : (value) {
                    if (value != null) _saveDesktop(accent: value);
                  },
          ),
        ),
        if (widget.desktop.error != null)
          ListTile(title: Text(widget.desktop.error!)),
      ],
      SettingsCategory.connection: [
        section('VPN'),
        if (widget.desktopCore)
          ElarniSelectTile(
            title: ElarniHelpLabel(
              l10n.connectionMode,
              help: widget.windows
                  ? l10n.connectionModeServiceHelp
                  : l10n.connectionModeHelp,
            ),
            trailing: ElarniSelect<String>(
              value: _settings.xrayTunEnabled
                  ? 'tun'
                  : _settings.systemProxyEnabled
                  ? 'systemProxy'
                  : 'localProxy',
              items: [
                DropdownMenuItem(value: 'tun', child: Text(l10n.systemWideVpn)),
                DropdownMenuItem(
                  value: 'systemProxy',
                  child: Text(l10n.systemProxy),
                ),
                DropdownMenuItem(
                  value: 'localProxy',
                  child: Text(l10n.localProxyOnly),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      final tun = value == 'tun';
                      _saveSettings(
                        _settings.copyWith(
                          xrayTunEnabled: tun,
                          systemProxyEnabled: value == 'systemProxy',
                          perAppMode: tun ? _settings.perAppMode : 'off',
                        ),
                      );
                    },
            ),
          )
        else
          toggle(
            'Xray TUN',
            _settings.xrayTunEnabled,
            (value) => _settings.copyWith(
              xrayTunEnabled: value,
              perAppMode: value ? _settings.perAppMode : 'off',
            ),
          ),
        if (widget.windows) ...[
          ElarniCheckboxTile(
            title: ElarniHelpLabel(
              l10n.connectWithoutAdminApproval,
              help: l10n.connectWithoutAdminApprovalHelp,
            ),
            value: _systemInfo['vpnService'] == true,
            onChanged: _systemBusy
                ? null
                : (value) => _refreshSystemInfo(vpnService: value),
          ),
          if (_systemError != null) ListTile(subtitle: Text(_systemError!)),
        ],
        // macOS has no guard of its own: the switch is Include all networks.
        ElarniCheckboxTile(
          title: ElarniHelpLabel(
            l10n.blockTrafficWithoutVpn,
            help: widget.desktopCore
                ? l10n.blockTrafficDesktopHelp
                : l10n.blockTrafficMacHelp,
          ),
          value: widget.desktopCore
              ? _settings.blockWithoutVPN
              : _settings.includeAllNetworks,
          onChanged: _busy || widget.desktopCore && !_settings.xrayTunEnabled
              ? null
              : (value) {
                  final next = widget.desktopCore
                      ? _settings.copyWith(blockWithoutVPN: value)
                      : _settings.copyWith(includeAllNetworks: value);
                  if (next.routeEnforcementError case final error?) {
                    _set(() => _message = routeEnforcementText(error));
                  } else {
                    _saveSettings(next);
                  }
                },
        ),
        section(l10n.serverAddressing),
        ElarniSelectTile(
          title: ElarniHelpLabel(
            l10n.defaultIpType,
            help: l10n.defaultIpTypeHelp,
          ),
          trailing: ElarniSelect<String>(
            value: _settings.profilePreferredIP,
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'inherit', child: Text(l10n.useProfile)),
              DropdownMenuItem(value: 'ipv4', child: Text('IPv4')),
              DropdownMenuItem(value: 'ipv6', child: Text('IPv6')),
              DropdownMenuItem(value: 'automatic', child: Text(l10n.automatic)),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      _saveSettings(
                        _settings.copyWith(
                          profilePreferredIP: value,
                          preferredIP: value == 'inherit'
                              ? _settings.preferredIP
                              : value,
                        ),
                      );
                    }
                  },
          ),
        ),
        // As on Android: servers from share links have no profile value to use.
        if (_settings.profilePreferredIP == 'inherit')
          ElarniSelectTile(
            title: Text(l10n.shareLinkServers),
            trailing: ElarniSelect<String>(
              value: _settings.preferredIP,
              items: <DropdownMenuItem<String>>[
                const DropdownMenuItem(value: 'ipv4', child: Text('IPv4')),
                const DropdownMenuItem(value: 'ipv6', child: Text('IPv6')),
                DropdownMenuItem(
                  value: 'automatic',
                  child: Text(l10n.automatic),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null)
                        _saveSettings(_settings.copyWith(preferredIP: value));
                    },
            ),
          ),
        if (_selectedNode case final node?)
          ElarniSelectTile(
            title: Text(l10n.serverIpType),
            subtitle: Text(ServerLocation.displayName(node.name)),
            trailing: ElarniSelect<String>(
              key: ValueKey('node-ip-${node.id}'),
              value: node.ipPreference ?? 'default',
              items: [
                DropdownMenuItem(
                  value: 'default',
                  child: Text(l10n.useAppDefault),
                ),
                DropdownMenuItem(
                  value: 'automatic',
                  child: Text(l10n.automatic),
                ),
                DropdownMenuItem(value: 'ipv4', child: Text('IPv4')),
                DropdownMenuItem(value: 'ipv6', child: Text('IPv6')),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null)
                        _setNodeIPPreference(
                          node.id,
                          value == 'default' ? null : value,
                        );
                    },
            ),
          ),
        section(l10n.localProxy),
        if (_settings.systemProxy)
          ListTile(subtitle: Text(l10n.systemProxyListeners)),
        ElarniCheckboxTile(
          title: Text(l10n.httpInbound),
          value: _settings.listeners.httpInboundEnabled,
          onChanged: _busy || _settings.systemProxy
              ? null
              : (value) => _saveSettings(
                  _settings.copyWith(httpInboundEnabled: value),
                ),
        ),
        action(
          label: l10n.edit,
          title: ElarniHelpLabel(
            l10n.socksAndHttpPorts,
            help: l10n.listenersHelp,
          ),
          subtitle: Text(
            l10n.listenersSummary(
              _settings.listeners.allowLAN
                  ? l10n.listenLan
                  : l10n.listenLoopback,
              _settings.socksPort,
              _settings.listeners.httpInboundEnabled
                  ? '${_settings.httpPort}'
                  : l10n.httpOff,
            ),
          ),
          onPressed: _busy ? null : _editListenerPorts,
        ),
        ElarniSelectTile(
          title: ElarniHelpLabel(l10n.proxyLogin, help: l10n.proxyLoginHelp),
          subtitle: Text(switch (_inboundLogin) {
            {'username': final username, 'password': final password} =>
              '$username · ${_showInboundPassword ? password : '••••••••••••'}',
            _ => l10n.notConfigured,
          }),
          onTap: _busy ? null : _editInboundCredentials,
          trailing: Wrap(
            spacing: 4,
            children: [
              if (_inboundLogin['password'] case final password?) ...[
                TextButton(
                  onPressed: () =>
                      _set(() => _showInboundPassword = !_showInboundPassword),
                  child: Text(_showInboundPassword ? l10n.hide : l10n.show),
                ),
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: password)),
                  child: Text(l10n.copy),
                ),
              ],
              OutlinedButton(
                onPressed: _busy ? null : _editInboundCredentials,
                child: Text(_inboundLogin.isEmpty ? l10n.set : l10n.change),
              ),
            ],
          ),
        ),
        if (widget.desktopCore)
          ElarniCheckboxTile(
            title: ElarniHelpLabel(
              l10n.allowAppsWithoutLoginToggle,
              help: l10n.allowAppsWithoutLoginHelp,
            ),
            value: !_settings.listeners.inboundAuthEnabled,
            onChanged: _busy || _settings.systemProxy
                ? null
                : (allow) => allow ? _allowAppsWithoutLogin() : _requireLogin(),
          )
        else
          ElarniCheckboxTile(
            title: ElarniHelpLabel(
              l10n.requireProxyAuth,
              help: l10n.requireProxyAuthHelp,
            ),
            value: _settings.inboundAuthEnabled,
            onChanged: _busy || !_settings.inboundCredentialsConfigured
                ? null
                : (value) => _saveSettings(
                    _settings.copyWith(
                      inboundAuthEnabled: value,
                      allowLAN: value && _settings.allowLAN,
                    ),
                  ),
          ),
        ElarniCheckboxTile(
          title: ElarniHelpLabel(l10n.allowLan, help: l10n.allowLanHelp),
          value: _settings.listeners.allowLAN,
          onChanged:
              _busy || !_settings.inboundAuthEnabled || _settings.systemProxy
              ? null
              : (value) => _saveSettings(_settings.copyWith(allowLAN: value)),
        ),
      ],
      SettingsCategory.dns: [
        ElarniSelectTile(
          title: ElarniHelpLabel(l10n.dnsSettings, help: l10n.dnsSettingsHelp),
          trailing: ElarniSelect<String>(
            value: _settings.profileDNSMode,
            items: [
              DropdownMenuItem(
                value: 'inherit',
                child: Text(l10n.providerProfile),
              ),
              DropdownMenuItem(
                value: 'routing',
                child: Text(l10n.routingProfile),
              ),
              DropdownMenuItem(value: 'default', child: Text('1.1.1.1')),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null)
                      _saveSettings(
                        _settings.copyWith(
                          profileDNSMode: value,
                          useDNSFromJSON: value != 'default',
                        ),
                      );
                  },
          ),
        ),
        if (_settings.profileDNSMode == 'routing') ...[
          section(l10n.routingProfiles),
          for (final profile in _routing.profiles.where(
            (profile) => profile.enabled,
          ))
            action(
              title: Text(profile.name),
              label: l10n.editDns,
              onPressed: _busy
                  ? null
                  : () => _editStructuredRouting(profile, initialSection: 1),
            ),
          if (!_routing.profiles.any((profile) => profile.enabled))
            ListTile(subtitle: Text(l10n.noEnabledRoutingProfiles)),
        ],
        ElarniCheckboxTile(
          title: ElarniHelpLabel(
            l10n.resolveServerBeforeConnecting,
            help: l10n.resolveServerHelp,
          ),
          value: _settings.resolveServer,
          onChanged: _busy
              ? null
              : (value) =>
                    _saveSettings(_settings.copyWith(resolveServer: value)),
        ),
      ],
      SettingsCategory.advanced: [
        section(l10n.transport),
        ElarniCheckboxTile(
          title: ElarniHelpLabel(
            l10n.enableFragmentation,
            help: l10n.fragmentationHelp,
          ),
          value: _settings.fragmentationEnabled,
          onChanged: _busy
              ? null
              : (value) => _saveSettings(
                  _settings.copyWith(fragmentationEnabled: value),
                ),
        ),
        action(
          label: l10n.edit,
          title: Text(l10n.fragmentationOptions),
          subtitle: Text(
            l10n.fragmentationSummary(
              _settings.fragmentPackets,
              _settings.fragmentLength,
              _settings.fragmentInterval,
            ),
          ),
          onPressed: _busy ? null : _editFragmentation,
        ),
        toggle(
          l10n.enableDefaultVlessMux,
          _settings.muxEnabled,
          (value) => _settings.copyWith(muxEnabled: value),
          help: l10n.defaultMuxHelp,
        ),
        section(l10n.resources),
        numberSetting(
          l10n.xrayMemoryLimit,
          _settings.memoryLimitMB,
          (<int>{
            0,
            if (widget.desktopCore) ...[40, 45, 50],
            64,
            128,
            256,
            512,
            1024,
            4096,
            _settings.memoryLimitMB,
          }.toList()..sort()),
          (value) => _settings.copyWith(memoryLimitMB: value),
        ),
        numberSetting(
          l10n.connectionIdleTimeout,
          _settings.idleTimeoutSeconds,
          const <int>[30, 60, 120, 300, 600, 1800, 3600],
          (value) => _settings.copyWith(idleTimeoutSeconds: value),
        ),
        numberSetting(
          l10n.tcpMaxConnections,
          _settings.tcpMaxConnections,
          const <int>[64, 128, 256, 512, 1024, 2048, 4096],
          (value) => _settings.copyWith(tcpMaxConnections: value),
        ),
        numberSetting(
          l10n.udpMaxConnections,
          _settings.udpMaxConnections,
          const <int>[32, 64, 128, 256, 512, 1024, 2048, 4096],
          (value) => _settings.copyWith(udpMaxConnections: value),
        ),
        toggle(
          l10n.enableSniffing,
          _settings.sniffingEnabled,
          (value) => _settings.copyWith(sniffingEnabled: value),
        ),
        section(l10n.monitoring),
        toggle(
          l10n.showMonitoringOnMain,
          _settings.monitoringEnabled,
          (value) => _settings.copyWith(monitoringEnabled: value),
        ),
        if (recordingBuild) ...[
          section(l10n.diagnosticsSection),
          toggle(
            l10n.recordConnectionDiagnostics,
            _settings.recordDiagnostics,
            (value) => _settings.copyWith(recordDiagnostics: value),
            help: l10n.recordConnectionDiagnosticsHelp,
          ),
          action(
            label: l10n.markAction,
            title: ElarniHelpLabel(
              l10n.markProblemNow,
              help: l10n.markProblemNowHelp,
            ),
            onPressed: _settings.recordDiagnostics ? _markRecording : null,
          ),
          action(
            label: l10n.export,
            title: Text(l10n.saveRecordingAsZip),
            onPressed: _busy ? null : _exportRecording,
          ),
        ],
      ],
      SettingsCategory.backup: [
        section(l10n.backups),
        action(
          label: l10n.export,
          title: Text(l10n.createEncryptedBackup),
          onPressed: _busy ? null : () => _catalogBackup(restore: false),
        ),
        action(
          label: l10n.restore,
          title: ElarniHelpLabel(
            l10n.restoreBackup,
            help: l10n.restoreBackupHelp,
          ),
          onPressed:
              _busy ||
                  !{
                    TunnelState.disconnected,
                    TunnelState.prepared,
                    TunnelState.failed,
                  }.contains(_state)
              ? null
              : () => _catalogBackup(restore: true),
        ),
        section(l10n.connectionRepair),
        action(
          label: l10n.reviewRepair,
          title: Text(l10n.repairVpnSetup),
          onPressed: _busy ? null : _repairTunnel,
        ),
      ],
      SettingsCategory.system: [
        for (final entry in {
          'os': l10n.operatingSystem,
          'architecture': l10n.appArchitecture,
          'processorCount': l10n.cpuCount,
          'activeProcessorCount': l10n.activeCpus,
        }.entries)
          ListTile(
            title: Text(entry.value),
            subtitle: Text('${_systemInfo[entry.key] ?? l10n.unavailable}'),
          ),
        ListTile(
          title: Text(l10n.physicalMemory),
          subtitle: Text(switch (_systemInfo['physicalMemoryBytes']) {
            final int bytes => l10n.gigabytesValue(
              (bytes / (1 << 30)).toStringAsFixed(1),
            ),
            _ => l10n.unavailable,
          }),
        ),
        // A platform that reports no version gets no placeholder.
        if ([
              if (_systemInfo['appVersion'] case final String version)
                'Elarni $version',
              if (_systemInfo['coreVersion'] case final String version)
                l10n.xrayCoreVersion(version),
            ]
            case final versions when versions.isNotEmpty)
          ListTile(
            title: Text(l10n.versions),
            subtitle: Text(versions.join(' · ')),
          ),
        if (_systemError != null) ListTile(subtitle: Text(_systemError!)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(
                onPressed: _systemBusy ? null : _refreshSystemInfo,
                child: Text(
                  _systemBusy ? l10n.refreshingEllipsis : l10n.refresh,
                ),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _troubleshoot,
                child: Text(l10n.troubleshootConnection),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _exportDiagnostics,
                child: Text(l10n.exportDiagnostics),
              ),
              OutlinedButton(onPressed: _openLogs, child: Text(l10n.logs)),
            ],
          ),
        ),
      ],
      SettingsCategory.routes: [
        if (_routesError != null) ListTile(subtitle: Text(_routesError!)),
        if (_routeTable != null)
          SizedBox(
            height: 320,
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _routeTable!,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          ),
        TextButton(
          onPressed: _routesBusy ? null : _refreshRouteTable,
          child: Text(_routesBusy ? l10n.refreshingEllipsis : l10n.refresh),
        ),
      ],
      SettingsCategory.ping: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ElarniSelect<String>(
              isExpanded: true,
              label: l10n.testType,
              value: _pingProtocol,
              items: <DropdownMenuItem<String>>[
                DropdownMenuItem(
                  value: 'proxy',
                  child: Text(l10n.testThroughProxy),
                ),
                DropdownMenuItem(
                  value: 'activeProxy',
                  child: Text(l10n.currentRulesActiveTunnel),
                ),
                DropdownMenuItem(value: 'tcp', child: Text(l10n.directTcp)),
                DropdownMenuItem(value: 'icmp', child: Text(l10n.directIcmp)),
              ],
              onChanged: _pingControlsDisabled
                  ? null
                  : (value) => setState(() => _pingProtocol = value!),
            ),
            const SizedBox(height: 12),
            if (const {'proxy', 'activeProxy'}.contains(_pingProtocol)) ...[
              ElarniSelect<String>(
                isExpanded: true,
                label: l10n.httpMethod,
                value: _pingMethod,
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'GET', child: Text(l10n.proxyGet)),
                  DropdownMenuItem(value: 'HEAD', child: Text(l10n.proxyHead)),
                ],
                onChanged:
                    _pingControlsDisabled ||
                        !const {'proxy', 'activeProxy'}.contains(_pingProtocol)
                    ? null
                    : (value) => setState(() => _pingMethod = value!),
              ),
              const SizedBox(height: 12),
              ElarniSelect<String>(
                isExpanded: true,
                label: l10n.testMode,
                value: _pingMode,
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem(
                    value: 'default',
                    child: Text(l10n.testModeDefault),
                  ),
                  DropdownMenuItem(
                    value: 'double',
                    child: Text(l10n.testModeDouble),
                  ),
                  DropdownMenuItem(
                    value: 'keepalive',
                    child: Text('Keep-alive'),
                  ),
                ],
                onChanged:
                    _pingControlsDisabled ||
                        !const {'proxy', 'activeProxy'}.contains(_pingProtocol)
                    ? null
                    : (value) => setState(() => _pingMode = value!),
              ),
              const SizedBox(height: 12),
            ],
            ElarniSelect<int>(
              isExpanded: true,
              label: l10n.timeout,
              value: _pingTimeout,
              items: <int>[5, 7, 9, 12, 15]
                  .map(
                    (value) => DropdownMenuItem<int>(
                      value: value,
                      child: Text(l10n.secondsTimeout(value)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _pingControlsDisabled
                  ? null
                  : (value) => setState(() => _pingTimeout = value!),
            ),
          ],
        ),
        if (const {'proxy', 'activeProxy'}.contains(_pingProtocol)) ...[
          section(l10n.httpRequest),
          TextField(
            key: const Key('ping-url'),
            controller: _pingURL,
            enabled: !_pingControlsDisabled,
            decoration: InputDecoration(
              labelText: l10n.testUrl,
              hintText: 'https://www.gstatic.com/generate_204',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('ping-expected-status'),
            controller: _pingExpectedStatus,
            enabled: !_pingControlsDisabled,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l10n.expectedHttpStatus),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pingExpectedBody,
            enabled: !_pingControlsDisabled,
            decoration: InputDecoration(
              labelText: l10n.expectedResponseBody,
              helperText: l10n.expectedBodyHelp,
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () => setState(() => _page = DesktopPage.home),
            child: Text(l10n.openServerList),
          ),
        ),
      ],
    };
    Widget pageList(
      String key,
      String title,
      List<Widget> children, {
      Widget? action,
    }) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            key: ValueKey(key),
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  ?action,
                ],
              ),
              const SizedBox(height: 20),
              for (final child in children)
                if (child is Card)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: child,
                  )
                else
                  child,
            ],
          ),
        ),
      ),
    );
    return ElarniShell(
      page: _page,
      onNavigate: (page) => setState(() => _page = page),
      importBusy: _busy,
      importing: _importing,
      onImport: _importProfiles,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Stack(
          children: [
            Positioned.fill(
              child: switch (_page) {
                DesktopPage.settings => ElarniSettings(
                  category: _settingsCategory,
                  help: _settingsCategory == SettingsCategory.routes
                      ? l10n.routeTableHelp
                      : null,
                  onSelect: _selectSettingsCategory,
                  children: settingsSections[_settingsCategory]!,
                ),
                DesktopPage.routing => pageList(
                  'routing-list',
                  l10n.routing,
                  [
                    DefaultTabController(
                      // An import that opens the profiles moves the tab too.
                      key: ValueKey(_routingTab),
                      length: 2,
                      initialIndex: _routingTab,
                      child: TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        onTap: (index) => setState(() => _routingTab = index),
                        tabs: [
                          Tab(text: l10n.routingProfiles),
                          Tab(text: l10n.perAppRouting),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_routingTab == 0)
                      ..._routingItems()
                    else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.perAppRoutingIntro,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            perAppRouting(),
                          ],
                        ),
                      ),
                  ],
                  action: _routingTab == 0
                      ? IconButton(
                          tooltip: l10n.refreshProfiles,
                          onPressed: _busy ? null : _refreshRouting,
                          icon: const Icon(CupertinoIcons.arrow_clockwise),
                        )
                      : null,
                ),
                DesktopPage.subscriptions => pageList(
                  'subscriptions-list',
                  l10n.subscriptions,
                  [
                    if (_subscriptions.subscriptions.isEmpty) ...[
                      const SizedBox(height: 12),
                      Text(l10n.noSubscriptionsYet),
                      const SizedBox(height: 8),
                      Text(l10n.addSubscriptionToStart),
                    ],
                    // Built only here: each card parses every server name.
                    for (final group in _subscriptions.subscriptions)
                      _subscriptionCard(group),
                  ],
                ),
                DesktopPage.home => _homeContent(
                  memorySummary,
                  activitySummary,
                ),
              },
            ),
            if (_message != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Semantics(
                                liveRegion: true,
                                child: Text(_message!),
                              ),
                            ),
                            if (_messageAction case final action?
                                when action.message == _message)
                              TextButton(
                                onPressed: action.onPressed,
                                child: Text(action.label),
                              ),
                            IconButton(
                              tooltip: l10n.dismissMessage,
                              icon: const Icon(CupertinoIcons.xmark, size: 18),
                              onPressed: () => setState(() => _message = null),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
