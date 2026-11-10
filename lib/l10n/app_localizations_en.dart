// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get noLogLinesYet =>
      'No log lines yet. The core records them while it runs.';

  @override
  String get loggingOff =>
      'Logging is off. Choose a level to record the core log.';

  @override
  String get saveEllipsis => 'Save…';

  @override
  String get copy => 'Copy';

  @override
  String get logLevel => 'Level';

  @override
  String get logNotSaved => 'The log could not be saved.';

  @override
  String get saved => 'Saved';

  @override
  String get copied => 'Copied';

  @override
  String get logLevelNotSaved => 'The log level could not be saved.';

  @override
  String get logLevelAppliesNextConnection =>
      'The level applies from the next connection.';

  @override
  String get close => 'Close';

  @override
  String get logs => 'Logs';

  @override
  String get logLevelDebug => 'Debug';

  @override
  String get logLevelInfo => 'Info';

  @override
  String get logLevelWarning => 'Warning';

  @override
  String get logLevelError => 'Error';

  @override
  String get logLevelOff => 'Off';

  @override
  String get issueOperationFailedRemedy =>
      'Refresh status and retry the selected server. Export diagnostics if it keeps failing.';

  @override
  String get issueOperationFailed => 'The connection operation failed.';

  @override
  String get issueCancelledRemedy => 'Your manual action takes priority.';

  @override
  String get issueCancelled => 'The operation was cancelled.';

  @override
  String get issuePerAppTargetMissingRemedy =>
      'Choose another target for it in Per-app routing.';

  @override
  String get issuePerAppTargetMissing =>
      'An app in Per-app routing uses a server that no longer exists.';

  @override
  String get issueStorageUnavailableRemedy =>
      'Restart Elarni. If this continues, restore an encrypted backup.';

  @override
  String get issueStorageUnavailable =>
      'Elarni could not read or save its catalog.';

  @override
  String get issueBusyRemedy => 'Wait for it to finish, then retry.';

  @override
  String get issueBusy => 'Another operation is in progress.';

  @override
  String get issueVpnGuardStaleRemedy =>
      'Use Repair VPN setup and allow the administrator permission request.';

  @override
  String get issueVpnGuardStale => 'DNS is blocked by a crashed tunnel.';

  @override
  String get issueVpnGuardBusyRemedy =>
      'Disconnect the other user or the system service, then retry.';

  @override
  String get issueVpnGuardBusy =>
      'Another Elarni VPN is connected on this computer.';

  @override
  String get issueVpnFirewallUnavailableRemedy =>
      'Install nftables (the nft command), then retry.';

  @override
  String get issueVpnFirewallUnavailable => 'The VPN firewall tool is missing.';

  @override
  String get issueDisconnectUnconfirmedRemedy =>
      'Refresh status before reconnecting, or use Repair VPN setup.';

  @override
  String get issueDisconnectUnconfirmed =>
      'Disconnection could not be confirmed.';

  @override
  String get issueProviderUnavailableRemedy =>
      'Retry the selected server. If the problem continues, use Repair VPN setup.';

  @override
  String get issueProviderUnavailable => 'The VPN runtime is unavailable.';

  @override
  String get issueCheckFailedRemedy =>
      'Retry the check. A timeout, target failure or authentication problem may need different action.';

  @override
  String get issueCheckFailed => 'The connection check failed.';

  @override
  String get issueStatusUnavailableRemedy =>
      'Refresh status. The last known state does not confirm the current connection.';

  @override
  String get issueStatusUnavailable => 'Connection status is unavailable.';

  @override
  String get issuePreviousRestoredRemedy =>
      'Check access before retrying another server.';

  @override
  String get issuePreviousRestored =>
      'The replacement failed; the previous configuration was restored.';

  @override
  String get issueRecoveryRequiredRemedy =>
      'Disconnect before retrying. If that fails, use Repair VPN setup.';

  @override
  String get issueRecoveryRequired =>
      'The connection could not be restored safely.';

  @override
  String get issueInvalidConfigurationRemedy =>
      'Review its settings or refresh the affected subscription.';

  @override
  String get issueInvalidConfiguration =>
      'The selected configuration cannot be used.';

  @override
  String get issueInvalidRecoveryRemedy =>
      'Choose the current server, allowed backups and connection-check targets again.';

  @override
  String get issueInvalidRecovery =>
      'The recovery settings are incomplete or no longer valid.';

  @override
  String get issueMissingCredentialsRemedy =>
      'Refresh or import the affected subscription again.';

  @override
  String get issueMissingCredentials =>
      'The server credentials are unavailable.';

  @override
  String get issueRecoveryExhaustedRemedy =>
      'Retry the selected server or review the backups you allowed.';

  @override
  String get issueRecoveryExhausted =>
      'Automatic recovery could not find working access.';

  @override
  String get issueUnsupportedPolicyRemedy =>
      'On macOS, checks require a full tunnel, no route exclusions or custom rules, and Xray TUN off. Your routing settings were preserved.';

  @override
  String get issueUnsupportedPolicy =>
      'Automatic traffic checks do not support this routing setup.';

  @override
  String get issueConnectionFailedRemedy =>
      'Retry this server and check its configuration or subscription.';

  @override
  String get issueConnectionFailed =>
      'The selected server could not establish working access.';

  @override
  String get issueCheckTargetFailedRemedy =>
      'Check the test URL and DNS settings. This does not prove the server is down.';

  @override
  String get issueCheckTargetFailed =>
      'The connection check could not verify its target.';

  @override
  String get issueListenerUnavailableRemedy =>
      'Close the conflicting app or change the listener port in Connection settings.';

  @override
  String get issueListenerUnavailable =>
      'A local proxy port is occupied or unavailable.';

  @override
  String get issueVpnConfigurationFailedRemedy =>
      'Review VPN permissions in system settings, then retry.';

  @override
  String get issueVpnConfigurationFailed =>
      'The system could not prepare the VPN.';

  @override
  String get issuePermissionDeniedRemedy =>
      'Retry and allow the system permission request.';

  @override
  String get issuePermissionDenied => 'VPN permission was denied.';

  @override
  String get savingEllipsis => 'Saving…';

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get expectedResponseBodyOptional =>
      'Expected response body (optional)';

  @override
  String get expectedHttpStatus => 'Expected HTTP status';

  @override
  String get recoverySecondUrlOptional => 'Optional for same-server recovery';

  @override
  String get checkUrl => 'Check URL';

  @override
  String get secondCheckUrl => 'Second check URL';

  @override
  String get recoveryChecksHelp =>
      'Connection checks send a small request through the connection while recovery is enabled. Choose trusted URLs with a predictable response. Backups require two different check hosts.';

  @override
  String get recoveryTcpFirstHelp =>
      'When a server on UDP or a port other than 443 stops answering, TCP 443 backups go first. If only Russian-entry servers get through, they go first.';

  @override
  String recoveryBackupNumber(Object number) {
    return 'Backup $number';
  }

  @override
  String get recoveryLatencyHelp =>
      'Allowed servers from any subscription to compare. Recovery uses the fastest healthy one and switches only after a meaningful improvement. Choosing another server by hand makes it the primary and keeps these servers.';

  @override
  String get recoveryOrderedHelp =>
      'Allowed backups from any subscription, tried in the order you select them. Choosing another server by hand makes it the primary and keeps these backups.';

  @override
  String get lowestLatency => 'Lowest latency';

  @override
  String get recoveryUseAllowedBackups => 'Use allowed backups';

  @override
  String get recoveryReconnectThisServer => 'Reconnect to this server';

  @override
  String get recovery => 'Recovery';

  @override
  String get recoveryIntro =>
      'Your selected server stays selected. Switching to a backup requires your permission below. Stop cancels recovery.';

  @override
  String get connectionRecovery => 'Connection recovery';

  @override
  String get recoveryChooseBackup =>
      'Choose at least one allowed backup server.';

  @override
  String get recoveryTargetsSameHost =>
      'Use two different check hosts for independent results.';

  @override
  String recoveryTargetInvalid(Object number) {
    return 'Enter a valid check URL and a successful HTTP status for target $number.';
  }

  @override
  String get off => 'Off';

  @override
  String get proxyNeedsScheme => 'Use a socks5:// or http:// address.';

  @override
  String get proxyNotLocal => 'Use a proxy on this device, such as 127.0.0.1.';

  @override
  String get proxyNeedsPort => 'Add the proxy port, such as 127.0.0.1:1080.';

  @override
  String get proxyAddressOnly =>
      'Use only the address and port, without a login or path.';

  @override
  String get proxyIsOwnPort =>
      'That is Elarni\'s own proxy port. Use the other app\'s port.';

  @override
  String get routeEnforcementWithIncludeAll =>
      'Enforce tunnel routes cannot be combined with Include all networks. Turn one of them off.';

  @override
  String get routeEnforcementWithBlock =>
      'Enforce tunnel routes cannot be combined with Block traffic without VPN. Turn one of them off.';

  @override
  String get routeEnforcementDefaultRoutes =>
      'Enforce tunnel routes needs specific included routes. Replace 0.0.0.0/0 and ::/0 with specific routes, or turn enforcement off.';

  @override
  String get providerAttentionLastReported =>
      'Provider attention required · Last reported information';

  @override
  String get notDownloadedYet => 'Not downloaded yet';

  @override
  String get refreshingLastReported => 'Refreshing · Last reported information';

  @override
  String get refreshFailedLastReported =>
      'Refresh failed · Last reported information';

  @override
  String get accountDisabledByProvider => 'Account disabled by provider';

  @override
  String remainingSemantics(Object label, Object value) {
    return '$label remaining: $value';
  }

  @override
  String get openProviderPage => 'Open provider page';

  @override
  String messageFrom(Object name) {
    return 'Message from $name';
  }

  @override
  String latencyMs(Object ms) {
    return '$ms ms';
  }

  @override
  String protocolTooltip(Object protocol) {
    return 'Protocol: $protocol';
  }

  @override
  String get notProvided => 'Not provided';

  @override
  String get lessThanDayLeft => 'Less than a day left';

  @override
  String get expired => 'Expired';

  @override
  String get noExpiry => 'No expiry';

  @override
  String get dataExhausted => 'Data exhausted';

  @override
  String amountLeft(Object amount) {
    return '$amount left';
  }

  @override
  String get unlimited => 'Unlimited';

  @override
  String get settings => 'Settings';

  @override
  String get routing => 'Routing';

  @override
  String get subscriptions => 'Subscriptions';

  @override
  String get home => 'Home';

  @override
  String get backToHome => 'Back to Home';

  @override
  String get settingsGroupSupport => 'Support';

  @override
  String get settingsGroupNetwork => 'Network';

  @override
  String get settingsGroupPreferences => 'Preferences';

  @override
  String get settingsCategory => 'Settings category';

  @override
  String helpFor(Object title) {
    return 'Help for $title';
  }

  @override
  String get importingEllipsis => 'Importing…';

  @override
  String get importAction => 'Import';

  @override
  String get importScanQr => 'Scan QR';

  @override
  String get importFromQrImage => 'From QR image';

  @override
  String get importFromClipboard => 'From clipboard';

  @override
  String get importFromFile => 'From file';

  @override
  String get liveCameraPreview => 'Live camera preview';

  @override
  String get scanQrCode => 'Scan QR code';

  @override
  String get cameraUnavailable =>
      'Camera unavailable. Check camera permissions and close other camera apps.';

  @override
  String get remindersUnavailable =>
      'Subscription reminders are unavailable. Check notification permissions.';

  @override
  String get appPreferencesNotSaved =>
      'Desktop preferences could not be saved.';

  @override
  String get appPreferencesNotLoaded =>
      'Desktop preferences could not be loaded.';

  @override
  String get openElarniLink => 'Open Elarni link?';

  @override
  String get select => 'Select';

  @override
  String daysLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days left',
      one: '1 day left',
    );
    return '$_temp0';
  }

  @override
  String get gibibytes => 'GiB';

  @override
  String get mebibytes => 'MiB';

  @override
  String get kibibytes => 'KiB';

  @override
  String bytesCount(String count) {
    return '$count bytes';
  }

  @override
  String get settingsGeneral => 'General';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsConnection => 'Connection';

  @override
  String get settingsAdvanced => 'Advanced';

  @override
  String get settingsServerTests => 'Server tests';

  @override
  String get settingsBackupAndRepair => 'Backup and repair';

  @override
  String get settingsSystemInfo => 'System info';

  @override
  String get settingsRouteTable => 'Route table';

  @override
  String get usageTime => 'Time';

  @override
  String get usageData => 'Data';

  @override
  String get desktopStatusNotUpdated => 'Desktop status could not be updated.';

  @override
  String get linkAsksDisconnect => 'A link asks Elarni to disconnect.';

  @override
  String get linkImportsRoutingProfile =>
      'A link wants to import a routing profile.';

  @override
  String get linkImportsClientProfile =>
      'A link wants to import a client profile.';

  @override
  String get disconnect => 'Disconnect';

  @override
  String appRoutingUses(String engine) {
    return 'App routing uses $engine. Unlisted apps connect directly in only-selected mode and follow normal routing in bypass mode. Traffic Elarni cannot link to an app (WSL, virtual machines, containers, connections that closed early) may come from a listed app: in only-selected mode it follows normal routing. Add Unidentified traffic to the list to choose where it goes.';
  }

  @override
  String get systemWideVpn => 'System-wide VPN';

  @override
  String get connectionMode => 'Connection mode';

  @override
  String get connectionModeHelp =>
      'System-wide VPN connects all apps; administrator approval is requested on the first VPN connection in this app session. System proxy points this computer\'s proxy setting at Elarni without administrator approval; only apps that follow it, such as browsers, use it. Local proxy only opens the ports below for apps you set up yourself.';

  @override
  String get connectionModeServiceHelp =>
      'System-wide VPN connects all apps; administrator approval is requested on the first VPN connection in this app session, unless Connect without administrator approval is on. System proxy points this computer\'s proxy setting at Elarni without administrator approval; only apps that follow it, such as browsers, use it. Local proxy only opens the ports below for apps you set up yourself.';

  @override
  String get systemProxy => 'System proxy';

  @override
  String get localProxyOnly => 'Local proxy only';

  @override
  String get systemProxyMode => 'System proxy mode';

  @override
  String get systemProxyListeners =>
      'In System proxy mode, apps on this computer use the HTTP port without a login.';

  @override
  String get updateDraft => 'Update draft';

  @override
  String get loadProfile => 'Load profile';

  @override
  String perAppProfileLoaded(Object platform) {
    return '$platform profile loaded. Review the apps and choose Save changes to apply.';
  }

  @override
  String get backToApps => 'Back to apps';

  @override
  String get routingProfileJson => 'Routing profile JSON';

  @override
  String get executableNamesOrPaths => 'Executable names or full paths';

  @override
  String loadRoutingProfileHelp(Object platform) {
    return 'Load a $platform routing profile into this draft. Save changes applies it.';
  }

  @override
  String get executableRulesHelp =>
      'One executable name or path per line, up to 256. A folder ending in / includes executables inside it.';

  @override
  String routingProfileContents(Object platform) {
    return 'Routing profiles contain only the mode, executable rules and app targets other than servers. Share with another $platform device; paths may need updating.';
  }

  @override
  String get appRoutingNotFirewall =>
      'DNS and local SOCKS/HTTP listeners keep their existing rules. App routing is not a firewall or a kill switch.';

  @override
  String get macMatchingHelp =>
      'Selecting an .app includes every executable inside its bundle. Other names and paths are case-sensitive.';

  @override
  String get windowsMatchingHelp =>
      'Windows matches .exe names and full paths case-insensitively. Select helper executables separately.';

  @override
  String get linuxMatchingHelp =>
      'Linux matches executable names and paths case-sensitively. Select helper processes separately.';

  @override
  String get pasteRoutingProfile => 'Paste routing profile';

  @override
  String get editExecutableRules => 'Edit executable rules';

  @override
  String get howAppRoutingWorks => 'How app routing works';

  @override
  String get done => 'Done';

  @override
  String get chooseAppFile => 'Choose app file';

  @override
  String get copyRoutingProfile => 'Copy routing profile';

  @override
  String perAppProfileCopied(Object platform) {
    return '$platform profile copied, including application names and paths.';
  }

  @override
  String get profileAndExecutableTools => 'Profile & executable tools';

  @override
  String get noMatchingApps => 'No matching apps.';

  @override
  String get noAppsFound => 'No apps found. Choose an app file below.';

  @override
  String get loadingApps => 'Loading apps…';

  @override
  String get installedAndRunningApps => 'Installed and running apps';

  @override
  String get refreshAppList => 'Refresh app list';

  @override
  String get searchApps => 'Search apps';

  @override
  String get addApps => 'Add apps';

  @override
  String get saveChanges => 'Save changes';

  @override
  String get perAppTargetsHelp =>
      'Each app can connect directly, follow your routing rules, be blocked, use a server from any subscription, or use a local SOCKS5 or HTTP proxy such as ByeByeDPI. VPN traffic only; DNS and local proxy rules are unchanged.';

  @override
  String get targetDirect => 'Direct';

  @override
  String get targetFollowRouting => 'Follow routing rules';

  @override
  String get otherApps => 'Other apps';

  @override
  String removeApp(Object name) {
    return 'Remove $name';
  }

  @override
  String get details => 'Details';

  @override
  String get executableRule => 'Executable rule';

  @override
  String get appBundleIncludesHelpers => 'App bundle · includes helpers';

  @override
  String get noAppsSelected =>
      'No apps selected. Add apps to create a routing rule.';

  @override
  String get selectedApps => 'Selected apps';

  @override
  String get perAppOnlySelected => 'Only selected';

  @override
  String get perAppBypassSelected => 'Bypass selected';

  @override
  String get perAppRouting => 'Per-app routing';

  @override
  String get perAppRoutingIntro =>
      'Choose which apps use the VPN. Applies to every subscription.';

  @override
  String get perAppOffHelp =>
      'All apps follow your routing rules. Your app selections are kept.';

  @override
  String get perAppOnlyHelp =>
      'Selected apps follow your routing rules unless you choose another target for them. All other apps connect directly.';

  @override
  String get perAppBypassHelp =>
      'Selected apps connect directly unless you choose another target for them. Other apps follow your routing rules.';

  @override
  String get macRulesCaseSensitive =>
      'Names and paths are case-sensitive. A path ending in / includes executables inside that folder.';

  @override
  String get macBundleRuleHelp =>
      'This rule includes every executable inside the app bundle.';

  @override
  String get windowsRulesCaseInsensitive =>
      'Executable names and paths are case-insensitive. Select other helper executables separately.';

  @override
  String get linuxRulesCaseSensitive =>
      'Names and paths are case-sensitive. Select any helper executables separately.';

  @override
  String get appListUnavailable =>
      'The app list is unavailable. Choose an app file or edit executable rules.';

  @override
  String get closeAppChooser => 'Close app chooser';

  @override
  String get localProxyEllipsis => 'Local proxy…';

  @override
  String get targetMissingServer => 'Missing server';

  @override
  String targetServer(Object name) {
    return 'Server · $name';
  }

  @override
  String targetLocalProxy(Object address) {
    return 'Local proxy · $address';
  }

  @override
  String get perAppOperationFailed =>
      'The operation failed. Try again; your draft is kept.';

  @override
  String get perAppLauncherRule =>
      'Snap, Flatpak and script launchers start another program, so their rules match nothing. Choose the app from the app list; start a Snap or script app first.';

  @override
  String get useProxy => 'Use proxy';

  @override
  String get proxyAddress => 'Proxy address';

  @override
  String get localProxyHelp =>
      'Another app\'s SOCKS5 or HTTP proxy, such as ByeByeDPI.';

  @override
  String get localProxy => 'Local proxy';

  @override
  String perAppOtherPlatformProfile(Object profilePlatform, Object platform) {
    return 'This is a $profilePlatform profile. Import a $platform profile or select the apps on this device.';
  }

  @override
  String get perAppUnsupportedProfile => 'Unsupported per-app routing profile.';

  @override
  String get perAppProfileTooLarge => 'The profile exceeds 512 KB.';

  @override
  String get perAppUnixPathsOnWindows =>
      'macOS or Unix executable paths cannot be used in a Windows profile. Select the apps on this PC.';

  @override
  String get perAppMacBundlesOnLinux =>
      'macOS app bundles cannot be used in a Linux profile. Select the Linux executables.';

  @override
  String perAppWindowsPathsElsewhere(Object platform) {
    return 'Windows executable paths cannot be used in a $platform profile. Select the apps on this device.';
  }

  @override
  String perAppLinuxRulesElsewhere(Object platform) {
    return 'Flatpak and AppImage rules name Linux apps and cannot be used in a $platform profile.';
  }

  @override
  String perAppServiceRulesElsewhere(Object platform) {
    return 'Service rules name Windows services and cannot be used in a $platform profile.';
  }

  @override
  String get perAppFlatpakRule =>
      'Flatpak app: also its other programs in the sandbox';

  @override
  String get perAppAppImageRule => 'AppImage: the programs in that image file';

  @override
  String get perAppServiceRule =>
      'Windows service: also the services that share its process';

  @override
  String get perAppKindService => 'Windows service';

  @override
  String get perAppIncludeChildren => 'Include programs it starts';

  @override
  String get perAppIncludeChildrenHelp =>
      'Also routes the programs this app starts, and theirs, such as helpers, updaters and command-line tools. A program listed on its own keeps its own target. A browser the app starts is included too, but not one that was already running.';

  @override
  String get perAppWithChildren => 'with the programs it starts';

  @override
  String get perAppPresets => 'Presets';

  @override
  String get perAppPresetSteam => 'Steam and games';

  @override
  String get perAppPresetBrowsers => 'Browsers';

  @override
  String get perAppPresetAdded => 'Added';

  @override
  String get perAppPresetNotFound => 'Not found';

  @override
  String get perAppPresetWithChildren => 'With the programs it starts';

  @override
  String get perAppPresetsHelp =>
      'A preset offers the apps the app list found, each with the rule this computer gives it. For an app it does not find, use Choose app file.';

  @override
  String perAppAddPresetApps(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Add $count apps',
      one: 'Add 1 app',
    );
    return '$_temp0';
  }

  @override
  String perAppConnectionStartedBy(String name) {
    return 'Started by $name';
  }

  @override
  String get perAppAndroidPackages =>
      'Use Android package names such as com.example.app. Select the apps on this device.';

  @override
  String get perAppInvalidProfile =>
      'Use a supported mode and up to 256 names or paths, each at most 1024 bytes without control characters, with targets only for listed apps. An active mode needs at least one app.';

  @override
  String get perAppUnsupportedPlatform => 'Unsupported profile platform.';

  @override
  String get targetBlock => 'Block';

  @override
  String get validateAndSave => 'Validate and save';

  @override
  String get rulesTab => 'Rules';

  @override
  String get routingAndDns => 'Routing and DNS';

  @override
  String get reduceRoutingDataHelp =>
      'Applied when routing data refreshes. Keeps complete matching records and preserves originals; falls back to full files on failure.';

  @override
  String get reduceRoutingDataSize => 'Reduce routing-data size';

  @override
  String get resolveWhenNeeded => 'Resolve when needed';

  @override
  String get resolveIfNoRuleMatches => 'Resolve if no rule matches';

  @override
  String get keepDomainNames => 'Keep domain names';

  @override
  String get resolveDomainsForRouting => 'Resolve domains for routing';

  @override
  String get ruleGroupOrder => 'Rule group order';

  @override
  String get profileName => 'Profile name';

  @override
  String get directDnsDomainsHint =>
      'One domain, domain: suffix, full: name, or geosite: tag per line.';

  @override
  String get domainsUsingDirectDns => 'Domains using direct DNS';

  @override
  String get explicitDomainRulesHelp =>
      'Matching domains use direct DNS; all others use remote DNS. Off preserves legacy ordered fallback. DoH bootstrap connects through the selected proxy.';

  @override
  String get useExplicitDomainRules => 'Use explicit domain rules';

  @override
  String get chooseDnsByDomain => 'Choose DNS by domain';

  @override
  String get resolverIp => 'Resolver IP';

  @override
  String get bootstrapIp => 'Bootstrap IP';

  @override
  String get resolverType => 'Resolver type';

  @override
  String get remoteDns => 'Remote DNS';

  @override
  String get directDns => 'Direct DNS';

  @override
  String get keepDomainIdentityHelp =>
      'Uses Fake DNS. With real DNS, domain rules depend on supported HTTP/TLS/QUIC sniffing; encrypted hostnames and other protocols may require IP rules.';

  @override
  String get keepDomainIdentity => 'Keep domain identity for routing';

  @override
  String get ipRulesHint =>
      'One IPv4/IPv6 address, CIDR, or geoip: target per line.';

  @override
  String get ipAddressesAndNetworks => 'IP addresses and networks';

  @override
  String get domainRulesHint =>
      'One domain, full:, domain:, regexp:, or geosite: target per line.';

  @override
  String get domains => 'Domains';

  @override
  String get addPreset => 'Add preset';

  @override
  String get russianSitesPresetHelp =>
      '.ru, .рф, .su and these services\' other domains';

  @override
  String get russianSitesDirect => 'Russian sites direct';

  @override
  String get connectDirectly => 'Connect directly';

  @override
  String get unmatchedTraffic => 'Unmatched traffic';

  @override
  String get routingChangeFailed =>
      'Routing change failed. The last working profile was kept.';

  @override
  String routingIpTargetsInvalid(String field) {
    return '$field needs IP addresses, valid CIDRs, or geoip: references.';
  }

  @override
  String routingDnsNeedsResolver(String dns) {
    return '$dns needs a resolver type and IP address.';
  }

  @override
  String routingDnsNeedsHttpsUrl(String dns) {
    return '$dns needs an HTTPS URL without credentials or a fragment.';
  }

  @override
  String get domesticDns => 'Domestic DNS';

  @override
  String get directRules => 'Direct rules';

  @override
  String get proxyRules => 'Proxy rules';

  @override
  String get blockRules => 'Block rules';

  @override
  String get ruleGroupBlock => 'Block';

  @override
  String get ruleGroupDirect => 'Direct';

  @override
  String get ruleGroupProxy => 'Proxy';

  @override
  String get httpsUrl => 'HTTPS URL';

  @override
  String get routingProfilesNotLoaded =>
      'Routing profiles could not be loaded.';

  @override
  String get connectionStoppedUnexpectedly =>
      'Connection stopped unexpectedly. Reconnect to retry.';

  @override
  String get groupSelectionFailed =>
      'Group selection failed. The saved selection was restored.';

  @override
  String get serverIpPreferenceNotApplied =>
      'Could not apply the server IP preference.';

  @override
  String get telegramNotOpened =>
      'Telegram could not be opened. Check that it is installed.';

  @override
  String get couldNotImport =>
      'Could not import. Use a subscription link, client configuration, or routing profile.';

  @override
  String get selectServerFirstRoutingLink =>
      'Select a server first. This routing link turns its profile on for the selected server’s subscription.';

  @override
  String get unsupportedProfileTryJson =>
      'This profile uses unsupported settings. Try the provider’s Xray JSON format.';

  @override
  String get subscriptionAddedFirstDownloadFailed =>
      'Subscription added, but the first download failed. Refresh to retry.';

  @override
  String get clipboardEmpty =>
      'The clipboard is empty. Copy a link or configuration first.';

  @override
  String get downloadPageNotOpened => 'The download page could not be opened.';

  @override
  String get providerLinkNotOpened => 'The provider link could not be opened.';

  @override
  String get continueAction => 'Continue';

  @override
  String get approveUnsafeSubscription => 'Approve unsafe subscription?';

  @override
  String get contactProvider => 'Contact provider';

  @override
  String get vpnSetupNotRepaired => 'VPN setup could not be repaired.';

  @override
  String get vpnSetupReset => 'VPN setup reset. Connect to try again.';

  @override
  String get repair => 'Repair';

  @override
  String get repairVpnMacBody =>
      'Stops the connection and removes the saved macOS VPN setup. Connect recreates it using your selected server and settings.';

  @override
  String get repairVpnDesktopBody =>
      'Stops the connection and closes the tunnel helper. On Windows it also removes a DNS block left by a helper that stopped unexpectedly, which asks for administrator permission. The next VPN connection starts a fresh helper and may ask for it too.';

  @override
  String get repairVpnSetupQuestion => 'Repair VPN setup?';

  @override
  String get favoriteNotSaved => 'The favorite could not be saved. Try again.';

  @override
  String get subscriptionsNotLoaded => 'Subscriptions could not be loaded.';

  @override
  String get hideVpnIconBody =>
      'This changes excluded network routes; it does not only hide interface chrome.';

  @override
  String get hideVpnIconQuestion => 'Hide VPN icon?';

  @override
  String settingNotApplied(Object details) {
    return 'Setting could not be applied. $details';
  }

  @override
  String get settingNotAppliedCheck =>
      'Setting could not be applied. Check the current settings and tunnel state before reconnecting.';

  @override
  String get settingsReloaded =>
      'Settings were reloaded. Make the change again.';

  @override
  String get pingFailedForNode => 'Ping failed for this node.';

  @override
  String get pingIcmpRestoreFailed =>
      'ICMP finished, but the previous tunnel connection could not be restored.';

  @override
  String get pingIcmpNoReplyRestored =>
      'No ICMP reply. The previous tunnel connection was restored.';

  @override
  String get pingIcmpUnavailable =>
      'ICMP is unavailable while system VPN is connected. Use TCP or HTTP testing.';

  @override
  String get pingDirectTcpUnsupported =>
      'Skipped: Direct TCP is not supported by this endpoint’s transport. Use Proxy testing.';

  @override
  String get pingNeedsDisconnect =>
      'Skipped: while connected, this test can’t reach the server. Disconnect to test it.';

  @override
  String get routeTableUnreadable =>
      'The current route table could not be read.';

  @override
  String get systemInfoUnavailable => 'System information is unavailable.';

  @override
  String get systemSettingsNotLoaded => 'System settings could not be loaded.';

  @override
  String get allowWithoutLogin => 'Allow without login';

  @override
  String allowWithoutLoginBody(Object ports) {
    return 'In local-proxy mode, any program on this device, including malware and other users\' programs, can then send traffic through your server on $ports. LAN access turns off.';
  }

  @override
  String get allowAppsWithoutLogin => 'Allow apps without a login?';

  @override
  String portSingle(Object port) {
    return 'port $port';
  }

  @override
  String portsPair(Object socks, Object http) {
    return 'ports $socks and $http';
  }

  @override
  String get tunnelSettingsNotLoaded => 'Tunnel settings could not be loaded.';

  @override
  String get chooseWritableLocation => 'Choose a writable location and retry.';

  @override
  String get diagnosticsNotSaved => 'Diagnostics could not be saved.';

  @override
  String pingTested(int tested, int total) {
    return 'Tested $tested of $total nodes.';
  }

  @override
  String pingSkippedIncompatible(int count) {
    return 'Skipped $count: incompatible with this test method.';
  }

  @override
  String pingSkippedWhileConnected(int count) {
    return 'Skipped $count: disconnect to test them.';
  }

  @override
  String get refreshFailedSentence => 'Refresh failed.';

  @override
  String get lastWorkingServersKept => 'The last working servers were kept.';

  @override
  String get catalogLimit =>
      'Elarni keeps up to 1,024 subscriptions and 256 routing profiles. Delete some, then retry.';

  @override
  String get dismissMessage => 'Dismiss message';

  @override
  String get addSubscriptionToStart =>
      'Add a subscription or import a profile to get started.';

  @override
  String get noSubscriptionsYet => 'No subscriptions yet';

  @override
  String get refreshProfiles => 'Refresh profiles';

  @override
  String get routeTableHelp => 'Current numeric IPv4 and IPv6 routes.';

  @override
  String get openServerList => 'Open server list';

  @override
  String get expectedBodyHelp =>
      'Exact text; leave empty for HTTP 204 or HEAD.';

  @override
  String get expectedResponseBody => 'Expected response body';

  @override
  String get testUrl => 'Test URL';

  @override
  String get httpRequest => 'HTTP request';

  @override
  String secondsTimeout(Object seconds) {
    return '$seconds s timeout';
  }

  @override
  String get timeout => 'Timeout';

  @override
  String get testMode => 'Test mode';

  @override
  String get httpMethod => 'HTTP method';

  @override
  String get currentRulesActiveTunnel => 'Current rules / active tunnel';

  @override
  String get testType => 'Test type';

  @override
  String get refreshingEllipsis => 'Refreshing…';

  @override
  String get refresh => 'Refresh';

  @override
  String get exportDiagnostics => 'Export diagnostics';

  @override
  String get troubleshootConnection => 'Troubleshoot connection';

  @override
  String get versions => 'Versions';

  @override
  String xrayCoreVersion(Object version) {
    return 'Xray core $version';
  }

  @override
  String get unavailable => 'Unavailable';

  @override
  String get physicalMemory => 'Physical memory';

  @override
  String get activeCpus => 'Active CPUs';

  @override
  String get cpuCount => 'CPU count';

  @override
  String get appArchitecture => 'App architecture';

  @override
  String get operatingSystem => 'Operating system';

  @override
  String get repairVpnSetup => 'Repair VPN setup';

  @override
  String get reviewRepair => 'Review repair';

  @override
  String get connectionRepair => 'Connection repair';

  @override
  String get restoreBackupHelp =>
      'Disconnect before replacing saved profiles and routing.';

  @override
  String get restoreBackup => 'Restore backup';

  @override
  String get restore => 'Restore';

  @override
  String get createEncryptedBackup => 'Create encrypted backup';

  @override
  String get export => 'Export';

  @override
  String get backups => 'Backups';

  @override
  String get showMonitoringOnMain => 'Show monitoring on main screen';

  @override
  String get monitoring => 'Monitoring';

  @override
  String get enableSniffing => 'Enable sniffing';

  @override
  String get udpMaxConnections => 'UDP max connections';

  @override
  String get tcpMaxConnections => 'TCP max connections';

  @override
  String get connectionIdleTimeout => 'Connection idle timeout (seconds)';

  @override
  String get xrayMemoryLimit => 'Xray memory limit (MB)';

  @override
  String get resources => 'Resources';

  @override
  String get defaultMuxHelp =>
      'Imported mux settings take precedence. This preference applies only to VLESS; it does not enable mux for Hysteria.';

  @override
  String get enableDefaultVlessMux => 'Enable default VLESS mux';

  @override
  String fragmentationSummary(Object packets, Object length, Object interval) {
    return '$packets · $length bytes · $interval ms';
  }

  @override
  String get fragmentationOptions => 'Fragmentation options';

  @override
  String get edit => 'Edit';

  @override
  String get fragmentationHelp =>
      'VLESS over TCP or XHTTP with TLS or Reality. XHTTP over HTTP/3 and existing dialer chains are unsupported.';

  @override
  String get enableFragmentation => 'Enable fragmentation';

  @override
  String get transport => 'Transport';

  @override
  String get resolveServerHelp =>
      'Keeps server IP addresses fixed until reconnect while preserving TLS names and transport headers.';

  @override
  String get resolveServerBeforeConnecting =>
      'Resolve server before connecting';

  @override
  String get noEnabledRoutingProfiles =>
      'No enabled routing profiles. Enable a profile in Routing.';

  @override
  String get editDns => 'Edit DNS';

  @override
  String get routingProfiles => 'Routing profiles';

  @override
  String get routingProfile => 'Routing profile';

  @override
  String get providerProfile => 'Provider profile';

  @override
  String get dnsSettingsHelp => 'Choose which profile supplies DNS settings.';

  @override
  String get dnsSettings => 'DNS settings';

  @override
  String get allowLanHelp =>
      'Requires authentication. Use a trusted LAN: SOCKS5 and HTTP authentication do not encrypt the client connection.';

  @override
  String get allowLan => 'Allow LAN connections (IPv4)';

  @override
  String get requireProxyAuthHelp =>
      'Both listeners use the saved credentials. Disabling authentication also disables LAN access.';

  @override
  String get requireProxyAuth => 'Require SOCKS5 and HTTP authentication';

  @override
  String get allowAppsWithoutLoginHelp =>
      'In local-proxy mode, any program on this device could then use your proxy and your server. With the VPN on, the listeners still need a login. Also disables LAN access.';

  @override
  String get allowAppsWithoutLoginToggle => 'Allow apps without a login';

  @override
  String get set => 'Set';

  @override
  String get change => 'Change';

  @override
  String get hide => 'Hide';

  @override
  String get show => 'Show';

  @override
  String get notConfigured => 'Not configured';

  @override
  String get proxyLoginHelp =>
      'Apps that use the SOCKS5 or HTTP proxy sign in with this username and password.';

  @override
  String get proxyLogin => 'Proxy login';

  @override
  String get listenersHelp =>
      'Listeners run while the tunnel is active on either backend. With the VPN on they always require a login: your saved credentials when authentication is on, otherwise a random one per connection, so other apps cannot use them.';

  @override
  String get socksAndHttpPorts => 'SOCKS5 and HTTP ports';

  @override
  String get httpInbound => 'HTTP inbound';

  @override
  String get useAppDefault => 'Use app default';

  @override
  String get serverIpType => 'Server IP type';

  @override
  String get shareLinkServers => 'Share-link servers';

  @override
  String get defaultIpTypeHelp => 'Used by servers without an override.';

  @override
  String get defaultIpType => 'Default IP type';

  @override
  String get serverAddressing => 'Server addressing';

  @override
  String get blockTrafficMacHelp =>
      'macOS keeps all traffic inside the tunnel, including while it reconnects. Route exclusions do not apply.';

  @override
  String get blockTrafficDesktopHelp =>
      'If the VPN stops unexpectedly, nothing leaves this device outside it until you reconnect or use Repair VPN setup. Disconnecting lifts the block. Needs System-wide VPN; cannot be combined with Enforce tunnel routes.';

  @override
  String get blockTrafficWithoutVpn => 'Block traffic without VPN';

  @override
  String get connectWithoutAdminApprovalHelp =>
      'The Elarni VPN service starts the VPN helper for this Windows account, so connecting asks for no approval. Turning this on or off asks for approval once.';

  @override
  String get connectWithoutAdminApproval =>
      'Connect without administrator approval';

  @override
  String get accentColor => 'Accent color';

  @override
  String get dark => 'Dark';

  @override
  String get light => 'Light';

  @override
  String get followSystem => 'Follow system';

  @override
  String get theme => 'Theme';

  @override
  String get language => 'Language';

  @override
  String get languageName => 'English';

  @override
  String get feedUnreadable => 'The feed could not be read.';

  @override
  String get upToDate => 'Up to date';

  @override
  String updateAvailable(Object version) {
    return 'Elarni $version is available';
  }

  @override
  String get updateFeedHelp =>
      'Elarni reads this address once a day and shows a notice on Home when it names a newer release. It never downloads or installs anything. Use a JSON file with \"version\" and \"url\", or a GitHub releases/latest API address; https only.';

  @override
  String get updateFeed => 'Update feed';

  @override
  String get updates => 'Updates';

  @override
  String get favoritesFirst => 'Favorites first';

  @override
  String get alphabetical => 'Alphabetical';

  @override
  String get providerOrder => 'Provider order';

  @override
  String get serverOrder => 'Server order';

  @override
  String get subscriptionExpiryRemindersHelp =>
      'Once a day while Elarni is running, when a subscription expires within three days.';

  @override
  String get subscriptionExpiryReminders => 'Subscription expiry reminders';

  @override
  String get subscriptionAutoUpdateHelp =>
      'Updates all subscriptions while Elarni is running. Default: 4 hours.';

  @override
  String get subscriptionAutoUpdateHours => 'Subscription auto-update (hours)';

  @override
  String get macDisconnectsWhenSleeping => 'macOS disconnects when sleeping.';

  @override
  String disconnectsWhenSleeps(Object platform) {
    return 'Disconnects when $platform sleeps.';
  }

  @override
  String get disconnectOnSleep => 'Disconnect on sleep';

  @override
  String get loginStateUnavailable => 'Registration state is unavailable.';

  @override
  String get loginApprovalRequired =>
      'Approval is required in macOS Login Items settings.';

  @override
  String get launchAtLogin => 'Launch app at login';

  @override
  String get windowsWifiLocationHelp =>
      'Windows keeps the Wi-Fi name from Elarni. Turn on Location services and Let desktop apps access your location in Settings › Privacy & security › Location.';

  @override
  String get noTrustedWifi => 'None. Every Wi-Fi network connects.';

  @override
  String get trustedWifiNetworks => 'Trusted Wi-Fi networks';

  @override
  String get untrustedWifiMacHelp =>
      'Joining a Wi-Fi network that is not on your trusted list connects, even before you press Connect. Trusted networks and wired connections leave the VPN as it is. Disconnect pauses this until your next Connect.';

  @override
  String get untrustedWifiDesktopHelp =>
      'Joining a Wi-Fi network that is not on your trusted list connects. Trusted networks, wired and mobile connections, and a connection you stopped stay as they are until the next network.';

  @override
  String get connectOnUntrustedWifi => 'Connect on untrusted Wi-Fi';

  @override
  String get onDemandMacHelp =>
      'On Demand controls automatic connection when network access resumes.';

  @override
  String get onDemand => 'On Demand';

  @override
  String get recoveryBackupsSummary => 'Use only your allowed backup servers.';

  @override
  String get recoveryFixedSummary => 'Reconnect to the selected server only.';

  @override
  String get recoveryOffSummary => 'Off. Your server choice is preserved.';

  @override
  String get configure => 'Configure';

  @override
  String get none => 'None';

  @override
  String get excludedRoutes => 'Excluded routes';

  @override
  String get includedRoutes => 'Included routes';

  @override
  String get compatibilityRouteExclusionsHelp =>
      'Adds route exclusions used by the hide-icon workaround. Hiding the VPN icon is not verified.';

  @override
  String get compatibilityRouteExclusions => 'Compatibility route exclusions';

  @override
  String get includeAllNetworksHelp =>
      'VPN routes apply in System VPN mode. Include all networks captures both IP families and respects your exclusions.';

  @override
  String get includeAllNetworks => 'Include all networks';

  @override
  String get enforceRoutesMacHelp =>
      'Enforcement requires specific included routes; default routes such as 0.0.0.0/0 and ::/0 are unsupported. For a full tunnel, turn enforcement off and use Block traffic without VPN in Connection settings.';

  @override
  String get enforceRoutesDesktopHelp =>
      'VPN routes apply in System VPN mode. Enforcement blocks physical bypass of specific included routes while connected.';

  @override
  String get enforceTunnelRoutes => 'Enforce tunnel routes';

  @override
  String get advancedNetworkRoutes => 'Advanced network routes';

  @override
  String get memoryLimitAutomatic => 'automatic';

  @override
  String megabytesValue(String value) {
    return '$value MB';
  }

  @override
  String gigabytesValue(String value) {
    return '$value GB';
  }

  @override
  String extensionMemory(String value) {
    return 'Extension RSS: $value MB';
  }

  @override
  String xrayHeap(String heap, String limit) {
    return 'Xray heap: $heap MB / $limit';
  }

  @override
  String get softLimit => '(soft limit)';

  @override
  String sessionsSummary(Object tcp, Object udp) {
    return 'Sessions: $tcp TCP / $udp UDP';
  }

  @override
  String trafficSummary(Object up, Object down) {
    return 'Traffic: $up up / $down down bytes';
  }

  @override
  String packetsSummary(Object incoming, Object outgoing) {
    return 'Packets: $incoming in / $outgoing out';
  }

  @override
  String listenersSummary(String scope, Object socks, String http) {
    return 'Configured $scope: SOCKS5 $socks; HTTP $http.';
  }

  @override
  String get listenLan => 'LAN IPv4';

  @override
  String get listenLoopback => 'loopback';

  @override
  String get httpOff => 'off';

  @override
  String get testModeDouble => 'Double';

  @override
  String get testModeDefault => 'Default';

  @override
  String get proxyHead => 'Proxy HEAD';

  @override
  String get proxyGet => 'Proxy GET';

  @override
  String get directIcmp => 'Direct ICMP';

  @override
  String get directTcp => 'Direct TCP';

  @override
  String get testThroughProxy => 'Proxy';

  @override
  String get automatic => 'Automatic';

  @override
  String get useProfile => 'Use profile';

  @override
  String get loginServiceNotFound =>
      'macOS could not find this app as a login service.';

  @override
  String get loginNotRegistered => 'Not registered.';

  @override
  String get loginRegistered => 'Registered for your account.';

  @override
  String get searchServers => 'Search servers';

  @override
  String get filterRecent => 'Recent';

  @override
  String get filterFavorites => 'Favorites';

  @override
  String get filterAll => 'All';

  @override
  String get servers => 'Servers';

  @override
  String get showAgain => 'Show again';

  @override
  String hiddenServersCount(int count) {
    return 'Hidden servers · $count';
  }

  @override
  String get noMatchingServers => 'No matching servers';

  @override
  String get noServersInSubscription => 'No servers in this subscription';

  @override
  String get delete => 'Delete';

  @override
  String get selectUnreachable => 'Select unreachable';

  @override
  String selectedCount(int count) {
    return '$count selected';
  }

  @override
  String get setByYourProvider => 'Set by your provider';

  @override
  String get noCustomRouting => 'No custom routing';

  @override
  String refreshNamed(Object name) {
    return 'Refresh $name';
  }

  @override
  String get accountDisabled => 'Account disabled';

  @override
  String get rename => 'Rename';

  @override
  String get shareLinksFormat => 'Share links';

  @override
  String get originalSubscription => 'Original subscription';

  @override
  String get subscriptionFormat => 'Subscription format';

  @override
  String get downloadOptions => 'Download options';

  @override
  String get shareSubscription => 'Share subscription';

  @override
  String get accountDetails => 'Account details';

  @override
  String get providerSupport => 'Provider support';

  @override
  String get pinSubscription => 'Pin subscription';

  @override
  String get unpinSubscription => 'Unpin subscription';

  @override
  String get subscriptionActions => 'Subscription actions';

  @override
  String get testSubscriptionNodes => 'Test this subscription’s nodes';

  @override
  String get testAllNodes => 'Test all nodes';

  @override
  String get useNodePingForIcmp => 'Use a node’s Ping button for ICMP';

  @override
  String get testing => 'Testing…';

  @override
  String get otherLocations => 'Other locations';

  @override
  String lowestLatencySemantics(int ms) {
    String _temp0 = intl.Intl.pluralLogic(
      ms,
      locale: localeName,
      other: 'Lowest latency: $ms milliseconds',
    );
    return '$_temp0';
  }

  @override
  String get clearSearch => 'Clear search';

  @override
  String get noServersYet => 'No servers yet';

  @override
  String get showAllServers => 'Show all servers';

  @override
  String get noSuccessfulConnections => 'No successful connections yet';

  @override
  String get noFavoriteServers => 'No favorite servers';

  @override
  String get onboardingStep3Proxy =>
      'Press Connect. Only apps set to use the local proxy go through it; turn on System-wide VPN in Settings > Connection to connect all apps.';

  @override
  String get onboardingStep3Vpn =>
      'Press Connect. Administrator approval is requested on the first VPN connection in this app session.';

  @override
  String get onboardingStep3Mac =>
      'Press Connect. macOS asks once to allow the VPN configuration.';

  @override
  String get openFile => 'Open file';

  @override
  String get pasteLink => 'Paste link';

  @override
  String get onboardingStep2 => 'Add it here.';

  @override
  String get onboardingStep1 =>
      'Get a subscription link or QR code from your provider. Elarni has no servers of its own.';

  @override
  String get onboardingTitle => 'Get connected in three steps';

  @override
  String get serverActions => 'Server actions';

  @override
  String get open => 'Open';

  @override
  String get openInTelegram => 'Open in Telegram';

  @override
  String get checkExit => 'Check exit';

  @override
  String get checking => 'Checking…';

  @override
  String get serverConfig => 'Server config';

  @override
  String exitMismatch(Object server, Object named, Object exit) {
    return '$server\'s name says $named, but its exit is in $exit.';
  }

  @override
  String get addFavorite => 'Add favorite';

  @override
  String get removeFavorite => 'Remove favorite';

  @override
  String get unknownLocation => 'Unknown location';

  @override
  String selectNamed(Object name) {
    return 'Select $name';
  }

  @override
  String get deleteServer => 'Delete server';

  @override
  String get hideServer => 'Hide server';

  @override
  String get renameServer => 'Rename server';

  @override
  String get ping => 'Ping';

  @override
  String get skipped => 'Skipped';

  @override
  String get localProxyMode => 'Local proxy mode';

  @override
  String get selectServerToConnect => 'Select a server to get connected.';

  @override
  String get chooseServer => 'Choose a server';

  @override
  String get stateConnectionFailed => 'Connection failed';

  @override
  String get stateReconnecting => 'Reconnecting…';

  @override
  String get stateDisconnecting => 'Disconnecting…';

  @override
  String get stateConnectedNoTraffic => 'Connected · no traffic';

  @override
  String get stateConnected => 'Connected';

  @override
  String get stateConnecting => 'Connecting…';

  @override
  String get statePreparing => 'Preparing…';

  @override
  String get stateReadyToConnect => 'Ready to connect';

  @override
  String get stateDisconnected => 'Disconnected';

  @override
  String get connectionStatusUnavailable => 'Connection status unavailable';

  @override
  String get connect => 'Connect';

  @override
  String get notNow => 'Not now';

  @override
  String get download => 'Download';

  @override
  String get requireLogin => 'Require a login';

  @override
  String get anyProgramCanUseProxy => 'Any program on this device can use it.';

  @override
  String get localProxyWithoutLogin =>
      'Your local proxy accepts apps without a login';

  @override
  String get liftBlock => 'Lift block';

  @override
  String get reconnect => 'Reconnect';

  @override
  String get connectionStoppedUnexpectedlyShort =>
      'The connection stopped unexpectedly.';

  @override
  String get trafficBlockedUntilReconnect =>
      'Traffic blocked until you reconnect';

  @override
  String deleteProfileAndRulesQuestion(Object name) {
    return 'Delete $name and its rules?';
  }

  @override
  String get deleteRoutingProfileQuestion => 'Delete routing profile?';

  @override
  String get reset => 'Reset';

  @override
  String replaceEditsQuestion(Object name) {
    return 'Replace your edits to $name with the subscription version?';
  }

  @override
  String get resetRoutingProfileQuestion => 'Reset routing profile?';

  @override
  String get resetToSubscriptionVersion => 'Reset to subscription version';

  @override
  String get duplicate => 'Duplicate';

  @override
  String get editJson => 'Edit JSON';

  @override
  String get refreshRoutingData => 'Refresh routing data';

  @override
  String get profileDetails => 'Profile details';

  @override
  String get editRoutingAndDns => 'Edit routing and DNS';

  @override
  String actionsFor(Object name) {
    return 'Actions for $name';
  }

  @override
  String enableProfile(Object name) {
    return 'Enable $name';
  }

  @override
  String get managedListsNeedAttention => 'Managed lists need attention';

  @override
  String get downloadNeedsAttention => 'Download needs attention';

  @override
  String get otherProfiles => 'Other profiles';

  @override
  String get routingEmptyHelp =>
      'Use Import to add a routing file, link, or QR code.';

  @override
  String get noRoutingProfiles => 'No routing profiles';

  @override
  String get deviceIdHelp =>
      'Elarni sends each provider a different device ID, made from a random key on this device. Providers can\'t link your IDs to each other. A renamed subscription, a changed refresh interval and your routing choice stay after a refresh.';

  @override
  String get registeredByProvider => 'Registered · set by your provider';

  @override
  String get loading => 'Loading';

  @override
  String get deviceId => 'Device ID';

  @override
  String everyHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Every $hours h',
    );
    return '$_temp0';
  }

  @override
  String get refreshes => 'Refreshes';

  @override
  String get appSetting => 'App setting';

  @override
  String get yourOverride => 'Your override';

  @override
  String get updated => 'Updated';

  @override
  String get providerNotice => 'Provider notice';

  @override
  String get providerAsksKeepSettings =>
      'Your provider asks you to keep its settings. You can still change them.';

  @override
  String get providerRouting => 'Provider routing';

  @override
  String get providerRoutingDisabled => 'Disabled';

  @override
  String get expires => 'Expires';

  @override
  String get quota => 'Quota';

  @override
  String get dataUsed => 'Data used';

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get providerStatus => 'Provider status';

  @override
  String get detailAccount => 'Account';

  @override
  String get accountDisabledValue => 'Disabled';

  @override
  String get detailInformation => 'Information';

  @override
  String get lastReportedProviderInfo => 'Last reported provider information';

  @override
  String get statusReady => 'Ready';

  @override
  String get statusDeviceLimit => 'Provider device limit reached';

  @override
  String get statusDeviceRequired => 'Provider requires device registration';

  @override
  String get statusRefreshing => 'Refreshing';

  @override
  String get refreshFailed => 'Refresh failed';

  @override
  String get statusApprovalRequired => 'Approval required';

  @override
  String get riskPrivateTarget =>
      'This subscription connects to a private or link-local network.';

  @override
  String get riskLoopbackTarget =>
      'This subscription connects to this computer.';

  @override
  String get riskCleartextHttp =>
      'This subscription uses an unencrypted HTTP connection.';

  @override
  String get connectionNotChecked => 'Connection has not been checked';

  @override
  String get trafficPassesThroughServer => 'Traffic passes through the server';

  @override
  String get recoveryInProgress => 'Recovery in progress…';

  @override
  String get automaticChecksUnavailable =>
      'Automatic checks unavailable for this routing setup';

  @override
  String get automaticCheckFailed => 'Automatic connection check failed';

  @override
  String get latestAutomaticCheckPassed => 'Latest automatic check passed';

  @override
  String get automaticTrafficChecksUnavailable =>
      'Automatic traffic checks unavailable for this routing setup';

  @override
  String serverPassedNoTraffic(Object time) {
    return 'The server passed no traffic at $time. Checking again each minute.';
  }

  @override
  String get connectionCheckUnavailable =>
      'Connection check unavailable for this routing setup';

  @override
  String get checkingConnection => 'Checking connection…';

  @override
  String lastKnownState(Object state) {
    return 'Last known state: $state';
  }

  @override
  String get refreshStatusToCheck => 'Refresh status to check the connection';

  @override
  String get whitelistModeRussianFirst =>
      'Whitelist mode: Russian-entry servers first';

  @override
  String staleHttpCheckAt(String time) {
    return 'Stale HTTP check at $time';
  }

  @override
  String connectionCheckPassedAt(String time) {
    return 'Connection check passed at $time';
  }

  @override
  String connectionCheckFailedAt(String time) {
    return 'Connection check failed at $time';
  }

  @override
  String get probeTcpEndpoint => 'TCP endpoint';

  @override
  String get probeIcmpEndpoint => 'ICMP endpoint';

  @override
  String get probeActiveConnectionHttp => 'Active connection HTTP';

  @override
  String get probeProxyHttp => 'Proxy HTTP';

  @override
  String get timeUnavailable => 'time unavailable';

  @override
  String secondsAgo(int seconds) {
    return '${seconds}s ago';
  }

  @override
  String minutesAgo(int minutes) {
    return '${minutes}m ago';
  }

  @override
  String get stale => 'stale';

  @override
  String connectedAt(String when) {
    return 'Connected $when';
  }

  @override
  String get configurationChanged => 'configuration changed';

  @override
  String get shortMonths => 'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec';

  @override
  String expiredOn(String date) {
    return 'expired $date';
  }

  @override
  String expiresOn(String date) {
    return 'expires $date';
  }

  @override
  String get exhausted => 'Exhausted';

  @override
  String profileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count profiles',
      one: '1 profile',
    );
    return '$_temp0';
  }

  @override
  String get profileFromSubscription => 'Subscription';

  @override
  String get profileCustom => 'Custom';

  @override
  String get profileEdited => 'Edited';

  @override
  String youHaveVersion(String version) {
    return 'You have $version. It keeps working; update when it suits you.';
  }

  @override
  String connectionStateSemantics(String state) {
    return 'Connection state: $state';
  }

  @override
  String exitAt(String country, String ip) {
    return 'Exit: $country · $ip';
  }

  @override
  String get unknownCountry => 'unknown country';

  @override
  String get checkingExit => 'Checking exit…';

  @override
  String get exitCheckFailed => 'Exit check failed';

  @override
  String get unsupportedTest => 'Unsupported test';

  @override
  String get testServerLatency => 'Test server latency';

  @override
  String serverCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count servers',
      one: '1 server',
    );
    return '$_temp0';
  }

  @override
  String get runtime => 'Runtime';

  @override
  String get failureFetch => 'Download failed';

  @override
  String get failureFetchText =>
      'The download failed. Check this device’s network, then retry.';

  @override
  String get failureDns => 'Address lookup failed';

  @override
  String get failureDnsText =>
      'The address could not be looked up. Check this device’s network and DNS, then retry.';

  @override
  String get failureProviderUnreachable => 'Provider unreachable';

  @override
  String failureProviderUnreachableText(String provider) {
    return '$provider’s server did not answer. Your network may block it, or it is down. Retry later or ask the provider for a mirror.';
  }

  @override
  String get failureProviderError => 'Provider error';

  @override
  String failureProviderErrorText(String provider) {
    return '$provider’s server reported an error. Nothing is wrong with Elarni or this device; retry later.';
  }

  @override
  String get failureRateLimited => 'Rate limited';

  @override
  String failureRateLimitedText(String provider) {
    return '$provider is limiting requests. Elarni retries later; wait before refreshing again.';
  }

  @override
  String get failureDenied => 'Access refused';

  @override
  String failureDeniedText(String provider) {
    return '$provider refused the request. The subscription may have expired, run out of traffic or reached its device limit. Contact the provider.';
  }

  @override
  String get failureLinkRemoved => 'Link removed';

  @override
  String failureLinkRemovedText(String provider) {
    return '$provider removed or changed this link. Ask the provider for a new one.';
  }

  @override
  String reductionStatus(Object status) {
    return 'Reduction: $status';
  }

  @override
  String routingDataStatus(Object status) {
    return 'Routing data: $status';
  }

  @override
  String get routingProfileGone => 'This routing profile no longer exists.';

  @override
  String get routingProfileRemoved => 'Routing profile removed';

  @override
  String get happRoutingJson => 'Happ routing JSON';

  @override
  String editNamed(Object name) {
    return 'Edit $name';
  }

  @override
  String get deleteFailed => 'Delete failed.';

  @override
  String deleteSubscriptionNamedQuestion(Object name) {
    return 'Delete $name and its stored nodes?';
  }

  @override
  String get deleteSubscriptionQuestion => 'Delete subscription?';

  @override
  String get showFailed => 'Show failed.';

  @override
  String get hiddenServers => 'Hidden servers';

  @override
  String get deviceIdNotReset => 'Device ID not reset.';

  @override
  String deviceIdResetHelp(Object name) {
    return '$name will see this device as new. If it limits devices, the new ID needs a free slot, and the old one may hold a slot until $name removes it. Your other subscriptions keep their IDs.';
  }

  @override
  String resetDeviceIdQuestion(Object name) {
    return 'Reset device ID for $name?';
  }

  @override
  String get hideFailed => 'Hide failed.';

  @override
  String get serversStayHidden =>
      'They stay hidden after refreshes. Show them again from Hidden servers.';

  @override
  String serversRemovedFrom(Object name) {
    return 'They are removed from $name.';
  }

  @override
  String deleteCountQuestion(Object count) {
    return 'Delete $count?';
  }

  @override
  String hideCountQuestion(Object count) {
    return 'Hide $count?';
  }

  @override
  String serverStaysHidden(Object name) {
    return '$name stays hidden after refreshes. Show it again from Hidden servers.';
  }

  @override
  String deleteNamedQuestion(Object name) {
    return 'Delete $name?';
  }

  @override
  String get deleteServerQuestion => 'Delete server?';

  @override
  String get hideServerQuestion => 'Hide server?';

  @override
  String get configNotSaved =>
      'Config not saved. It must be valid Xray JSON for one server.';

  @override
  String get copyConfigFailed => 'Could not copy the config.';

  @override
  String nextRefreshReplacesEdits(Object name) {
    return '$name’s next refresh replaces your edits.';
  }

  @override
  String get serverConfigUnavailable => 'Server config unavailable.';

  @override
  String refreshToShowConfig(Object name) {
    return 'Refresh $name to show this server’s config.';
  }

  @override
  String get providerHidesConfig => 'The provider hides this server’s config.';

  @override
  String get renameFailed => 'Rename failed.';

  @override
  String get emptyUsesProviderName => 'Leave empty to use the provider’s name.';

  @override
  String get renameSubscription => 'Rename subscription';

  @override
  String get downloadOptionsNotSaved =>
      'Subscription download options could not be saved.';

  @override
  String get checkHostsAndRanges =>
      'Check the host names and fragmentation ranges.';

  @override
  String get refreshWholeHours => 'Refresh takes whole hours from 1 to 168.';

  @override
  String get fragmentIntervalRangeHelp => '0–1000, or a range such as 10-100';

  @override
  String get fragmentIntervalMs => 'Fragment interval (ms)';

  @override
  String get fragmentLengthRangeHelp => '1–65535, or a range such as 80-250';

  @override
  String get fragmentLengthBytes => 'Fragment length (bytes)';

  @override
  String get fragmentClientHello => 'Fragment TLS ClientHello';

  @override
  String get httpHostHelp =>
      'Provider host for domain fronting. HTTPS subscriptions only.';

  @override
  String get httpHostOptional => 'HTTP Host (optional)';

  @override
  String get connectAddressHelp =>
      'Provider host or IP; TLS still verifies the subscription hostname.';

  @override
  String get connectAddressOptional => 'Connect address (optional)';

  @override
  String get userAgentHelp =>
      'For providers that serve only the clients they recognize.';

  @override
  String get userAgentOptional => 'User agent (optional)';

  @override
  String get fallbackHostsWarning =>
      'Tried in order after download failures. The subscription path and token are sent to these hosts. Only add hosts supplied by your provider. HTTP 404 and 410 stop retries.';

  @override
  String get fallbackHostsHelp =>
      'One host per line, up to eight. No scheme, port or path.';

  @override
  String get fallbackHosts => 'Fallback hosts';

  @override
  String refreshFollowAppHelp(Object hours) {
    return 'Leave empty to follow the app setting ($hours h). 1–168.';
  }

  @override
  String get refreshFollowProviderHelp =>
      'Leave empty to follow the provider. 1–168.';

  @override
  String providerHours(Object hours) {
    return 'Provider: $hours h';
  }

  @override
  String get refreshEveryHoursOverride => 'Refresh every (hours) · override';

  @override
  String get subscriptionDownloads => 'Subscription downloads';

  @override
  String get sharingUnavailable =>
      'Sharing unavailable. Refresh the subscription and check whether the provider allows sharing.';

  @override
  String get copyDetailsFailed => 'Could not copy connection details.';

  @override
  String get anyoneCanUseDetails =>
      'Anyone with this code or copied text can use these connection details.';

  @override
  String get configTooLargeForQr =>
      'This configuration is too large for a QR code. Use Copy.';

  @override
  String get connectionQrCode => 'Connection QR code';

  @override
  String get backupNotSaved => 'Backup could not be saved.';

  @override
  String get backupNotRestored => 'Backup could not be restored.';

  @override
  String get backupNotSavedCheck =>
      'Backup could not be saved. Refresh subscriptions and check provider sharing restrictions.';

  @override
  String get restoreFailedCheck =>
      'Restore failed. Check the password and backup file.';

  @override
  String get backupUnsupported =>
      'This catalog cannot be backed up: a restore accepts at most 4,096 servers and names up to 1,024 bytes.';

  @override
  String get restoreRollbackFailed =>
      'Restore failed and recovery is incomplete. Restart Elarni.';

  @override
  String get refreshBeforeBackup =>
      'Refresh every subscription before creating a backup.';

  @override
  String get sharingDisabledByProvider =>
      'A provider has disabled sharing and backups.';

  @override
  String get encryptedBackupSaved => 'Encrypted backup saved.';

  @override
  String get backupRestored =>
      'Backup restored. Refresh subscription and routing data before connecting.';

  @override
  String get chooseBackupAndRestore => 'Choose backup and restore';

  @override
  String get saveBackup => 'Save backup';

  @override
  String get backupPasswordRules =>
      'Use at least 12 characters and matching passwords.';

  @override
  String get confirmPassword => 'Confirm password';

  @override
  String get atLeast12Characters => 'At least 12 characters';

  @override
  String get backupPassword => 'Backup password';

  @override
  String get createBackupHelp =>
      'Saves subscriptions, servers, group choices and routing in a password-protected file. Refresh subscriptions first; providers that disable sharing also disable backup. Keep the password: it cannot be recovered.';

  @override
  String get restoreBackupReplacesHelp =>
      'Replaces subscriptions, servers and routing. Automatic failover is disabled. Refresh subscriptions and downloaded routing data afterward. Tunnel settings and login credentials stay on this device.';

  @override
  String get trustedWifiRules =>
      'Use up to 64 names of at most 32 bytes each, without tabs.';

  @override
  String get oneNetworkPerLine => 'One network name per line';

  @override
  String get oneCidrPerLine => 'One CIDR per line';

  @override
  String get icmpDisconnectsTunnel =>
      'Elarni will disconnect the tunnel for this test and restore it afterward.';

  @override
  String get runIcmpTestQuestion => 'Run ICMP test?';

  @override
  String get credentialsNotApplied => 'Credentials could not be applied.';

  @override
  String get saveAndEnable => 'Save & enable';

  @override
  String get credentialRules =>
      'Use 1–255 bytes per field, without control characters; usernames cannot contain a colon.';

  @override
  String get enterPassword => 'Enter password';

  @override
  String get password => 'Password';

  @override
  String get enterUsername => 'Enter username';

  @override
  String get username => 'Username';

  @override
  String get setProxyCredentials =>
      'Set credentials for SOCKS5 and HTTP connections.';

  @override
  String get proxyCredentialsStored =>
      'Stored securely for your account. Existing credentials are never displayed.';

  @override
  String get proxyAuthentication => 'Proxy authentication';

  @override
  String get useValidRanges =>
      'Use valid increasing ranges within the displayed limits.';

  @override
  String get fragmentIntervalHelp => 'A value or range from 0 to 1000';

  @override
  String get intervalMs => 'Interval (ms)';

  @override
  String get fragmentLengthHelp => 'A value or range from 1 to 65535';

  @override
  String get fragmentPacketsHelp => 'tlshello or a packet range, such as 1-3';

  @override
  String get fragmentPackets => 'Packets';

  @override
  String get feedNotSaved => 'The feed could not be saved.';

  @override
  String get feedNeedsHttps =>
      'Enter an https:// address, or leave it empty to turn the check off.';

  @override
  String get feedEmptyTurnsOff => 'Leave empty to turn the check off.';

  @override
  String get feedAddress => 'Feed address';

  @override
  String get useDifferentPorts => 'Use different ports between 1 and 65535.';

  @override
  String get httpPort => 'HTTP port';

  @override
  String get socksPort => 'SOCKS5 port';

  @override
  String get listenerPorts => 'Listener ports';

  @override
  String get retrySelectedServer => 'Retry selected server';

  @override
  String get checkConnection => 'Check connection';

  @override
  String get refreshStatus => 'Refresh status';

  @override
  String get diagnosticsContents =>
      'Diagnostics contain connection state and selected runtime counters. Credentials, subscription URLs and browsing destinations are excluded. Nothing is uploaded.';

  @override
  String get recoveryTriesAllowedBackups =>
      'Only your allowed backup servers may be tried.';

  @override
  String get recoveryStaysOnServer => 'Recovery stays on your selected server.';

  @override
  String get passingCheckScope =>
      'A passing check verifies one target at that time. It does not verify every app or website.';

  @override
  String connectionStateLine(Object state) {
    return 'Connection: $state';
  }

  @override
  String get connectionTroubleshooting => 'Connection troubleshooting';

  @override
  String get subscriptionProfile => 'Subscription profile';

  @override
  String get customProfile => 'Custom profile';

  @override
  String get originalVersion => 'Original version';

  @override
  String skippedGeodata(String codes) {
    return 'Direct, Block and domestic DNS rules skip codes the geofiles lack: $codes.';
  }

  @override
  String geofileDetails(String bytes, String original, String updated) {
    return '$bytes bytes · Original $original bytes\nUpdated $updated';
  }

  @override
  String get unknown => 'Unknown';

  @override
  String managedListsError(String error) {
    return 'Managed lists: $error';
  }

  @override
  String get serverName => 'Server name';

  @override
  String get diagnosticsSection => 'Diagnostics';

  @override
  String get recordConnectionDiagnostics => 'Record connection diagnostics';

  @override
  String get recordConnectionDiagnosticsHelp =>
      'Records connection timing, byte counts and errors while connected, so a problem can be traced. No sites, addresses, credentials or content. Uses little CPU; changing it reconnects.';

  @override
  String get markAction => 'Mark';

  @override
  String get markProblemNow => 'Mark a problem now';

  @override
  String get markProblemNowHelp => 'Also on the main screen while recording.';

  @override
  String get saveRecordingAsZip => 'Save recording as ZIP';

  @override
  String problemMarkedAt(String time) {
    return 'Problem marked at $time. Export the recording when you are done.';
  }

  @override
  String get markNotSaved => 'The mark could not be saved.';

  @override
  String get recordingSaved => 'Recording saved.';

  @override
  String get recordingEmpty =>
      'Nothing is recorded yet. Turn on Record connection diagnostics, reproduce the problem, then export.';

  @override
  String get recordingNotSaved =>
      'The recording could not be saved. Choose a writable location and retry.';

  @override
  String get recordingConnectionDiagnostics =>
      'Recording connection diagnostics';

  @override
  String get markProblem => 'Mark problem';

  @override
  String get perAppUnknownOwner => 'Unidentified traffic';

  @override
  String get perAppUnknownOwnerHelp =>
      'Traffic without an app: WSL, virtual machines, closed connections';

  @override
  String perAppRunningNow(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count programs running',
      one: '1 program running',
    );
    return '$_temp0';
  }

  @override
  String get perAppNotRunning => 'Not running now';

  @override
  String get perAppWarningMissing => 'Not found on this computer.';

  @override
  String get perAppWarningFolder =>
      'This is a folder. A folder rule ends with a separator and matches the programs inside.';

  @override
  String get perAppWarningNotFolder => 'This is a file, not a folder.';

  @override
  String get perAppWarningScript =>
      'A script: its interpreter runs, not the script. Add the program it starts.';

  @override
  String get perAppWarningSymlink =>
      'A link: the program runs as the file it points to.';

  @override
  String get perAppWarningCase =>
      'The letter case differs from the file on disk, and rules compare it.';

  @override
  String get perAppWarningLauncher =>
      'A launcher: it starts another program, which this rule does not match.';

  @override
  String get perAppWarningBundleName =>
      'A bare name matches a program file, not an app bundle. Pick the app from the list.';

  @override
  String get perAppWarningVersioned =>
      'Names one version of the app, so it stops matching after the next update.';

  @override
  String get perAppWarningUnknown => 'This rule may not match any program.';

  @override
  String perAppSuggestedRule(String rule) {
    return 'Suggested rule: $rule';
  }

  @override
  String get perAppUseSuggested => 'Use suggested rule';

  @override
  String get perAppConnections => 'Recent connections';

  @override
  String get perAppConnectionsHelp =>
      'Connections apps opened while Elarni is connected, newest first, with where each one went. It names the program behind an app\'s traffic, such as a helper or updater, so you can add it. Kept in memory until you disconnect.';

  @override
  String get perAppConnectionsDisconnected =>
      'Connect to see which apps open connections and where they go.';

  @override
  String get perAppConnectionsOff =>
      'Per-app routing is off, so apps are not named. Turn it on and save to see them.';

  @override
  String get perAppConnectionsEmpty => 'No connections yet.';

  @override
  String get perAppConnectionsSearch => 'Search apps and addresses';

  @override
  String get perAppConnectionNoApp => 'App not looked up';

  @override
  String get perAppConnectionDirect => 'Direct';

  @override
  String get perAppConnectionProxy => 'Through a server';

  @override
  String get perAppConnectionBlocked => 'Blocked';

  @override
  String get perAppConnectionDns => 'DNS';

  @override
  String get perAppConnectionRouting => 'Routing';

  @override
  String get perAppConnectionListed => 'Per-app rule';

  @override
  String get perAppConnectionNotListed => 'Not listed';

  @override
  String get perAppConnectionAdd => 'Add to list';

  @override
  String perAppConnectionAdded(String name) {
    return '$name added. Save changes to apply.';
  }

  @override
  String get perAppConnectionOpenedReset =>
      'Open before Elarni connected · Closed, so the app reconnects through per-app routing';

  @override
  String get perAppConnectionOpenedKept =>
      'Open before Elarni connected · Skips per-app routing until the app reconnects';

  @override
  String perAppConnectionsRestart(String apps) {
    return 'Restart $apps: their connections opened before Elarni connected skip per-app routing until they reconnect.';
  }
}
