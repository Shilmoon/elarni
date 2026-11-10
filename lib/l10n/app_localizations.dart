import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @noLogLinesYet.
  ///
  /// In en, this message translates to:
  /// **'No log lines yet. The core records them while it runs.'**
  String get noLogLinesYet;

  /// No description provided for @loggingOff.
  ///
  /// In en, this message translates to:
  /// **'Logging is off. Choose a level to record the core log.'**
  String get loggingOff;

  /// No description provided for @saveEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Save…'**
  String get saveEllipsis;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @logLevel.
  ///
  /// In en, this message translates to:
  /// **'Level'**
  String get logLevel;

  /// No description provided for @logNotSaved.
  ///
  /// In en, this message translates to:
  /// **'The log could not be saved.'**
  String get logNotSaved;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @logLevelNotSaved.
  ///
  /// In en, this message translates to:
  /// **'The log level could not be saved.'**
  String get logLevelNotSaved;

  /// No description provided for @logLevelAppliesNextConnection.
  ///
  /// In en, this message translates to:
  /// **'The level applies from the next connection.'**
  String get logLevelAppliesNextConnection;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @logs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logs;

  /// No description provided for @logLevelDebug.
  ///
  /// In en, this message translates to:
  /// **'Debug'**
  String get logLevelDebug;

  /// No description provided for @logLevelInfo.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get logLevelInfo;

  /// No description provided for @logLevelWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get logLevelWarning;

  /// No description provided for @logLevelError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get logLevelError;

  /// No description provided for @logLevelOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get logLevelOff;

  /// No description provided for @issueOperationFailedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Refresh status and retry the selected server. Export diagnostics if it keeps failing.'**
  String get issueOperationFailedRemedy;

  /// No description provided for @issueOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'The connection operation failed.'**
  String get issueOperationFailed;

  /// No description provided for @issueCancelledRemedy.
  ///
  /// In en, this message translates to:
  /// **'Your manual action takes priority.'**
  String get issueCancelledRemedy;

  /// No description provided for @issueCancelled.
  ///
  /// In en, this message translates to:
  /// **'The operation was cancelled.'**
  String get issueCancelled;

  /// No description provided for @issuePerAppTargetMissingRemedy.
  ///
  /// In en, this message translates to:
  /// **'Choose another target for it in Per-app routing.'**
  String get issuePerAppTargetMissingRemedy;

  /// No description provided for @issuePerAppTargetMissing.
  ///
  /// In en, this message translates to:
  /// **'An app in Per-app routing uses a server that no longer exists.'**
  String get issuePerAppTargetMissing;

  /// No description provided for @issueStorageUnavailableRemedy.
  ///
  /// In en, this message translates to:
  /// **'Restart Elarni. If this continues, restore an encrypted backup.'**
  String get issueStorageUnavailableRemedy;

  /// No description provided for @issueStorageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Elarni could not read or save its catalog.'**
  String get issueStorageUnavailable;

  /// No description provided for @issueBusyRemedy.
  ///
  /// In en, this message translates to:
  /// **'Wait for it to finish, then retry.'**
  String get issueBusyRemedy;

  /// No description provided for @issueBusy.
  ///
  /// In en, this message translates to:
  /// **'Another operation is in progress.'**
  String get issueBusy;

  /// No description provided for @issueVpnGuardStaleRemedy.
  ///
  /// In en, this message translates to:
  /// **'Use Repair VPN setup and allow the administrator permission request.'**
  String get issueVpnGuardStaleRemedy;

  /// No description provided for @issueVpnGuardStale.
  ///
  /// In en, this message translates to:
  /// **'DNS is blocked by a crashed tunnel.'**
  String get issueVpnGuardStale;

  /// No description provided for @issueVpnGuardBusyRemedy.
  ///
  /// In en, this message translates to:
  /// **'Disconnect the other user or the system service, then retry.'**
  String get issueVpnGuardBusyRemedy;

  /// No description provided for @issueVpnGuardBusy.
  ///
  /// In en, this message translates to:
  /// **'Another Elarni VPN is connected on this computer.'**
  String get issueVpnGuardBusy;

  /// No description provided for @issueVpnFirewallUnavailableRemedy.
  ///
  /// In en, this message translates to:
  /// **'Install nftables (the nft command), then retry.'**
  String get issueVpnFirewallUnavailableRemedy;

  /// No description provided for @issueVpnFirewallUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The VPN firewall tool is missing.'**
  String get issueVpnFirewallUnavailable;

  /// No description provided for @issueDisconnectUnconfirmedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Refresh status before reconnecting, or use Repair VPN setup.'**
  String get issueDisconnectUnconfirmedRemedy;

  /// No description provided for @issueDisconnectUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Disconnection could not be confirmed.'**
  String get issueDisconnectUnconfirmed;

  /// No description provided for @issueProviderUnavailableRemedy.
  ///
  /// In en, this message translates to:
  /// **'Retry the selected server. If the problem continues, use Repair VPN setup.'**
  String get issueProviderUnavailableRemedy;

  /// No description provided for @issueProviderUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The VPN runtime is unavailable.'**
  String get issueProviderUnavailable;

  /// No description provided for @issueCheckFailedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Retry the check. A timeout, target failure or authentication problem may need different action.'**
  String get issueCheckFailedRemedy;

  /// No description provided for @issueCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'The connection check failed.'**
  String get issueCheckFailed;

  /// No description provided for @issueStatusUnavailableRemedy.
  ///
  /// In en, this message translates to:
  /// **'Refresh status. The last known state does not confirm the current connection.'**
  String get issueStatusUnavailableRemedy;

  /// No description provided for @issueStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Connection status is unavailable.'**
  String get issueStatusUnavailable;

  /// No description provided for @issuePreviousRestoredRemedy.
  ///
  /// In en, this message translates to:
  /// **'Check access before retrying another server.'**
  String get issuePreviousRestoredRemedy;

  /// No description provided for @issuePreviousRestored.
  ///
  /// In en, this message translates to:
  /// **'The replacement failed; the previous configuration was restored.'**
  String get issuePreviousRestored;

  /// No description provided for @issueRecoveryRequiredRemedy.
  ///
  /// In en, this message translates to:
  /// **'Disconnect before retrying. If that fails, use Repair VPN setup.'**
  String get issueRecoveryRequiredRemedy;

  /// No description provided for @issueRecoveryRequired.
  ///
  /// In en, this message translates to:
  /// **'The connection could not be restored safely.'**
  String get issueRecoveryRequired;

  /// No description provided for @issueInvalidConfigurationRemedy.
  ///
  /// In en, this message translates to:
  /// **'Review its settings or refresh the affected subscription.'**
  String get issueInvalidConfigurationRemedy;

  /// No description provided for @issueInvalidConfiguration.
  ///
  /// In en, this message translates to:
  /// **'The selected configuration cannot be used.'**
  String get issueInvalidConfiguration;

  /// No description provided for @issueInvalidRecoveryRemedy.
  ///
  /// In en, this message translates to:
  /// **'Choose the current server, allowed backups and connection-check targets again.'**
  String get issueInvalidRecoveryRemedy;

  /// No description provided for @issueInvalidRecovery.
  ///
  /// In en, this message translates to:
  /// **'The recovery settings are incomplete or no longer valid.'**
  String get issueInvalidRecovery;

  /// No description provided for @issueMissingCredentialsRemedy.
  ///
  /// In en, this message translates to:
  /// **'Refresh or import the affected subscription again.'**
  String get issueMissingCredentialsRemedy;

  /// No description provided for @issueMissingCredentials.
  ///
  /// In en, this message translates to:
  /// **'The server credentials are unavailable.'**
  String get issueMissingCredentials;

  /// No description provided for @issueRecoveryExhaustedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Retry the selected server or review the backups you allowed.'**
  String get issueRecoveryExhaustedRemedy;

  /// No description provided for @issueRecoveryExhausted.
  ///
  /// In en, this message translates to:
  /// **'Automatic recovery could not find working access.'**
  String get issueRecoveryExhausted;

  /// No description provided for @issueUnsupportedPolicyRemedy.
  ///
  /// In en, this message translates to:
  /// **'On macOS, checks require a full tunnel, no route exclusions or custom rules, and Xray TUN off. Your routing settings were preserved.'**
  String get issueUnsupportedPolicyRemedy;

  /// No description provided for @issueUnsupportedPolicy.
  ///
  /// In en, this message translates to:
  /// **'Automatic traffic checks do not support this routing setup.'**
  String get issueUnsupportedPolicy;

  /// No description provided for @issueConnectionFailedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Retry this server and check its configuration or subscription.'**
  String get issueConnectionFailedRemedy;

  /// No description provided for @issueConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'The selected server could not establish working access.'**
  String get issueConnectionFailed;

  /// No description provided for @issueCheckTargetFailedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Check the test URL and DNS settings. This does not prove the server is down.'**
  String get issueCheckTargetFailedRemedy;

  /// No description provided for @issueCheckTargetFailed.
  ///
  /// In en, this message translates to:
  /// **'The connection check could not verify its target.'**
  String get issueCheckTargetFailed;

  /// No description provided for @issueListenerUnavailableRemedy.
  ///
  /// In en, this message translates to:
  /// **'Close the conflicting app or change the listener port in Connection settings.'**
  String get issueListenerUnavailableRemedy;

  /// No description provided for @issueListenerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'A local proxy port is occupied or unavailable.'**
  String get issueListenerUnavailable;

  /// No description provided for @issueVpnConfigurationFailedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Review VPN permissions in system settings, then retry.'**
  String get issueVpnConfigurationFailedRemedy;

  /// No description provided for @issueVpnConfigurationFailed.
  ///
  /// In en, this message translates to:
  /// **'The system could not prepare the VPN.'**
  String get issueVpnConfigurationFailed;

  /// No description provided for @issuePermissionDeniedRemedy.
  ///
  /// In en, this message translates to:
  /// **'Retry and allow the system permission request.'**
  String get issuePermissionDeniedRemedy;

  /// No description provided for @issuePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'VPN permission was denied.'**
  String get issuePermissionDenied;

  /// No description provided for @savingEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get savingEllipsis;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @expectedResponseBodyOptional.
  ///
  /// In en, this message translates to:
  /// **'Expected response body (optional)'**
  String get expectedResponseBodyOptional;

  /// No description provided for @expectedHttpStatus.
  ///
  /// In en, this message translates to:
  /// **'Expected HTTP status'**
  String get expectedHttpStatus;

  /// No description provided for @recoverySecondUrlOptional.
  ///
  /// In en, this message translates to:
  /// **'Optional for same-server recovery'**
  String get recoverySecondUrlOptional;

  /// No description provided for @checkUrl.
  ///
  /// In en, this message translates to:
  /// **'Check URL'**
  String get checkUrl;

  /// No description provided for @secondCheckUrl.
  ///
  /// In en, this message translates to:
  /// **'Second check URL'**
  String get secondCheckUrl;

  /// No description provided for @recoveryChecksHelp.
  ///
  /// In en, this message translates to:
  /// **'Connection checks send a small request through the connection while recovery is enabled. Choose trusted URLs with a predictable response. Backups require two different check hosts.'**
  String get recoveryChecksHelp;

  /// No description provided for @recoveryTcpFirstHelp.
  ///
  /// In en, this message translates to:
  /// **'When a server on UDP or a port other than 443 stops answering, TCP 443 backups go first. If only Russian-entry servers get through, they go first.'**
  String get recoveryTcpFirstHelp;

  /// No description provided for @recoveryBackupNumber.
  ///
  /// In en, this message translates to:
  /// **'Backup {number}'**
  String recoveryBackupNumber(Object number);

  /// No description provided for @recoveryLatencyHelp.
  ///
  /// In en, this message translates to:
  /// **'Allowed servers from any subscription to compare. Recovery uses the fastest healthy one and switches only after a meaningful improvement. Choosing another server by hand makes it the primary and keeps these servers.'**
  String get recoveryLatencyHelp;

  /// No description provided for @recoveryOrderedHelp.
  ///
  /// In en, this message translates to:
  /// **'Allowed backups from any subscription, tried in the order you select them. Choosing another server by hand makes it the primary and keeps these backups.'**
  String get recoveryOrderedHelp;

  /// No description provided for @lowestLatency.
  ///
  /// In en, this message translates to:
  /// **'Lowest latency'**
  String get lowestLatency;

  /// No description provided for @recoveryUseAllowedBackups.
  ///
  /// In en, this message translates to:
  /// **'Use allowed backups'**
  String get recoveryUseAllowedBackups;

  /// No description provided for @recoveryReconnectThisServer.
  ///
  /// In en, this message translates to:
  /// **'Reconnect to this server'**
  String get recoveryReconnectThisServer;

  /// No description provided for @recovery.
  ///
  /// In en, this message translates to:
  /// **'Recovery'**
  String get recovery;

  /// No description provided for @recoveryIntro.
  ///
  /// In en, this message translates to:
  /// **'Your selected server stays selected. Switching to a backup requires your permission below. Stop cancels recovery.'**
  String get recoveryIntro;

  /// No description provided for @connectionRecovery.
  ///
  /// In en, this message translates to:
  /// **'Connection recovery'**
  String get connectionRecovery;

  /// No description provided for @recoveryChooseBackup.
  ///
  /// In en, this message translates to:
  /// **'Choose at least one allowed backup server.'**
  String get recoveryChooseBackup;

  /// No description provided for @recoveryTargetsSameHost.
  ///
  /// In en, this message translates to:
  /// **'Use two different check hosts for independent results.'**
  String get recoveryTargetsSameHost;

  /// No description provided for @recoveryTargetInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid check URL and a successful HTTP status for target {number}.'**
  String recoveryTargetInvalid(Object number);

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @proxyNeedsScheme.
  ///
  /// In en, this message translates to:
  /// **'Use a socks5:// or http:// address.'**
  String get proxyNeedsScheme;

  /// No description provided for @proxyNotLocal.
  ///
  /// In en, this message translates to:
  /// **'Use a proxy on this device, such as 127.0.0.1.'**
  String get proxyNotLocal;

  /// No description provided for @proxyNeedsPort.
  ///
  /// In en, this message translates to:
  /// **'Add the proxy port, such as 127.0.0.1:1080.'**
  String get proxyNeedsPort;

  /// No description provided for @proxyAddressOnly.
  ///
  /// In en, this message translates to:
  /// **'Use only the address and port, without a login or path.'**
  String get proxyAddressOnly;

  /// No description provided for @proxyIsOwnPort.
  ///
  /// In en, this message translates to:
  /// **'That is Elarni\'s own proxy port. Use the other app\'s port.'**
  String get proxyIsOwnPort;

  /// No description provided for @routeEnforcementWithIncludeAll.
  ///
  /// In en, this message translates to:
  /// **'Enforce tunnel routes cannot be combined with Include all networks. Turn one of them off.'**
  String get routeEnforcementWithIncludeAll;

  /// No description provided for @routeEnforcementWithBlock.
  ///
  /// In en, this message translates to:
  /// **'Enforce tunnel routes cannot be combined with Block traffic without VPN. Turn one of them off.'**
  String get routeEnforcementWithBlock;

  /// No description provided for @routeEnforcementDefaultRoutes.
  ///
  /// In en, this message translates to:
  /// **'Enforce tunnel routes needs specific included routes. Replace 0.0.0.0/0 and ::/0 with specific routes, or turn enforcement off.'**
  String get routeEnforcementDefaultRoutes;

  /// No description provided for @providerAttentionLastReported.
  ///
  /// In en, this message translates to:
  /// **'Provider attention required · Last reported information'**
  String get providerAttentionLastReported;

  /// No description provided for @notDownloadedYet.
  ///
  /// In en, this message translates to:
  /// **'Not downloaded yet'**
  String get notDownloadedYet;

  /// No description provided for @refreshingLastReported.
  ///
  /// In en, this message translates to:
  /// **'Refreshing · Last reported information'**
  String get refreshingLastReported;

  /// No description provided for @refreshFailedLastReported.
  ///
  /// In en, this message translates to:
  /// **'Refresh failed · Last reported information'**
  String get refreshFailedLastReported;

  /// No description provided for @accountDisabledByProvider.
  ///
  /// In en, this message translates to:
  /// **'Account disabled by provider'**
  String get accountDisabledByProvider;

  /// No description provided for @remainingSemantics.
  ///
  /// In en, this message translates to:
  /// **'{label} remaining: {value}'**
  String remainingSemantics(Object label, Object value);

  /// No description provided for @openProviderPage.
  ///
  /// In en, this message translates to:
  /// **'Open provider page'**
  String get openProviderPage;

  /// No description provided for @messageFrom.
  ///
  /// In en, this message translates to:
  /// **'Message from {name}'**
  String messageFrom(Object name);

  /// No description provided for @latencyMs.
  ///
  /// In en, this message translates to:
  /// **'{ms} ms'**
  String latencyMs(Object ms);

  /// No description provided for @protocolTooltip.
  ///
  /// In en, this message translates to:
  /// **'Protocol: {protocol}'**
  String protocolTooltip(Object protocol);

  /// No description provided for @notProvided.
  ///
  /// In en, this message translates to:
  /// **'Not provided'**
  String get notProvided;

  /// No description provided for @lessThanDayLeft.
  ///
  /// In en, this message translates to:
  /// **'Less than a day left'**
  String get lessThanDayLeft;

  /// No description provided for @expired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expired;

  /// No description provided for @noExpiry.
  ///
  /// In en, this message translates to:
  /// **'No expiry'**
  String get noExpiry;

  /// No description provided for @dataExhausted.
  ///
  /// In en, this message translates to:
  /// **'Data exhausted'**
  String get dataExhausted;

  /// No description provided for @amountLeft.
  ///
  /// In en, this message translates to:
  /// **'{amount} left'**
  String amountLeft(Object amount);

  /// No description provided for @unlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get unlimited;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @routing.
  ///
  /// In en, this message translates to:
  /// **'Routing'**
  String get routing;

  /// No description provided for @subscriptions.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions'**
  String get subscriptions;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @backToHome.
  ///
  /// In en, this message translates to:
  /// **'Back to Home'**
  String get backToHome;

  /// No description provided for @settingsGroupSupport.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get settingsGroupSupport;

  /// No description provided for @settingsGroupNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get settingsGroupNetwork;

  /// No description provided for @settingsGroupPreferences.
  ///
  /// In en, this message translates to:
  /// **'Preferences'**
  String get settingsGroupPreferences;

  /// No description provided for @settingsCategory.
  ///
  /// In en, this message translates to:
  /// **'Settings category'**
  String get settingsCategory;

  /// No description provided for @helpFor.
  ///
  /// In en, this message translates to:
  /// **'Help for {title}'**
  String helpFor(Object title);

  /// No description provided for @importingEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Importing…'**
  String get importingEllipsis;

  /// No description provided for @importAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// No description provided for @importScanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan QR'**
  String get importScanQr;

  /// No description provided for @importFromQrImage.
  ///
  /// In en, this message translates to:
  /// **'From QR image'**
  String get importFromQrImage;

  /// No description provided for @importFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'From clipboard'**
  String get importFromClipboard;

  /// No description provided for @importFromFile.
  ///
  /// In en, this message translates to:
  /// **'From file'**
  String get importFromFile;

  /// No description provided for @liveCameraPreview.
  ///
  /// In en, this message translates to:
  /// **'Live camera preview'**
  String get liveCameraPreview;

  /// No description provided for @scanQrCode.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get scanQrCode;

  /// No description provided for @cameraUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Camera unavailable. Check camera permissions and close other camera apps.'**
  String get cameraUnavailable;

  /// No description provided for @remindersUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Subscription reminders are unavailable. Check notification permissions.'**
  String get remindersUnavailable;

  /// No description provided for @appPreferencesNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Desktop preferences could not be saved.'**
  String get appPreferencesNotSaved;

  /// No description provided for @appPreferencesNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Desktop preferences could not be loaded.'**
  String get appPreferencesNotLoaded;

  /// No description provided for @openElarniLink.
  ///
  /// In en, this message translates to:
  /// **'Open Elarni link?'**
  String get openElarniLink;

  /// No description provided for @select.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get select;

  /// No description provided for @daysLeft.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{1 day left} other{{days} days left}}'**
  String daysLeft(int days);

  /// No description provided for @gibibytes.
  ///
  /// In en, this message translates to:
  /// **'GiB'**
  String get gibibytes;

  /// No description provided for @mebibytes.
  ///
  /// In en, this message translates to:
  /// **'MiB'**
  String get mebibytes;

  /// No description provided for @kibibytes.
  ///
  /// In en, this message translates to:
  /// **'KiB'**
  String get kibibytes;

  /// No description provided for @bytesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} bytes'**
  String bytesCount(String count);

  /// No description provided for @settingsGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsGeneral;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get settingsConnection;

  /// No description provided for @settingsAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsAdvanced;

  /// No description provided for @settingsServerTests.
  ///
  /// In en, this message translates to:
  /// **'Server tests'**
  String get settingsServerTests;

  /// No description provided for @settingsBackupAndRepair.
  ///
  /// In en, this message translates to:
  /// **'Backup and repair'**
  String get settingsBackupAndRepair;

  /// No description provided for @settingsSystemInfo.
  ///
  /// In en, this message translates to:
  /// **'System info'**
  String get settingsSystemInfo;

  /// No description provided for @settingsRouteTable.
  ///
  /// In en, this message translates to:
  /// **'Route table'**
  String get settingsRouteTable;

  /// No description provided for @usageTime.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get usageTime;

  /// No description provided for @usageData.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get usageData;

  /// No description provided for @desktopStatusNotUpdated.
  ///
  /// In en, this message translates to:
  /// **'Desktop status could not be updated.'**
  String get desktopStatusNotUpdated;

  /// No description provided for @linkAsksDisconnect.
  ///
  /// In en, this message translates to:
  /// **'A link asks Elarni to disconnect.'**
  String get linkAsksDisconnect;

  /// No description provided for @linkImportsRoutingProfile.
  ///
  /// In en, this message translates to:
  /// **'A link wants to import a routing profile.'**
  String get linkImportsRoutingProfile;

  /// No description provided for @linkImportsClientProfile.
  ///
  /// In en, this message translates to:
  /// **'A link wants to import a client profile.'**
  String get linkImportsClientProfile;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @appRoutingUses.
  ///
  /// In en, this message translates to:
  /// **'App routing uses {engine}. Unlisted apps connect directly in only-selected mode and follow normal routing in bypass mode. Traffic Elarni cannot link to an app (WSL, virtual machines, containers, connections that closed early) may come from a listed app: in only-selected mode it follows normal routing. Add Unidentified traffic to the list to choose where it goes.'**
  String appRoutingUses(String engine);

  /// No description provided for @systemWideVpn.
  ///
  /// In en, this message translates to:
  /// **'System-wide VPN'**
  String get systemWideVpn;

  /// No description provided for @connectionMode.
  ///
  /// In en, this message translates to:
  /// **'Connection mode'**
  String get connectionMode;

  /// No description provided for @connectionModeHelp.
  ///
  /// In en, this message translates to:
  /// **'System-wide VPN connects all apps; administrator approval is requested on the first VPN connection in this app session. System proxy points this computer\'s proxy setting at Elarni without administrator approval; only apps that follow it, such as browsers, use it. Local proxy only opens the ports below for apps you set up yourself.'**
  String get connectionModeHelp;

  /// No description provided for @connectionModeServiceHelp.
  ///
  /// In en, this message translates to:
  /// **'System-wide VPN connects all apps; administrator approval is requested on the first VPN connection in this app session, unless Connect without administrator approval is on. System proxy points this computer\'s proxy setting at Elarni without administrator approval; only apps that follow it, such as browsers, use it. Local proxy only opens the ports below for apps you set up yourself.'**
  String get connectionModeServiceHelp;

  /// No description provided for @systemProxy.
  ///
  /// In en, this message translates to:
  /// **'System proxy'**
  String get systemProxy;

  /// No description provided for @localProxyOnly.
  ///
  /// In en, this message translates to:
  /// **'Local proxy only'**
  String get localProxyOnly;

  /// No description provided for @systemProxyMode.
  ///
  /// In en, this message translates to:
  /// **'System proxy mode'**
  String get systemProxyMode;

  /// No description provided for @systemProxyListeners.
  ///
  /// In en, this message translates to:
  /// **'In System proxy mode, apps on this computer use the HTTP port without a login.'**
  String get systemProxyListeners;

  /// No description provided for @updateDraft.
  ///
  /// In en, this message translates to:
  /// **'Update draft'**
  String get updateDraft;

  /// No description provided for @loadProfile.
  ///
  /// In en, this message translates to:
  /// **'Load profile'**
  String get loadProfile;

  /// No description provided for @perAppProfileLoaded.
  ///
  /// In en, this message translates to:
  /// **'{platform} profile loaded. Review the apps and choose Save changes to apply.'**
  String perAppProfileLoaded(Object platform);

  /// No description provided for @backToApps.
  ///
  /// In en, this message translates to:
  /// **'Back to apps'**
  String get backToApps;

  /// No description provided for @routingProfileJson.
  ///
  /// In en, this message translates to:
  /// **'Routing profile JSON'**
  String get routingProfileJson;

  /// No description provided for @executableNamesOrPaths.
  ///
  /// In en, this message translates to:
  /// **'Executable names or full paths'**
  String get executableNamesOrPaths;

  /// No description provided for @loadRoutingProfileHelp.
  ///
  /// In en, this message translates to:
  /// **'Load a {platform} routing profile into this draft. Save changes applies it.'**
  String loadRoutingProfileHelp(Object platform);

  /// No description provided for @executableRulesHelp.
  ///
  /// In en, this message translates to:
  /// **'One executable name or path per line, up to 256. A folder ending in / includes executables inside it.'**
  String get executableRulesHelp;

  /// No description provided for @routingProfileContents.
  ///
  /// In en, this message translates to:
  /// **'Routing profiles contain only the mode, executable rules and app targets other than servers. Share with another {platform} device; paths may need updating.'**
  String routingProfileContents(Object platform);

  /// No description provided for @appRoutingNotFirewall.
  ///
  /// In en, this message translates to:
  /// **'DNS and local SOCKS/HTTP listeners keep their existing rules. App routing is not a firewall or a kill switch.'**
  String get appRoutingNotFirewall;

  /// No description provided for @macMatchingHelp.
  ///
  /// In en, this message translates to:
  /// **'Selecting an .app includes every executable inside its bundle. Other names and paths are case-sensitive.'**
  String get macMatchingHelp;

  /// No description provided for @windowsMatchingHelp.
  ///
  /// In en, this message translates to:
  /// **'Windows matches .exe names and full paths case-insensitively. Select helper executables separately.'**
  String get windowsMatchingHelp;

  /// No description provided for @linuxMatchingHelp.
  ///
  /// In en, this message translates to:
  /// **'Linux matches executable names and paths case-sensitively. Select helper processes separately.'**
  String get linuxMatchingHelp;

  /// No description provided for @pasteRoutingProfile.
  ///
  /// In en, this message translates to:
  /// **'Paste routing profile'**
  String get pasteRoutingProfile;

  /// No description provided for @editExecutableRules.
  ///
  /// In en, this message translates to:
  /// **'Edit executable rules'**
  String get editExecutableRules;

  /// No description provided for @howAppRoutingWorks.
  ///
  /// In en, this message translates to:
  /// **'How app routing works'**
  String get howAppRoutingWorks;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @chooseAppFile.
  ///
  /// In en, this message translates to:
  /// **'Choose app file'**
  String get chooseAppFile;

  /// No description provided for @copyRoutingProfile.
  ///
  /// In en, this message translates to:
  /// **'Copy routing profile'**
  String get copyRoutingProfile;

  /// No description provided for @perAppProfileCopied.
  ///
  /// In en, this message translates to:
  /// **'{platform} profile copied, including application names and paths.'**
  String perAppProfileCopied(Object platform);

  /// No description provided for @profileAndExecutableTools.
  ///
  /// In en, this message translates to:
  /// **'Profile & executable tools'**
  String get profileAndExecutableTools;

  /// No description provided for @noMatchingApps.
  ///
  /// In en, this message translates to:
  /// **'No matching apps.'**
  String get noMatchingApps;

  /// No description provided for @noAppsFound.
  ///
  /// In en, this message translates to:
  /// **'No apps found. Choose an app file below.'**
  String get noAppsFound;

  /// No description provided for @loadingApps.
  ///
  /// In en, this message translates to:
  /// **'Loading apps…'**
  String get loadingApps;

  /// No description provided for @installedAndRunningApps.
  ///
  /// In en, this message translates to:
  /// **'Installed and running apps'**
  String get installedAndRunningApps;

  /// No description provided for @refreshAppList.
  ///
  /// In en, this message translates to:
  /// **'Refresh app list'**
  String get refreshAppList;

  /// No description provided for @searchApps.
  ///
  /// In en, this message translates to:
  /// **'Search apps'**
  String get searchApps;

  /// No description provided for @addApps.
  ///
  /// In en, this message translates to:
  /// **'Add apps'**
  String get addApps;

  /// No description provided for @saveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save changes'**
  String get saveChanges;

  /// No description provided for @perAppTargetsHelp.
  ///
  /// In en, this message translates to:
  /// **'Each app can connect directly, follow your routing rules, be blocked, use a server from any subscription, or use a local SOCKS5 or HTTP proxy such as ByeByeDPI. VPN traffic only; DNS and local proxy rules are unchanged.'**
  String get perAppTargetsHelp;

  /// No description provided for @targetDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get targetDirect;

  /// No description provided for @targetFollowRouting.
  ///
  /// In en, this message translates to:
  /// **'Follow routing rules'**
  String get targetFollowRouting;

  /// No description provided for @otherApps.
  ///
  /// In en, this message translates to:
  /// **'Other apps'**
  String get otherApps;

  /// No description provided for @removeApp.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}'**
  String removeApp(Object name);

  /// No description provided for @details.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get details;

  /// No description provided for @executableRule.
  ///
  /// In en, this message translates to:
  /// **'Executable rule'**
  String get executableRule;

  /// No description provided for @appBundleIncludesHelpers.
  ///
  /// In en, this message translates to:
  /// **'App bundle · includes helpers'**
  String get appBundleIncludesHelpers;

  /// No description provided for @noAppsSelected.
  ///
  /// In en, this message translates to:
  /// **'No apps selected. Add apps to create a routing rule.'**
  String get noAppsSelected;

  /// No description provided for @selectedApps.
  ///
  /// In en, this message translates to:
  /// **'Selected apps'**
  String get selectedApps;

  /// No description provided for @perAppOnlySelected.
  ///
  /// In en, this message translates to:
  /// **'Only selected'**
  String get perAppOnlySelected;

  /// No description provided for @perAppBypassSelected.
  ///
  /// In en, this message translates to:
  /// **'Bypass selected'**
  String get perAppBypassSelected;

  /// No description provided for @perAppRouting.
  ///
  /// In en, this message translates to:
  /// **'Per-app routing'**
  String get perAppRouting;

  /// No description provided for @perAppRoutingIntro.
  ///
  /// In en, this message translates to:
  /// **'Choose which apps use the VPN. Applies to every subscription.'**
  String get perAppRoutingIntro;

  /// No description provided for @perAppOffHelp.
  ///
  /// In en, this message translates to:
  /// **'All apps follow your routing rules. Your app selections are kept.'**
  String get perAppOffHelp;

  /// No description provided for @perAppOnlyHelp.
  ///
  /// In en, this message translates to:
  /// **'Selected apps follow your routing rules unless you choose another target for them. All other apps connect directly.'**
  String get perAppOnlyHelp;

  /// No description provided for @perAppBypassHelp.
  ///
  /// In en, this message translates to:
  /// **'Selected apps connect directly unless you choose another target for them. Other apps follow your routing rules.'**
  String get perAppBypassHelp;

  /// No description provided for @macRulesCaseSensitive.
  ///
  /// In en, this message translates to:
  /// **'Names and paths are case-sensitive. A path ending in / includes executables inside that folder.'**
  String get macRulesCaseSensitive;

  /// No description provided for @macBundleRuleHelp.
  ///
  /// In en, this message translates to:
  /// **'This rule includes every executable inside the app bundle.'**
  String get macBundleRuleHelp;

  /// No description provided for @windowsRulesCaseInsensitive.
  ///
  /// In en, this message translates to:
  /// **'Executable names and paths are case-insensitive. Select other helper executables separately.'**
  String get windowsRulesCaseInsensitive;

  /// No description provided for @linuxRulesCaseSensitive.
  ///
  /// In en, this message translates to:
  /// **'Names and paths are case-sensitive. Select any helper executables separately.'**
  String get linuxRulesCaseSensitive;

  /// No description provided for @appListUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The app list is unavailable. Choose an app file or edit executable rules.'**
  String get appListUnavailable;

  /// No description provided for @closeAppChooser.
  ///
  /// In en, this message translates to:
  /// **'Close app chooser'**
  String get closeAppChooser;

  /// No description provided for @localProxyEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Local proxy…'**
  String get localProxyEllipsis;

  /// No description provided for @targetMissingServer.
  ///
  /// In en, this message translates to:
  /// **'Missing server'**
  String get targetMissingServer;

  /// No description provided for @targetServer.
  ///
  /// In en, this message translates to:
  /// **'Server · {name}'**
  String targetServer(Object name);

  /// No description provided for @targetLocalProxy.
  ///
  /// In en, this message translates to:
  /// **'Local proxy · {address}'**
  String targetLocalProxy(Object address);

  /// No description provided for @perAppOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'The operation failed. Try again; your draft is kept.'**
  String get perAppOperationFailed;

  /// No description provided for @perAppLauncherRule.
  ///
  /// In en, this message translates to:
  /// **'Snap, Flatpak and script launchers start another program, so their rules match nothing. Choose the app from the app list; start a Snap or script app first.'**
  String get perAppLauncherRule;

  /// No description provided for @useProxy.
  ///
  /// In en, this message translates to:
  /// **'Use proxy'**
  String get useProxy;

  /// No description provided for @proxyAddress.
  ///
  /// In en, this message translates to:
  /// **'Proxy address'**
  String get proxyAddress;

  /// No description provided for @localProxyHelp.
  ///
  /// In en, this message translates to:
  /// **'Another app\'s SOCKS5 or HTTP proxy, such as ByeByeDPI.'**
  String get localProxyHelp;

  /// No description provided for @localProxy.
  ///
  /// In en, this message translates to:
  /// **'Local proxy'**
  String get localProxy;

  /// No description provided for @perAppOtherPlatformProfile.
  ///
  /// In en, this message translates to:
  /// **'This is a {profilePlatform} profile. Import a {platform} profile or select the apps on this device.'**
  String perAppOtherPlatformProfile(Object profilePlatform, Object platform);

  /// No description provided for @perAppUnsupportedProfile.
  ///
  /// In en, this message translates to:
  /// **'Unsupported per-app routing profile.'**
  String get perAppUnsupportedProfile;

  /// No description provided for @perAppProfileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The profile exceeds 512 KB.'**
  String get perAppProfileTooLarge;

  /// No description provided for @perAppUnixPathsOnWindows.
  ///
  /// In en, this message translates to:
  /// **'macOS or Unix executable paths cannot be used in a Windows profile. Select the apps on this PC.'**
  String get perAppUnixPathsOnWindows;

  /// No description provided for @perAppMacBundlesOnLinux.
  ///
  /// In en, this message translates to:
  /// **'macOS app bundles cannot be used in a Linux profile. Select the Linux executables.'**
  String get perAppMacBundlesOnLinux;

  /// No description provided for @perAppWindowsPathsElsewhere.
  ///
  /// In en, this message translates to:
  /// **'Windows executable paths cannot be used in a {platform} profile. Select the apps on this device.'**
  String perAppWindowsPathsElsewhere(Object platform);

  /// No description provided for @perAppLinuxRulesElsewhere.
  ///
  /// In en, this message translates to:
  /// **'Flatpak and AppImage rules name Linux apps and cannot be used in a {platform} profile.'**
  String perAppLinuxRulesElsewhere(Object platform);

  /// No description provided for @perAppServiceRulesElsewhere.
  ///
  /// In en, this message translates to:
  /// **'Service rules name Windows services and cannot be used in a {platform} profile.'**
  String perAppServiceRulesElsewhere(Object platform);

  /// No description provided for @perAppFlatpakRule.
  ///
  /// In en, this message translates to:
  /// **'Flatpak app: also its other programs in the sandbox'**
  String get perAppFlatpakRule;

  /// No description provided for @perAppAppImageRule.
  ///
  /// In en, this message translates to:
  /// **'AppImage: the programs in that image file'**
  String get perAppAppImageRule;

  /// No description provided for @perAppServiceRule.
  ///
  /// In en, this message translates to:
  /// **'Windows service: also the services that share its process'**
  String get perAppServiceRule;

  /// No description provided for @perAppKindService.
  ///
  /// In en, this message translates to:
  /// **'Windows service'**
  String get perAppKindService;

  /// No description provided for @perAppIncludeChildren.
  ///
  /// In en, this message translates to:
  /// **'Include programs it starts'**
  String get perAppIncludeChildren;

  /// No description provided for @perAppIncludeChildrenHelp.
  ///
  /// In en, this message translates to:
  /// **'Also routes the programs this app starts, and theirs, such as helpers, updaters and command-line tools. A program listed on its own keeps its own target. A browser the app starts is included too, but not one that was already running.'**
  String get perAppIncludeChildrenHelp;

  /// No description provided for @perAppWithChildren.
  ///
  /// In en, this message translates to:
  /// **'with the programs it starts'**
  String get perAppWithChildren;

  /// No description provided for @perAppPresets.
  ///
  /// In en, this message translates to:
  /// **'Presets'**
  String get perAppPresets;

  /// No description provided for @perAppPresetSteam.
  ///
  /// In en, this message translates to:
  /// **'Steam and games'**
  String get perAppPresetSteam;

  /// No description provided for @perAppPresetBrowsers.
  ///
  /// In en, this message translates to:
  /// **'Browsers'**
  String get perAppPresetBrowsers;

  /// No description provided for @perAppPresetAdded.
  ///
  /// In en, this message translates to:
  /// **'Added'**
  String get perAppPresetAdded;

  /// No description provided for @perAppPresetNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not found'**
  String get perAppPresetNotFound;

  /// No description provided for @perAppPresetWithChildren.
  ///
  /// In en, this message translates to:
  /// **'With the programs it starts'**
  String get perAppPresetWithChildren;

  /// No description provided for @perAppPresetsHelp.
  ///
  /// In en, this message translates to:
  /// **'A preset offers the apps the app list found, each with the rule this computer gives it. For an app it does not find, use Choose app file.'**
  String get perAppPresetsHelp;

  /// No description provided for @perAppAddPresetApps.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Add 1 app} other{Add {count} apps}}'**
  String perAppAddPresetApps(int count);

  /// No description provided for @perAppConnectionStartedBy.
  ///
  /// In en, this message translates to:
  /// **'Started by {name}'**
  String perAppConnectionStartedBy(String name);

  /// No description provided for @perAppAndroidPackages.
  ///
  /// In en, this message translates to:
  /// **'Use Android package names such as com.example.app. Select the apps on this device.'**
  String get perAppAndroidPackages;

  /// No description provided for @perAppInvalidProfile.
  ///
  /// In en, this message translates to:
  /// **'Use a supported mode and up to 256 names or paths, each at most 1024 bytes without control characters, with targets only for listed apps. An active mode needs at least one app.'**
  String get perAppInvalidProfile;

  /// No description provided for @perAppUnsupportedPlatform.
  ///
  /// In en, this message translates to:
  /// **'Unsupported profile platform.'**
  String get perAppUnsupportedPlatform;

  /// No description provided for @targetBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get targetBlock;

  /// No description provided for @validateAndSave.
  ///
  /// In en, this message translates to:
  /// **'Validate and save'**
  String get validateAndSave;

  /// No description provided for @rulesTab.
  ///
  /// In en, this message translates to:
  /// **'Rules'**
  String get rulesTab;

  /// No description provided for @routingAndDns.
  ///
  /// In en, this message translates to:
  /// **'Routing and DNS'**
  String get routingAndDns;

  /// No description provided for @reduceRoutingDataHelp.
  ///
  /// In en, this message translates to:
  /// **'Applied when routing data refreshes. Keeps complete matching records and preserves originals; falls back to full files on failure.'**
  String get reduceRoutingDataHelp;

  /// No description provided for @reduceRoutingDataSize.
  ///
  /// In en, this message translates to:
  /// **'Reduce routing-data size'**
  String get reduceRoutingDataSize;

  /// No description provided for @resolveWhenNeeded.
  ///
  /// In en, this message translates to:
  /// **'Resolve when needed'**
  String get resolveWhenNeeded;

  /// No description provided for @resolveIfNoRuleMatches.
  ///
  /// In en, this message translates to:
  /// **'Resolve if no rule matches'**
  String get resolveIfNoRuleMatches;

  /// No description provided for @keepDomainNames.
  ///
  /// In en, this message translates to:
  /// **'Keep domain names'**
  String get keepDomainNames;

  /// No description provided for @resolveDomainsForRouting.
  ///
  /// In en, this message translates to:
  /// **'Resolve domains for routing'**
  String get resolveDomainsForRouting;

  /// No description provided for @ruleGroupOrder.
  ///
  /// In en, this message translates to:
  /// **'Rule group order'**
  String get ruleGroupOrder;

  /// No description provided for @profileName.
  ///
  /// In en, this message translates to:
  /// **'Profile name'**
  String get profileName;

  /// No description provided for @directDnsDomainsHint.
  ///
  /// In en, this message translates to:
  /// **'One domain, domain: suffix, full: name, or geosite: tag per line.'**
  String get directDnsDomainsHint;

  /// No description provided for @domainsUsingDirectDns.
  ///
  /// In en, this message translates to:
  /// **'Domains using direct DNS'**
  String get domainsUsingDirectDns;

  /// No description provided for @explicitDomainRulesHelp.
  ///
  /// In en, this message translates to:
  /// **'Matching domains use direct DNS; all others use remote DNS. Off preserves legacy ordered fallback. DoH bootstrap connects through the selected proxy.'**
  String get explicitDomainRulesHelp;

  /// No description provided for @useExplicitDomainRules.
  ///
  /// In en, this message translates to:
  /// **'Use explicit domain rules'**
  String get useExplicitDomainRules;

  /// No description provided for @chooseDnsByDomain.
  ///
  /// In en, this message translates to:
  /// **'Choose DNS by domain'**
  String get chooseDnsByDomain;

  /// No description provided for @resolverIp.
  ///
  /// In en, this message translates to:
  /// **'Resolver IP'**
  String get resolverIp;

  /// No description provided for @bootstrapIp.
  ///
  /// In en, this message translates to:
  /// **'Bootstrap IP'**
  String get bootstrapIp;

  /// No description provided for @resolverType.
  ///
  /// In en, this message translates to:
  /// **'Resolver type'**
  String get resolverType;

  /// No description provided for @remoteDns.
  ///
  /// In en, this message translates to:
  /// **'Remote DNS'**
  String get remoteDns;

  /// No description provided for @directDns.
  ///
  /// In en, this message translates to:
  /// **'Direct DNS'**
  String get directDns;

  /// No description provided for @keepDomainIdentityHelp.
  ///
  /// In en, this message translates to:
  /// **'Uses Fake DNS. With real DNS, domain rules depend on supported HTTP/TLS/QUIC sniffing; encrypted hostnames and other protocols may require IP rules.'**
  String get keepDomainIdentityHelp;

  /// No description provided for @keepDomainIdentity.
  ///
  /// In en, this message translates to:
  /// **'Keep domain identity for routing'**
  String get keepDomainIdentity;

  /// No description provided for @ipRulesHint.
  ///
  /// In en, this message translates to:
  /// **'One IPv4/IPv6 address, CIDR, or geoip: target per line.'**
  String get ipRulesHint;

  /// No description provided for @ipAddressesAndNetworks.
  ///
  /// In en, this message translates to:
  /// **'IP addresses and networks'**
  String get ipAddressesAndNetworks;

  /// No description provided for @domainRulesHint.
  ///
  /// In en, this message translates to:
  /// **'One domain, full:, domain:, regexp:, or geosite: target per line.'**
  String get domainRulesHint;

  /// No description provided for @domains.
  ///
  /// In en, this message translates to:
  /// **'Domains'**
  String get domains;

  /// No description provided for @addPreset.
  ///
  /// In en, this message translates to:
  /// **'Add preset'**
  String get addPreset;

  /// No description provided for @russianSitesPresetHelp.
  ///
  /// In en, this message translates to:
  /// **'.ru, .рф, .su and these services\' other domains'**
  String get russianSitesPresetHelp;

  /// No description provided for @russianSitesDirect.
  ///
  /// In en, this message translates to:
  /// **'Russian sites direct'**
  String get russianSitesDirect;

  /// No description provided for @connectDirectly.
  ///
  /// In en, this message translates to:
  /// **'Connect directly'**
  String get connectDirectly;

  /// No description provided for @unmatchedTraffic.
  ///
  /// In en, this message translates to:
  /// **'Unmatched traffic'**
  String get unmatchedTraffic;

  /// No description provided for @routingChangeFailed.
  ///
  /// In en, this message translates to:
  /// **'Routing change failed. The last working profile was kept.'**
  String get routingChangeFailed;

  /// No description provided for @routingIpTargetsInvalid.
  ///
  /// In en, this message translates to:
  /// **'{field} needs IP addresses, valid CIDRs, or geoip: references.'**
  String routingIpTargetsInvalid(String field);

  /// No description provided for @routingDnsNeedsResolver.
  ///
  /// In en, this message translates to:
  /// **'{dns} needs a resolver type and IP address.'**
  String routingDnsNeedsResolver(String dns);

  /// No description provided for @routingDnsNeedsHttpsUrl.
  ///
  /// In en, this message translates to:
  /// **'{dns} needs an HTTPS URL without credentials or a fragment.'**
  String routingDnsNeedsHttpsUrl(String dns);

  /// No description provided for @domesticDns.
  ///
  /// In en, this message translates to:
  /// **'Domestic DNS'**
  String get domesticDns;

  /// No description provided for @directRules.
  ///
  /// In en, this message translates to:
  /// **'Direct rules'**
  String get directRules;

  /// No description provided for @proxyRules.
  ///
  /// In en, this message translates to:
  /// **'Proxy rules'**
  String get proxyRules;

  /// No description provided for @blockRules.
  ///
  /// In en, this message translates to:
  /// **'Block rules'**
  String get blockRules;

  /// No description provided for @ruleGroupBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get ruleGroupBlock;

  /// No description provided for @ruleGroupDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get ruleGroupDirect;

  /// No description provided for @ruleGroupProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get ruleGroupProxy;

  /// No description provided for @httpsUrl.
  ///
  /// In en, this message translates to:
  /// **'HTTPS URL'**
  String get httpsUrl;

  /// No description provided for @routingProfilesNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Routing profiles could not be loaded.'**
  String get routingProfilesNotLoaded;

  /// No description provided for @connectionStoppedUnexpectedly.
  ///
  /// In en, this message translates to:
  /// **'Connection stopped unexpectedly. Reconnect to retry.'**
  String get connectionStoppedUnexpectedly;

  /// No description provided for @groupSelectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Group selection failed. The saved selection was restored.'**
  String get groupSelectionFailed;

  /// No description provided for @serverIpPreferenceNotApplied.
  ///
  /// In en, this message translates to:
  /// **'Could not apply the server IP preference.'**
  String get serverIpPreferenceNotApplied;

  /// No description provided for @telegramNotOpened.
  ///
  /// In en, this message translates to:
  /// **'Telegram could not be opened. Check that it is installed.'**
  String get telegramNotOpened;

  /// No description provided for @couldNotImport.
  ///
  /// In en, this message translates to:
  /// **'Could not import. Use a subscription link, client configuration, or routing profile.'**
  String get couldNotImport;

  /// No description provided for @selectServerFirstRoutingLink.
  ///
  /// In en, this message translates to:
  /// **'Select a server first. This routing link turns its profile on for the selected server’s subscription.'**
  String get selectServerFirstRoutingLink;

  /// No description provided for @unsupportedProfileTryJson.
  ///
  /// In en, this message translates to:
  /// **'This profile uses unsupported settings. Try the provider’s Xray JSON format.'**
  String get unsupportedProfileTryJson;

  /// No description provided for @subscriptionAddedFirstDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Subscription added, but the first download failed. Refresh to retry.'**
  String get subscriptionAddedFirstDownloadFailed;

  /// No description provided for @clipboardEmpty.
  ///
  /// In en, this message translates to:
  /// **'The clipboard is empty. Copy a link or configuration first.'**
  String get clipboardEmpty;

  /// No description provided for @downloadPageNotOpened.
  ///
  /// In en, this message translates to:
  /// **'The download page could not be opened.'**
  String get downloadPageNotOpened;

  /// No description provided for @providerLinkNotOpened.
  ///
  /// In en, this message translates to:
  /// **'The provider link could not be opened.'**
  String get providerLinkNotOpened;

  /// No description provided for @continueAction.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueAction;

  /// No description provided for @approveUnsafeSubscription.
  ///
  /// In en, this message translates to:
  /// **'Approve unsafe subscription?'**
  String get approveUnsafeSubscription;

  /// No description provided for @contactProvider.
  ///
  /// In en, this message translates to:
  /// **'Contact provider'**
  String get contactProvider;

  /// No description provided for @vpnSetupNotRepaired.
  ///
  /// In en, this message translates to:
  /// **'VPN setup could not be repaired.'**
  String get vpnSetupNotRepaired;

  /// No description provided for @vpnSetupReset.
  ///
  /// In en, this message translates to:
  /// **'VPN setup reset. Connect to try again.'**
  String get vpnSetupReset;

  /// No description provided for @repair.
  ///
  /// In en, this message translates to:
  /// **'Repair'**
  String get repair;

  /// No description provided for @repairVpnMacBody.
  ///
  /// In en, this message translates to:
  /// **'Stops the connection and removes the saved macOS VPN setup. Connect recreates it using your selected server and settings.'**
  String get repairVpnMacBody;

  /// No description provided for @repairVpnDesktopBody.
  ///
  /// In en, this message translates to:
  /// **'Stops the connection and closes the tunnel helper. On Windows it also removes a DNS block left by a helper that stopped unexpectedly, which asks for administrator permission. The next VPN connection starts a fresh helper and may ask for it too.'**
  String get repairVpnDesktopBody;

  /// No description provided for @repairVpnSetupQuestion.
  ///
  /// In en, this message translates to:
  /// **'Repair VPN setup?'**
  String get repairVpnSetupQuestion;

  /// No description provided for @favoriteNotSaved.
  ///
  /// In en, this message translates to:
  /// **'The favorite could not be saved. Try again.'**
  String get favoriteNotSaved;

  /// No description provided for @subscriptionsNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Subscriptions could not be loaded.'**
  String get subscriptionsNotLoaded;

  /// No description provided for @hideVpnIconBody.
  ///
  /// In en, this message translates to:
  /// **'This changes excluded network routes; it does not only hide interface chrome.'**
  String get hideVpnIconBody;

  /// No description provided for @hideVpnIconQuestion.
  ///
  /// In en, this message translates to:
  /// **'Hide VPN icon?'**
  String get hideVpnIconQuestion;

  /// No description provided for @settingNotApplied.
  ///
  /// In en, this message translates to:
  /// **'Setting could not be applied. {details}'**
  String settingNotApplied(Object details);

  /// No description provided for @settingNotAppliedCheck.
  ///
  /// In en, this message translates to:
  /// **'Setting could not be applied. Check the current settings and tunnel state before reconnecting.'**
  String get settingNotAppliedCheck;

  /// No description provided for @settingsReloaded.
  ///
  /// In en, this message translates to:
  /// **'Settings were reloaded. Make the change again.'**
  String get settingsReloaded;

  /// No description provided for @pingFailedForNode.
  ///
  /// In en, this message translates to:
  /// **'Ping failed for this node.'**
  String get pingFailedForNode;

  /// No description provided for @pingIcmpRestoreFailed.
  ///
  /// In en, this message translates to:
  /// **'ICMP finished, but the previous tunnel connection could not be restored.'**
  String get pingIcmpRestoreFailed;

  /// No description provided for @pingIcmpNoReplyRestored.
  ///
  /// In en, this message translates to:
  /// **'No ICMP reply. The previous tunnel connection was restored.'**
  String get pingIcmpNoReplyRestored;

  /// No description provided for @pingIcmpUnavailable.
  ///
  /// In en, this message translates to:
  /// **'ICMP is unavailable while system VPN is connected. Use TCP or HTTP testing.'**
  String get pingIcmpUnavailable;

  /// No description provided for @pingDirectTcpUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Skipped: Direct TCP is not supported by this endpoint’s transport. Use Proxy testing.'**
  String get pingDirectTcpUnsupported;

  /// No description provided for @pingNeedsDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Skipped: while connected, this test can’t reach the server. Disconnect to test it.'**
  String get pingNeedsDisconnect;

  /// No description provided for @routeTableUnreadable.
  ///
  /// In en, this message translates to:
  /// **'The current route table could not be read.'**
  String get routeTableUnreadable;

  /// No description provided for @systemInfoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'System information is unavailable.'**
  String get systemInfoUnavailable;

  /// No description provided for @systemSettingsNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'System settings could not be loaded.'**
  String get systemSettingsNotLoaded;

  /// No description provided for @allowWithoutLogin.
  ///
  /// In en, this message translates to:
  /// **'Allow without login'**
  String get allowWithoutLogin;

  /// No description provided for @allowWithoutLoginBody.
  ///
  /// In en, this message translates to:
  /// **'In local-proxy mode, any program on this device, including malware and other users\' programs, can then send traffic through your server on {ports}. LAN access turns off.'**
  String allowWithoutLoginBody(Object ports);

  /// No description provided for @allowAppsWithoutLogin.
  ///
  /// In en, this message translates to:
  /// **'Allow apps without a login?'**
  String get allowAppsWithoutLogin;

  /// No description provided for @portSingle.
  ///
  /// In en, this message translates to:
  /// **'port {port}'**
  String portSingle(Object port);

  /// No description provided for @portsPair.
  ///
  /// In en, this message translates to:
  /// **'ports {socks} and {http}'**
  String portsPair(Object socks, Object http);

  /// No description provided for @tunnelSettingsNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Tunnel settings could not be loaded.'**
  String get tunnelSettingsNotLoaded;

  /// No description provided for @chooseWritableLocation.
  ///
  /// In en, this message translates to:
  /// **'Choose a writable location and retry.'**
  String get chooseWritableLocation;

  /// No description provided for @diagnosticsNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics could not be saved.'**
  String get diagnosticsNotSaved;

  /// No description provided for @pingTested.
  ///
  /// In en, this message translates to:
  /// **'Tested {tested} of {total} nodes.'**
  String pingTested(int tested, int total);

  /// No description provided for @pingSkippedIncompatible.
  ///
  /// In en, this message translates to:
  /// **'Skipped {count}: incompatible with this test method.'**
  String pingSkippedIncompatible(int count);

  /// No description provided for @pingSkippedWhileConnected.
  ///
  /// In en, this message translates to:
  /// **'Skipped {count}: disconnect to test them.'**
  String pingSkippedWhileConnected(int count);

  /// No description provided for @refreshFailedSentence.
  ///
  /// In en, this message translates to:
  /// **'Refresh failed.'**
  String get refreshFailedSentence;

  /// No description provided for @lastWorkingServersKept.
  ///
  /// In en, this message translates to:
  /// **'The last working servers were kept.'**
  String get lastWorkingServersKept;

  /// No description provided for @catalogLimit.
  ///
  /// In en, this message translates to:
  /// **'Elarni keeps up to 1,024 subscriptions and 256 routing profiles. Delete some, then retry.'**
  String get catalogLimit;

  /// No description provided for @dismissMessage.
  ///
  /// In en, this message translates to:
  /// **'Dismiss message'**
  String get dismissMessage;

  /// No description provided for @addSubscriptionToStart.
  ///
  /// In en, this message translates to:
  /// **'Add a subscription or import a profile to get started.'**
  String get addSubscriptionToStart;

  /// No description provided for @noSubscriptionsYet.
  ///
  /// In en, this message translates to:
  /// **'No subscriptions yet'**
  String get noSubscriptionsYet;

  /// No description provided for @refreshProfiles.
  ///
  /// In en, this message translates to:
  /// **'Refresh profiles'**
  String get refreshProfiles;

  /// No description provided for @routeTableHelp.
  ///
  /// In en, this message translates to:
  /// **'Current numeric IPv4 and IPv6 routes.'**
  String get routeTableHelp;

  /// No description provided for @openServerList.
  ///
  /// In en, this message translates to:
  /// **'Open server list'**
  String get openServerList;

  /// No description provided for @expectedBodyHelp.
  ///
  /// In en, this message translates to:
  /// **'Exact text; leave empty for HTTP 204 or HEAD.'**
  String get expectedBodyHelp;

  /// No description provided for @expectedResponseBody.
  ///
  /// In en, this message translates to:
  /// **'Expected response body'**
  String get expectedResponseBody;

  /// No description provided for @testUrl.
  ///
  /// In en, this message translates to:
  /// **'Test URL'**
  String get testUrl;

  /// No description provided for @httpRequest.
  ///
  /// In en, this message translates to:
  /// **'HTTP request'**
  String get httpRequest;

  /// No description provided for @secondsTimeout.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s timeout'**
  String secondsTimeout(Object seconds);

  /// No description provided for @timeout.
  ///
  /// In en, this message translates to:
  /// **'Timeout'**
  String get timeout;

  /// No description provided for @testMode.
  ///
  /// In en, this message translates to:
  /// **'Test mode'**
  String get testMode;

  /// No description provided for @httpMethod.
  ///
  /// In en, this message translates to:
  /// **'HTTP method'**
  String get httpMethod;

  /// No description provided for @currentRulesActiveTunnel.
  ///
  /// In en, this message translates to:
  /// **'Current rules / active tunnel'**
  String get currentRulesActiveTunnel;

  /// No description provided for @testType.
  ///
  /// In en, this message translates to:
  /// **'Test type'**
  String get testType;

  /// No description provided for @refreshingEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Refreshing…'**
  String get refreshingEllipsis;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @exportDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Export diagnostics'**
  String get exportDiagnostics;

  /// No description provided for @troubleshootConnection.
  ///
  /// In en, this message translates to:
  /// **'Troubleshoot connection'**
  String get troubleshootConnection;

  /// No description provided for @versions.
  ///
  /// In en, this message translates to:
  /// **'Versions'**
  String get versions;

  /// No description provided for @xrayCoreVersion.
  ///
  /// In en, this message translates to:
  /// **'Xray core {version}'**
  String xrayCoreVersion(Object version);

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get unavailable;

  /// No description provided for @physicalMemory.
  ///
  /// In en, this message translates to:
  /// **'Physical memory'**
  String get physicalMemory;

  /// No description provided for @activeCpus.
  ///
  /// In en, this message translates to:
  /// **'Active CPUs'**
  String get activeCpus;

  /// No description provided for @cpuCount.
  ///
  /// In en, this message translates to:
  /// **'CPU count'**
  String get cpuCount;

  /// No description provided for @appArchitecture.
  ///
  /// In en, this message translates to:
  /// **'App architecture'**
  String get appArchitecture;

  /// No description provided for @operatingSystem.
  ///
  /// In en, this message translates to:
  /// **'Operating system'**
  String get operatingSystem;

  /// No description provided for @repairVpnSetup.
  ///
  /// In en, this message translates to:
  /// **'Repair VPN setup'**
  String get repairVpnSetup;

  /// No description provided for @reviewRepair.
  ///
  /// In en, this message translates to:
  /// **'Review repair'**
  String get reviewRepair;

  /// No description provided for @connectionRepair.
  ///
  /// In en, this message translates to:
  /// **'Connection repair'**
  String get connectionRepair;

  /// No description provided for @restoreBackupHelp.
  ///
  /// In en, this message translates to:
  /// **'Disconnect before replacing saved profiles and routing.'**
  String get restoreBackupHelp;

  /// No description provided for @restoreBackup.
  ///
  /// In en, this message translates to:
  /// **'Restore backup'**
  String get restoreBackup;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @createEncryptedBackup.
  ///
  /// In en, this message translates to:
  /// **'Create encrypted backup'**
  String get createEncryptedBackup;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @backups.
  ///
  /// In en, this message translates to:
  /// **'Backups'**
  String get backups;

  /// No description provided for @showMonitoringOnMain.
  ///
  /// In en, this message translates to:
  /// **'Show monitoring on main screen'**
  String get showMonitoringOnMain;

  /// No description provided for @monitoring.
  ///
  /// In en, this message translates to:
  /// **'Monitoring'**
  String get monitoring;

  /// No description provided for @enableSniffing.
  ///
  /// In en, this message translates to:
  /// **'Enable sniffing'**
  String get enableSniffing;

  /// No description provided for @udpMaxConnections.
  ///
  /// In en, this message translates to:
  /// **'UDP max connections'**
  String get udpMaxConnections;

  /// No description provided for @tcpMaxConnections.
  ///
  /// In en, this message translates to:
  /// **'TCP max connections'**
  String get tcpMaxConnections;

  /// No description provided for @connectionIdleTimeout.
  ///
  /// In en, this message translates to:
  /// **'Connection idle timeout (seconds)'**
  String get connectionIdleTimeout;

  /// No description provided for @xrayMemoryLimit.
  ///
  /// In en, this message translates to:
  /// **'Xray memory limit (MB)'**
  String get xrayMemoryLimit;

  /// No description provided for @resources.
  ///
  /// In en, this message translates to:
  /// **'Resources'**
  String get resources;

  /// No description provided for @defaultMuxHelp.
  ///
  /// In en, this message translates to:
  /// **'Imported mux settings take precedence. This preference applies only to VLESS; it does not enable mux for Hysteria.'**
  String get defaultMuxHelp;

  /// No description provided for @enableDefaultVlessMux.
  ///
  /// In en, this message translates to:
  /// **'Enable default VLESS mux'**
  String get enableDefaultVlessMux;

  /// No description provided for @fragmentationSummary.
  ///
  /// In en, this message translates to:
  /// **'{packets} · {length} bytes · {interval} ms'**
  String fragmentationSummary(Object packets, Object length, Object interval);

  /// No description provided for @fragmentationOptions.
  ///
  /// In en, this message translates to:
  /// **'Fragmentation options'**
  String get fragmentationOptions;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @fragmentationHelp.
  ///
  /// In en, this message translates to:
  /// **'VLESS over TCP or XHTTP with TLS or Reality. XHTTP over HTTP/3 and existing dialer chains are unsupported.'**
  String get fragmentationHelp;

  /// No description provided for @enableFragmentation.
  ///
  /// In en, this message translates to:
  /// **'Enable fragmentation'**
  String get enableFragmentation;

  /// No description provided for @transport.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get transport;

  /// No description provided for @resolveServerHelp.
  ///
  /// In en, this message translates to:
  /// **'Keeps server IP addresses fixed until reconnect while preserving TLS names and transport headers.'**
  String get resolveServerHelp;

  /// No description provided for @resolveServerBeforeConnecting.
  ///
  /// In en, this message translates to:
  /// **'Resolve server before connecting'**
  String get resolveServerBeforeConnecting;

  /// No description provided for @noEnabledRoutingProfiles.
  ///
  /// In en, this message translates to:
  /// **'No enabled routing profiles. Enable a profile in Routing.'**
  String get noEnabledRoutingProfiles;

  /// No description provided for @editDns.
  ///
  /// In en, this message translates to:
  /// **'Edit DNS'**
  String get editDns;

  /// No description provided for @routingProfiles.
  ///
  /// In en, this message translates to:
  /// **'Routing profiles'**
  String get routingProfiles;

  /// No description provided for @routingProfile.
  ///
  /// In en, this message translates to:
  /// **'Routing profile'**
  String get routingProfile;

  /// No description provided for @providerProfile.
  ///
  /// In en, this message translates to:
  /// **'Provider profile'**
  String get providerProfile;

  /// No description provided for @dnsSettingsHelp.
  ///
  /// In en, this message translates to:
  /// **'Choose which profile supplies DNS settings.'**
  String get dnsSettingsHelp;

  /// No description provided for @dnsSettings.
  ///
  /// In en, this message translates to:
  /// **'DNS settings'**
  String get dnsSettings;

  /// No description provided for @allowLanHelp.
  ///
  /// In en, this message translates to:
  /// **'Requires authentication. Use a trusted LAN: SOCKS5 and HTTP authentication do not encrypt the client connection.'**
  String get allowLanHelp;

  /// No description provided for @allowLan.
  ///
  /// In en, this message translates to:
  /// **'Allow LAN connections (IPv4)'**
  String get allowLan;

  /// No description provided for @requireProxyAuthHelp.
  ///
  /// In en, this message translates to:
  /// **'Both listeners use the saved credentials. Disabling authentication also disables LAN access.'**
  String get requireProxyAuthHelp;

  /// No description provided for @requireProxyAuth.
  ///
  /// In en, this message translates to:
  /// **'Require SOCKS5 and HTTP authentication'**
  String get requireProxyAuth;

  /// No description provided for @allowAppsWithoutLoginHelp.
  ///
  /// In en, this message translates to:
  /// **'In local-proxy mode, any program on this device could then use your proxy and your server. With the VPN on, the listeners still need a login. Also disables LAN access.'**
  String get allowAppsWithoutLoginHelp;

  /// No description provided for @allowAppsWithoutLoginToggle.
  ///
  /// In en, this message translates to:
  /// **'Allow apps without a login'**
  String get allowAppsWithoutLoginToggle;

  /// No description provided for @set.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get set;

  /// No description provided for @change.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get change;

  /// No description provided for @hide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get hide;

  /// No description provided for @show.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get show;

  /// No description provided for @notConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get notConfigured;

  /// No description provided for @proxyLoginHelp.
  ///
  /// In en, this message translates to:
  /// **'Apps that use the SOCKS5 or HTTP proxy sign in with this username and password.'**
  String get proxyLoginHelp;

  /// No description provided for @proxyLogin.
  ///
  /// In en, this message translates to:
  /// **'Proxy login'**
  String get proxyLogin;

  /// No description provided for @listenersHelp.
  ///
  /// In en, this message translates to:
  /// **'Listeners run while the tunnel is active on either backend. With the VPN on they always require a login: your saved credentials when authentication is on, otherwise a random one per connection, so other apps cannot use them.'**
  String get listenersHelp;

  /// No description provided for @socksAndHttpPorts.
  ///
  /// In en, this message translates to:
  /// **'SOCKS5 and HTTP ports'**
  String get socksAndHttpPorts;

  /// No description provided for @httpInbound.
  ///
  /// In en, this message translates to:
  /// **'HTTP inbound'**
  String get httpInbound;

  /// No description provided for @useAppDefault.
  ///
  /// In en, this message translates to:
  /// **'Use app default'**
  String get useAppDefault;

  /// No description provided for @serverIpType.
  ///
  /// In en, this message translates to:
  /// **'Server IP type'**
  String get serverIpType;

  /// No description provided for @shareLinkServers.
  ///
  /// In en, this message translates to:
  /// **'Share-link servers'**
  String get shareLinkServers;

  /// No description provided for @defaultIpTypeHelp.
  ///
  /// In en, this message translates to:
  /// **'Used by servers without an override.'**
  String get defaultIpTypeHelp;

  /// No description provided for @defaultIpType.
  ///
  /// In en, this message translates to:
  /// **'Default IP type'**
  String get defaultIpType;

  /// No description provided for @serverAddressing.
  ///
  /// In en, this message translates to:
  /// **'Server addressing'**
  String get serverAddressing;

  /// No description provided for @blockTrafficMacHelp.
  ///
  /// In en, this message translates to:
  /// **'macOS keeps all traffic inside the tunnel, including while it reconnects. Route exclusions do not apply.'**
  String get blockTrafficMacHelp;

  /// No description provided for @blockTrafficDesktopHelp.
  ///
  /// In en, this message translates to:
  /// **'If the VPN stops unexpectedly, nothing leaves this device outside it until you reconnect or use Repair VPN setup. Disconnecting lifts the block. Needs System-wide VPN; cannot be combined with Enforce tunnel routes.'**
  String get blockTrafficDesktopHelp;

  /// No description provided for @blockTrafficWithoutVpn.
  ///
  /// In en, this message translates to:
  /// **'Block traffic without VPN'**
  String get blockTrafficWithoutVpn;

  /// No description provided for @connectWithoutAdminApprovalHelp.
  ///
  /// In en, this message translates to:
  /// **'The Elarni VPN service starts the VPN helper for this Windows account, so connecting asks for no approval. Turning this on or off asks for approval once.'**
  String get connectWithoutAdminApprovalHelp;

  /// No description provided for @connectWithoutAdminApproval.
  ///
  /// In en, this message translates to:
  /// **'Connect without administrator approval'**
  String get connectWithoutAdminApproval;

  /// No description provided for @accentColor.
  ///
  /// In en, this message translates to:
  /// **'Accent color'**
  String get accentColor;

  /// No description provided for @dark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get dark;

  /// No description provided for @light.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get light;

  /// No description provided for @followSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get followSystem;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// This language's own name, shown in the language list.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageName;

  /// No description provided for @feedUnreadable.
  ///
  /// In en, this message translates to:
  /// **'The feed could not be read.'**
  String get feedUnreadable;

  /// No description provided for @upToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get upToDate;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Elarni {version} is available'**
  String updateAvailable(Object version);

  /// No description provided for @updateFeedHelp.
  ///
  /// In en, this message translates to:
  /// **'Elarni reads this address once a day and shows a notice on Home when it names a newer release. It never downloads or installs anything. Use a JSON file with \"version\" and \"url\", or a GitHub releases/latest API address; https only.'**
  String get updateFeedHelp;

  /// No description provided for @updateFeed.
  ///
  /// In en, this message translates to:
  /// **'Update feed'**
  String get updateFeed;

  /// No description provided for @updates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get updates;

  /// No description provided for @favoritesFirst.
  ///
  /// In en, this message translates to:
  /// **'Favorites first'**
  String get favoritesFirst;

  /// No description provided for @alphabetical.
  ///
  /// In en, this message translates to:
  /// **'Alphabetical'**
  String get alphabetical;

  /// No description provided for @providerOrder.
  ///
  /// In en, this message translates to:
  /// **'Provider order'**
  String get providerOrder;

  /// No description provided for @serverOrder.
  ///
  /// In en, this message translates to:
  /// **'Server order'**
  String get serverOrder;

  /// No description provided for @subscriptionExpiryRemindersHelp.
  ///
  /// In en, this message translates to:
  /// **'Once a day while Elarni is running, when a subscription expires within three days.'**
  String get subscriptionExpiryRemindersHelp;

  /// No description provided for @subscriptionExpiryReminders.
  ///
  /// In en, this message translates to:
  /// **'Subscription expiry reminders'**
  String get subscriptionExpiryReminders;

  /// No description provided for @subscriptionAutoUpdateHelp.
  ///
  /// In en, this message translates to:
  /// **'Updates all subscriptions while Elarni is running. Default: 4 hours.'**
  String get subscriptionAutoUpdateHelp;

  /// No description provided for @subscriptionAutoUpdateHours.
  ///
  /// In en, this message translates to:
  /// **'Subscription auto-update (hours)'**
  String get subscriptionAutoUpdateHours;

  /// No description provided for @macDisconnectsWhenSleeping.
  ///
  /// In en, this message translates to:
  /// **'macOS disconnects when sleeping.'**
  String get macDisconnectsWhenSleeping;

  /// No description provided for @disconnectsWhenSleeps.
  ///
  /// In en, this message translates to:
  /// **'Disconnects when {platform} sleeps.'**
  String disconnectsWhenSleeps(Object platform);

  /// No description provided for @disconnectOnSleep.
  ///
  /// In en, this message translates to:
  /// **'Disconnect on sleep'**
  String get disconnectOnSleep;

  /// No description provided for @loginStateUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Registration state is unavailable.'**
  String get loginStateUnavailable;

  /// No description provided for @loginApprovalRequired.
  ///
  /// In en, this message translates to:
  /// **'Approval is required in macOS Login Items settings.'**
  String get loginApprovalRequired;

  /// No description provided for @launchAtLogin.
  ///
  /// In en, this message translates to:
  /// **'Launch app at login'**
  String get launchAtLogin;

  /// No description provided for @windowsWifiLocationHelp.
  ///
  /// In en, this message translates to:
  /// **'Windows keeps the Wi-Fi name from Elarni. Turn on Location services and Let desktop apps access your location in Settings › Privacy & security › Location.'**
  String get windowsWifiLocationHelp;

  /// No description provided for @noTrustedWifi.
  ///
  /// In en, this message translates to:
  /// **'None. Every Wi-Fi network connects.'**
  String get noTrustedWifi;

  /// No description provided for @trustedWifiNetworks.
  ///
  /// In en, this message translates to:
  /// **'Trusted Wi-Fi networks'**
  String get trustedWifiNetworks;

  /// No description provided for @untrustedWifiMacHelp.
  ///
  /// In en, this message translates to:
  /// **'Joining a Wi-Fi network that is not on your trusted list connects, even before you press Connect. Trusted networks and wired connections leave the VPN as it is. Disconnect pauses this until your next Connect.'**
  String get untrustedWifiMacHelp;

  /// No description provided for @untrustedWifiDesktopHelp.
  ///
  /// In en, this message translates to:
  /// **'Joining a Wi-Fi network that is not on your trusted list connects. Trusted networks, wired and mobile connections, and a connection you stopped stay as they are until the next network.'**
  String get untrustedWifiDesktopHelp;

  /// No description provided for @connectOnUntrustedWifi.
  ///
  /// In en, this message translates to:
  /// **'Connect on untrusted Wi-Fi'**
  String get connectOnUntrustedWifi;

  /// No description provided for @onDemandMacHelp.
  ///
  /// In en, this message translates to:
  /// **'On Demand controls automatic connection when network access resumes.'**
  String get onDemandMacHelp;

  /// No description provided for @onDemand.
  ///
  /// In en, this message translates to:
  /// **'On Demand'**
  String get onDemand;

  /// No description provided for @recoveryBackupsSummary.
  ///
  /// In en, this message translates to:
  /// **'Use only your allowed backup servers.'**
  String get recoveryBackupsSummary;

  /// No description provided for @recoveryFixedSummary.
  ///
  /// In en, this message translates to:
  /// **'Reconnect to the selected server only.'**
  String get recoveryFixedSummary;

  /// No description provided for @recoveryOffSummary.
  ///
  /// In en, this message translates to:
  /// **'Off. Your server choice is preserved.'**
  String get recoveryOffSummary;

  /// No description provided for @configure.
  ///
  /// In en, this message translates to:
  /// **'Configure'**
  String get configure;

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// No description provided for @excludedRoutes.
  ///
  /// In en, this message translates to:
  /// **'Excluded routes'**
  String get excludedRoutes;

  /// No description provided for @includedRoutes.
  ///
  /// In en, this message translates to:
  /// **'Included routes'**
  String get includedRoutes;

  /// No description provided for @compatibilityRouteExclusionsHelp.
  ///
  /// In en, this message translates to:
  /// **'Adds route exclusions used by the hide-icon workaround. Hiding the VPN icon is not verified.'**
  String get compatibilityRouteExclusionsHelp;

  /// No description provided for @compatibilityRouteExclusions.
  ///
  /// In en, this message translates to:
  /// **'Compatibility route exclusions'**
  String get compatibilityRouteExclusions;

  /// No description provided for @includeAllNetworksHelp.
  ///
  /// In en, this message translates to:
  /// **'VPN routes apply in System VPN mode. Include all networks captures both IP families and respects your exclusions.'**
  String get includeAllNetworksHelp;

  /// No description provided for @includeAllNetworks.
  ///
  /// In en, this message translates to:
  /// **'Include all networks'**
  String get includeAllNetworks;

  /// No description provided for @enforceRoutesMacHelp.
  ///
  /// In en, this message translates to:
  /// **'Enforcement requires specific included routes; default routes such as 0.0.0.0/0 and ::/0 are unsupported. For a full tunnel, turn enforcement off and use Block traffic without VPN in Connection settings.'**
  String get enforceRoutesMacHelp;

  /// No description provided for @enforceRoutesDesktopHelp.
  ///
  /// In en, this message translates to:
  /// **'VPN routes apply in System VPN mode. Enforcement blocks physical bypass of specific included routes while connected.'**
  String get enforceRoutesDesktopHelp;

  /// No description provided for @enforceTunnelRoutes.
  ///
  /// In en, this message translates to:
  /// **'Enforce tunnel routes'**
  String get enforceTunnelRoutes;

  /// No description provided for @advancedNetworkRoutes.
  ///
  /// In en, this message translates to:
  /// **'Advanced network routes'**
  String get advancedNetworkRoutes;

  /// No description provided for @memoryLimitAutomatic.
  ///
  /// In en, this message translates to:
  /// **'automatic'**
  String get memoryLimitAutomatic;

  /// No description provided for @megabytesValue.
  ///
  /// In en, this message translates to:
  /// **'{value} MB'**
  String megabytesValue(String value);

  /// No description provided for @gigabytesValue.
  ///
  /// In en, this message translates to:
  /// **'{value} GB'**
  String gigabytesValue(String value);

  /// No description provided for @extensionMemory.
  ///
  /// In en, this message translates to:
  /// **'Extension RSS: {value} MB'**
  String extensionMemory(String value);

  /// No description provided for @xrayHeap.
  ///
  /// In en, this message translates to:
  /// **'Xray heap: {heap} MB / {limit}'**
  String xrayHeap(String heap, String limit);

  /// No description provided for @softLimit.
  ///
  /// In en, this message translates to:
  /// **'(soft limit)'**
  String get softLimit;

  /// No description provided for @sessionsSummary.
  ///
  /// In en, this message translates to:
  /// **'Sessions: {tcp} TCP / {udp} UDP'**
  String sessionsSummary(Object tcp, Object udp);

  /// No description provided for @trafficSummary.
  ///
  /// In en, this message translates to:
  /// **'Traffic: {up} up / {down} down bytes'**
  String trafficSummary(Object up, Object down);

  /// No description provided for @packetsSummary.
  ///
  /// In en, this message translates to:
  /// **'Packets: {incoming} in / {outgoing} out'**
  String packetsSummary(Object incoming, Object outgoing);

  /// No description provided for @listenersSummary.
  ///
  /// In en, this message translates to:
  /// **'Configured {scope}: SOCKS5 {socks}; HTTP {http}.'**
  String listenersSummary(String scope, Object socks, String http);

  /// No description provided for @listenLan.
  ///
  /// In en, this message translates to:
  /// **'LAN IPv4'**
  String get listenLan;

  /// No description provided for @listenLoopback.
  ///
  /// In en, this message translates to:
  /// **'loopback'**
  String get listenLoopback;

  /// No description provided for @httpOff.
  ///
  /// In en, this message translates to:
  /// **'off'**
  String get httpOff;

  /// No description provided for @testModeDouble.
  ///
  /// In en, this message translates to:
  /// **'Double'**
  String get testModeDouble;

  /// No description provided for @testModeDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get testModeDefault;

  /// No description provided for @proxyHead.
  ///
  /// In en, this message translates to:
  /// **'Proxy HEAD'**
  String get proxyHead;

  /// No description provided for @proxyGet.
  ///
  /// In en, this message translates to:
  /// **'Proxy GET'**
  String get proxyGet;

  /// No description provided for @directIcmp.
  ///
  /// In en, this message translates to:
  /// **'Direct ICMP'**
  String get directIcmp;

  /// No description provided for @directTcp.
  ///
  /// In en, this message translates to:
  /// **'Direct TCP'**
  String get directTcp;

  /// No description provided for @testThroughProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get testThroughProxy;

  /// No description provided for @automatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get automatic;

  /// No description provided for @useProfile.
  ///
  /// In en, this message translates to:
  /// **'Use profile'**
  String get useProfile;

  /// No description provided for @loginServiceNotFound.
  ///
  /// In en, this message translates to:
  /// **'macOS could not find this app as a login service.'**
  String get loginServiceNotFound;

  /// No description provided for @loginNotRegistered.
  ///
  /// In en, this message translates to:
  /// **'Not registered.'**
  String get loginNotRegistered;

  /// No description provided for @loginRegistered.
  ///
  /// In en, this message translates to:
  /// **'Registered for your account.'**
  String get loginRegistered;

  /// No description provided for @searchServers.
  ///
  /// In en, this message translates to:
  /// **'Search servers'**
  String get searchServers;

  /// No description provided for @filterRecent.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get filterRecent;

  /// No description provided for @filterFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get filterFavorites;

  /// No description provided for @filterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// No description provided for @servers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get servers;

  /// No description provided for @showAgain.
  ///
  /// In en, this message translates to:
  /// **'Show again'**
  String get showAgain;

  /// No description provided for @hiddenServersCount.
  ///
  /// In en, this message translates to:
  /// **'Hidden servers · {count}'**
  String hiddenServersCount(int count);

  /// No description provided for @noMatchingServers.
  ///
  /// In en, this message translates to:
  /// **'No matching servers'**
  String get noMatchingServers;

  /// No description provided for @noServersInSubscription.
  ///
  /// In en, this message translates to:
  /// **'No servers in this subscription'**
  String get noServersInSubscription;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @selectUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Select unreachable'**
  String get selectUnreachable;

  /// No description provided for @selectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String selectedCount(int count);

  /// No description provided for @setByYourProvider.
  ///
  /// In en, this message translates to:
  /// **'Set by your provider'**
  String get setByYourProvider;

  /// No description provided for @noCustomRouting.
  ///
  /// In en, this message translates to:
  /// **'No custom routing'**
  String get noCustomRouting;

  /// No description provided for @refreshNamed.
  ///
  /// In en, this message translates to:
  /// **'Refresh {name}'**
  String refreshNamed(Object name);

  /// No description provided for @accountDisabled.
  ///
  /// In en, this message translates to:
  /// **'Account disabled'**
  String get accountDisabled;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @shareLinksFormat.
  ///
  /// In en, this message translates to:
  /// **'Share links'**
  String get shareLinksFormat;

  /// No description provided for @originalSubscription.
  ///
  /// In en, this message translates to:
  /// **'Original subscription'**
  String get originalSubscription;

  /// No description provided for @subscriptionFormat.
  ///
  /// In en, this message translates to:
  /// **'Subscription format'**
  String get subscriptionFormat;

  /// No description provided for @downloadOptions.
  ///
  /// In en, this message translates to:
  /// **'Download options'**
  String get downloadOptions;

  /// No description provided for @shareSubscription.
  ///
  /// In en, this message translates to:
  /// **'Share subscription'**
  String get shareSubscription;

  /// No description provided for @accountDetails.
  ///
  /// In en, this message translates to:
  /// **'Account details'**
  String get accountDetails;

  /// No description provided for @providerSupport.
  ///
  /// In en, this message translates to:
  /// **'Provider support'**
  String get providerSupport;

  /// No description provided for @pinSubscription.
  ///
  /// In en, this message translates to:
  /// **'Pin subscription'**
  String get pinSubscription;

  /// No description provided for @unpinSubscription.
  ///
  /// In en, this message translates to:
  /// **'Unpin subscription'**
  String get unpinSubscription;

  /// No description provided for @subscriptionActions.
  ///
  /// In en, this message translates to:
  /// **'Subscription actions'**
  String get subscriptionActions;

  /// No description provided for @testSubscriptionNodes.
  ///
  /// In en, this message translates to:
  /// **'Test this subscription’s nodes'**
  String get testSubscriptionNodes;

  /// No description provided for @testAllNodes.
  ///
  /// In en, this message translates to:
  /// **'Test all nodes'**
  String get testAllNodes;

  /// No description provided for @useNodePingForIcmp.
  ///
  /// In en, this message translates to:
  /// **'Use a node’s Ping button for ICMP'**
  String get useNodePingForIcmp;

  /// No description provided for @testing.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get testing;

  /// No description provided for @otherLocations.
  ///
  /// In en, this message translates to:
  /// **'Other locations'**
  String get otherLocations;

  /// No description provided for @lowestLatencySemantics.
  ///
  /// In en, this message translates to:
  /// **'{ms, plural, other{Lowest latency: {ms} milliseconds}}'**
  String lowestLatencySemantics(int ms);

  /// No description provided for @clearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get clearSearch;

  /// No description provided for @noServersYet.
  ///
  /// In en, this message translates to:
  /// **'No servers yet'**
  String get noServersYet;

  /// No description provided for @showAllServers.
  ///
  /// In en, this message translates to:
  /// **'Show all servers'**
  String get showAllServers;

  /// No description provided for @noSuccessfulConnections.
  ///
  /// In en, this message translates to:
  /// **'No successful connections yet'**
  String get noSuccessfulConnections;

  /// No description provided for @noFavoriteServers.
  ///
  /// In en, this message translates to:
  /// **'No favorite servers'**
  String get noFavoriteServers;

  /// No description provided for @onboardingStep3Proxy.
  ///
  /// In en, this message translates to:
  /// **'Press Connect. Only apps set to use the local proxy go through it; turn on System-wide VPN in Settings > Connection to connect all apps.'**
  String get onboardingStep3Proxy;

  /// No description provided for @onboardingStep3Vpn.
  ///
  /// In en, this message translates to:
  /// **'Press Connect. Administrator approval is requested on the first VPN connection in this app session.'**
  String get onboardingStep3Vpn;

  /// No description provided for @onboardingStep3Mac.
  ///
  /// In en, this message translates to:
  /// **'Press Connect. macOS asks once to allow the VPN configuration.'**
  String get onboardingStep3Mac;

  /// No description provided for @openFile.
  ///
  /// In en, this message translates to:
  /// **'Open file'**
  String get openFile;

  /// No description provided for @pasteLink.
  ///
  /// In en, this message translates to:
  /// **'Paste link'**
  String get pasteLink;

  /// No description provided for @onboardingStep2.
  ///
  /// In en, this message translates to:
  /// **'Add it here.'**
  String get onboardingStep2;

  /// No description provided for @onboardingStep1.
  ///
  /// In en, this message translates to:
  /// **'Get a subscription link or QR code from your provider. Elarni has no servers of its own.'**
  String get onboardingStep1;

  /// No description provided for @onboardingTitle.
  ///
  /// In en, this message translates to:
  /// **'Get connected in three steps'**
  String get onboardingTitle;

  /// No description provided for @serverActions.
  ///
  /// In en, this message translates to:
  /// **'Server actions'**
  String get serverActions;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @openInTelegram.
  ///
  /// In en, this message translates to:
  /// **'Open in Telegram'**
  String get openInTelegram;

  /// No description provided for @checkExit.
  ///
  /// In en, this message translates to:
  /// **'Check exit'**
  String get checkExit;

  /// No description provided for @checking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get checking;

  /// No description provided for @serverConfig.
  ///
  /// In en, this message translates to:
  /// **'Server config'**
  String get serverConfig;

  /// No description provided for @exitMismatch.
  ///
  /// In en, this message translates to:
  /// **'{server}\'s name says {named}, but its exit is in {exit}.'**
  String exitMismatch(Object server, Object named, Object exit);

  /// No description provided for @addFavorite.
  ///
  /// In en, this message translates to:
  /// **'Add favorite'**
  String get addFavorite;

  /// No description provided for @removeFavorite.
  ///
  /// In en, this message translates to:
  /// **'Remove favorite'**
  String get removeFavorite;

  /// No description provided for @unknownLocation.
  ///
  /// In en, this message translates to:
  /// **'Unknown location'**
  String get unknownLocation;

  /// No description provided for @selectNamed.
  ///
  /// In en, this message translates to:
  /// **'Select {name}'**
  String selectNamed(Object name);

  /// No description provided for @deleteServer.
  ///
  /// In en, this message translates to:
  /// **'Delete server'**
  String get deleteServer;

  /// No description provided for @hideServer.
  ///
  /// In en, this message translates to:
  /// **'Hide server'**
  String get hideServer;

  /// No description provided for @renameServer.
  ///
  /// In en, this message translates to:
  /// **'Rename server'**
  String get renameServer;

  /// No description provided for @ping.
  ///
  /// In en, this message translates to:
  /// **'Ping'**
  String get ping;

  /// No description provided for @skipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get skipped;

  /// No description provided for @localProxyMode.
  ///
  /// In en, this message translates to:
  /// **'Local proxy mode'**
  String get localProxyMode;

  /// No description provided for @selectServerToConnect.
  ///
  /// In en, this message translates to:
  /// **'Select a server to get connected.'**
  String get selectServerToConnect;

  /// No description provided for @chooseServer.
  ///
  /// In en, this message translates to:
  /// **'Choose a server'**
  String get chooseServer;

  /// No description provided for @stateConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get stateConnectionFailed;

  /// No description provided for @stateReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get stateReconnecting;

  /// No description provided for @stateDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting…'**
  String get stateDisconnecting;

  /// No description provided for @stateConnectedNoTraffic.
  ///
  /// In en, this message translates to:
  /// **'Connected · no traffic'**
  String get stateConnectedNoTraffic;

  /// No description provided for @stateConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get stateConnected;

  /// No description provided for @stateConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get stateConnecting;

  /// No description provided for @statePreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing…'**
  String get statePreparing;

  /// No description provided for @stateReadyToConnect.
  ///
  /// In en, this message translates to:
  /// **'Ready to connect'**
  String get stateReadyToConnect;

  /// No description provided for @stateDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get stateDisconnected;

  /// No description provided for @connectionStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Connection status unavailable'**
  String get connectionStatusUnavailable;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @notNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get notNow;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @requireLogin.
  ///
  /// In en, this message translates to:
  /// **'Require a login'**
  String get requireLogin;

  /// No description provided for @anyProgramCanUseProxy.
  ///
  /// In en, this message translates to:
  /// **'Any program on this device can use it.'**
  String get anyProgramCanUseProxy;

  /// No description provided for @localProxyWithoutLogin.
  ///
  /// In en, this message translates to:
  /// **'Your local proxy accepts apps without a login'**
  String get localProxyWithoutLogin;

  /// No description provided for @liftBlock.
  ///
  /// In en, this message translates to:
  /// **'Lift block'**
  String get liftBlock;

  /// No description provided for @reconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get reconnect;

  /// No description provided for @connectionStoppedUnexpectedlyShort.
  ///
  /// In en, this message translates to:
  /// **'The connection stopped unexpectedly.'**
  String get connectionStoppedUnexpectedlyShort;

  /// No description provided for @trafficBlockedUntilReconnect.
  ///
  /// In en, this message translates to:
  /// **'Traffic blocked until you reconnect'**
  String get trafficBlockedUntilReconnect;

  /// No description provided for @deleteProfileAndRulesQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete {name} and its rules?'**
  String deleteProfileAndRulesQuestion(Object name);

  /// No description provided for @deleteRoutingProfileQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete routing profile?'**
  String get deleteRoutingProfileQuestion;

  /// No description provided for @reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// No description provided for @replaceEditsQuestion.
  ///
  /// In en, this message translates to:
  /// **'Replace your edits to {name} with the subscription version?'**
  String replaceEditsQuestion(Object name);

  /// No description provided for @resetRoutingProfileQuestion.
  ///
  /// In en, this message translates to:
  /// **'Reset routing profile?'**
  String get resetRoutingProfileQuestion;

  /// No description provided for @resetToSubscriptionVersion.
  ///
  /// In en, this message translates to:
  /// **'Reset to subscription version'**
  String get resetToSubscriptionVersion;

  /// No description provided for @duplicate.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get duplicate;

  /// No description provided for @editJson.
  ///
  /// In en, this message translates to:
  /// **'Edit JSON'**
  String get editJson;

  /// No description provided for @refreshRoutingData.
  ///
  /// In en, this message translates to:
  /// **'Refresh routing data'**
  String get refreshRoutingData;

  /// No description provided for @profileDetails.
  ///
  /// In en, this message translates to:
  /// **'Profile details'**
  String get profileDetails;

  /// No description provided for @editRoutingAndDns.
  ///
  /// In en, this message translates to:
  /// **'Edit routing and DNS'**
  String get editRoutingAndDns;

  /// No description provided for @actionsFor.
  ///
  /// In en, this message translates to:
  /// **'Actions for {name}'**
  String actionsFor(Object name);

  /// No description provided for @enableProfile.
  ///
  /// In en, this message translates to:
  /// **'Enable {name}'**
  String enableProfile(Object name);

  /// No description provided for @managedListsNeedAttention.
  ///
  /// In en, this message translates to:
  /// **'Managed lists need attention'**
  String get managedListsNeedAttention;

  /// No description provided for @downloadNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Download needs attention'**
  String get downloadNeedsAttention;

  /// No description provided for @otherProfiles.
  ///
  /// In en, this message translates to:
  /// **'Other profiles'**
  String get otherProfiles;

  /// No description provided for @routingEmptyHelp.
  ///
  /// In en, this message translates to:
  /// **'Use Import to add a routing file, link, or QR code.'**
  String get routingEmptyHelp;

  /// No description provided for @noRoutingProfiles.
  ///
  /// In en, this message translates to:
  /// **'No routing profiles'**
  String get noRoutingProfiles;

  /// No description provided for @deviceIdHelp.
  ///
  /// In en, this message translates to:
  /// **'Elarni sends each provider a different device ID, made from a random key on this device. Providers can\'t link your IDs to each other. A renamed subscription, a changed refresh interval and your routing choice stay after a refresh.'**
  String get deviceIdHelp;

  /// No description provided for @registeredByProvider.
  ///
  /// In en, this message translates to:
  /// **'Registered · set by your provider'**
  String get registeredByProvider;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading'**
  String get loading;

  /// No description provided for @deviceId.
  ///
  /// In en, this message translates to:
  /// **'Device ID'**
  String get deviceId;

  /// No description provided for @everyHours.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, other{Every {hours} h}}'**
  String everyHours(int hours);

  /// No description provided for @refreshes.
  ///
  /// In en, this message translates to:
  /// **'Refreshes'**
  String get refreshes;

  /// No description provided for @appSetting.
  ///
  /// In en, this message translates to:
  /// **'App setting'**
  String get appSetting;

  /// No description provided for @yourOverride.
  ///
  /// In en, this message translates to:
  /// **'Your override'**
  String get yourOverride;

  /// No description provided for @updated.
  ///
  /// In en, this message translates to:
  /// **'Updated'**
  String get updated;

  /// No description provided for @providerNotice.
  ///
  /// In en, this message translates to:
  /// **'Provider notice'**
  String get providerNotice;

  /// No description provided for @providerAsksKeepSettings.
  ///
  /// In en, this message translates to:
  /// **'Your provider asks you to keep its settings. You can still change them.'**
  String get providerAsksKeepSettings;

  /// No description provided for @providerRouting.
  ///
  /// In en, this message translates to:
  /// **'Provider routing'**
  String get providerRouting;

  /// No description provided for @providerRoutingDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get providerRoutingDisabled;

  /// No description provided for @expires.
  ///
  /// In en, this message translates to:
  /// **'Expires'**
  String get expires;

  /// No description provided for @quota.
  ///
  /// In en, this message translates to:
  /// **'Quota'**
  String get quota;

  /// No description provided for @dataUsed.
  ///
  /// In en, this message translates to:
  /// **'Data used'**
  String get dataUsed;

  /// No description provided for @online.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get online;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @providerStatus.
  ///
  /// In en, this message translates to:
  /// **'Provider status'**
  String get providerStatus;

  /// No description provided for @detailAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get detailAccount;

  /// No description provided for @accountDisabledValue.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get accountDisabledValue;

  /// No description provided for @detailInformation.
  ///
  /// In en, this message translates to:
  /// **'Information'**
  String get detailInformation;

  /// No description provided for @lastReportedProviderInfo.
  ///
  /// In en, this message translates to:
  /// **'Last reported provider information'**
  String get lastReportedProviderInfo;

  /// No description provided for @statusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get statusReady;

  /// No description provided for @statusDeviceLimit.
  ///
  /// In en, this message translates to:
  /// **'Provider device limit reached'**
  String get statusDeviceLimit;

  /// No description provided for @statusDeviceRequired.
  ///
  /// In en, this message translates to:
  /// **'Provider requires device registration'**
  String get statusDeviceRequired;

  /// No description provided for @statusRefreshing.
  ///
  /// In en, this message translates to:
  /// **'Refreshing'**
  String get statusRefreshing;

  /// No description provided for @refreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Refresh failed'**
  String get refreshFailed;

  /// No description provided for @statusApprovalRequired.
  ///
  /// In en, this message translates to:
  /// **'Approval required'**
  String get statusApprovalRequired;

  /// No description provided for @riskPrivateTarget.
  ///
  /// In en, this message translates to:
  /// **'This subscription connects to a private or link-local network.'**
  String get riskPrivateTarget;

  /// No description provided for @riskLoopbackTarget.
  ///
  /// In en, this message translates to:
  /// **'This subscription connects to this computer.'**
  String get riskLoopbackTarget;

  /// No description provided for @riskCleartextHttp.
  ///
  /// In en, this message translates to:
  /// **'This subscription uses an unencrypted HTTP connection.'**
  String get riskCleartextHttp;

  /// No description provided for @connectionNotChecked.
  ///
  /// In en, this message translates to:
  /// **'Connection has not been checked'**
  String get connectionNotChecked;

  /// No description provided for @trafficPassesThroughServer.
  ///
  /// In en, this message translates to:
  /// **'Traffic passes through the server'**
  String get trafficPassesThroughServer;

  /// No description provided for @recoveryInProgress.
  ///
  /// In en, this message translates to:
  /// **'Recovery in progress…'**
  String get recoveryInProgress;

  /// No description provided for @automaticChecksUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Automatic checks unavailable for this routing setup'**
  String get automaticChecksUnavailable;

  /// No description provided for @automaticCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Automatic connection check failed'**
  String get automaticCheckFailed;

  /// No description provided for @latestAutomaticCheckPassed.
  ///
  /// In en, this message translates to:
  /// **'Latest automatic check passed'**
  String get latestAutomaticCheckPassed;

  /// No description provided for @automaticTrafficChecksUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Automatic traffic checks unavailable for this routing setup'**
  String get automaticTrafficChecksUnavailable;

  /// No description provided for @serverPassedNoTraffic.
  ///
  /// In en, this message translates to:
  /// **'The server passed no traffic at {time}. Checking again each minute.'**
  String serverPassedNoTraffic(Object time);

  /// No description provided for @connectionCheckUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Connection check unavailable for this routing setup'**
  String get connectionCheckUnavailable;

  /// No description provided for @checkingConnection.
  ///
  /// In en, this message translates to:
  /// **'Checking connection…'**
  String get checkingConnection;

  /// No description provided for @lastKnownState.
  ///
  /// In en, this message translates to:
  /// **'Last known state: {state}'**
  String lastKnownState(Object state);

  /// No description provided for @refreshStatusToCheck.
  ///
  /// In en, this message translates to:
  /// **'Refresh status to check the connection'**
  String get refreshStatusToCheck;

  /// No description provided for @whitelistModeRussianFirst.
  ///
  /// In en, this message translates to:
  /// **'Whitelist mode: Russian-entry servers first'**
  String get whitelistModeRussianFirst;

  /// No description provided for @staleHttpCheckAt.
  ///
  /// In en, this message translates to:
  /// **'Stale HTTP check at {time}'**
  String staleHttpCheckAt(String time);

  /// No description provided for @connectionCheckPassedAt.
  ///
  /// In en, this message translates to:
  /// **'Connection check passed at {time}'**
  String connectionCheckPassedAt(String time);

  /// No description provided for @connectionCheckFailedAt.
  ///
  /// In en, this message translates to:
  /// **'Connection check failed at {time}'**
  String connectionCheckFailedAt(String time);

  /// No description provided for @probeTcpEndpoint.
  ///
  /// In en, this message translates to:
  /// **'TCP endpoint'**
  String get probeTcpEndpoint;

  /// No description provided for @probeIcmpEndpoint.
  ///
  /// In en, this message translates to:
  /// **'ICMP endpoint'**
  String get probeIcmpEndpoint;

  /// No description provided for @probeActiveConnectionHttp.
  ///
  /// In en, this message translates to:
  /// **'Active connection HTTP'**
  String get probeActiveConnectionHttp;

  /// No description provided for @probeProxyHttp.
  ///
  /// In en, this message translates to:
  /// **'Proxy HTTP'**
  String get probeProxyHttp;

  /// No description provided for @timeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'time unavailable'**
  String get timeUnavailable;

  /// No description provided for @secondsAgo.
  ///
  /// In en, this message translates to:
  /// **'{seconds}s ago'**
  String secondsAgo(int seconds);

  /// No description provided for @minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{minutes}m ago'**
  String minutesAgo(int minutes);

  /// No description provided for @stale.
  ///
  /// In en, this message translates to:
  /// **'stale'**
  String get stale;

  /// No description provided for @connectedAt.
  ///
  /// In en, this message translates to:
  /// **'Connected {when}'**
  String connectedAt(String when);

  /// No description provided for @configurationChanged.
  ///
  /// In en, this message translates to:
  /// **'configuration changed'**
  String get configurationChanged;

  /// No description provided for @shortMonths.
  ///
  /// In en, this message translates to:
  /// **'Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'**
  String get shortMonths;

  /// No description provided for @expiredOn.
  ///
  /// In en, this message translates to:
  /// **'expired {date}'**
  String expiredOn(String date);

  /// No description provided for @expiresOn.
  ///
  /// In en, this message translates to:
  /// **'expires {date}'**
  String expiresOn(String date);

  /// No description provided for @exhausted.
  ///
  /// In en, this message translates to:
  /// **'Exhausted'**
  String get exhausted;

  /// No description provided for @profileCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 profile} other{{count} profiles}}'**
  String profileCount(int count);

  /// No description provided for @profileFromSubscription.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get profileFromSubscription;

  /// No description provided for @profileCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get profileCustom;

  /// No description provided for @profileEdited.
  ///
  /// In en, this message translates to:
  /// **'Edited'**
  String get profileEdited;

  /// No description provided for @youHaveVersion.
  ///
  /// In en, this message translates to:
  /// **'You have {version}. It keeps working; update when it suits you.'**
  String youHaveVersion(String version);

  /// No description provided for @connectionStateSemantics.
  ///
  /// In en, this message translates to:
  /// **'Connection state: {state}'**
  String connectionStateSemantics(String state);

  /// No description provided for @exitAt.
  ///
  /// In en, this message translates to:
  /// **'Exit: {country} · {ip}'**
  String exitAt(String country, String ip);

  /// No description provided for @unknownCountry.
  ///
  /// In en, this message translates to:
  /// **'unknown country'**
  String get unknownCountry;

  /// No description provided for @checkingExit.
  ///
  /// In en, this message translates to:
  /// **'Checking exit…'**
  String get checkingExit;

  /// No description provided for @exitCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Exit check failed'**
  String get exitCheckFailed;

  /// No description provided for @unsupportedTest.
  ///
  /// In en, this message translates to:
  /// **'Unsupported test'**
  String get unsupportedTest;

  /// No description provided for @testServerLatency.
  ///
  /// In en, this message translates to:
  /// **'Test server latency'**
  String get testServerLatency;

  /// No description provided for @serverCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 server} other{{count} servers}}'**
  String serverCount(int count);

  /// No description provided for @runtime.
  ///
  /// In en, this message translates to:
  /// **'Runtime'**
  String get runtime;

  /// No description provided for @failureFetch.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get failureFetch;

  /// No description provided for @failureFetchText.
  ///
  /// In en, this message translates to:
  /// **'The download failed. Check this device’s network, then retry.'**
  String get failureFetchText;

  /// No description provided for @failureDns.
  ///
  /// In en, this message translates to:
  /// **'Address lookup failed'**
  String get failureDns;

  /// No description provided for @failureDnsText.
  ///
  /// In en, this message translates to:
  /// **'The address could not be looked up. Check this device’s network and DNS, then retry.'**
  String get failureDnsText;

  /// No description provided for @failureProviderUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Provider unreachable'**
  String get failureProviderUnreachable;

  /// No description provided for @failureProviderUnreachableText.
  ///
  /// In en, this message translates to:
  /// **'{provider}’s server did not answer. Your network may block it, or it is down. Retry later or ask the provider for a mirror.'**
  String failureProviderUnreachableText(String provider);

  /// No description provided for @failureProviderError.
  ///
  /// In en, this message translates to:
  /// **'Provider error'**
  String get failureProviderError;

  /// No description provided for @failureProviderErrorText.
  ///
  /// In en, this message translates to:
  /// **'{provider}’s server reported an error. Nothing is wrong with Elarni or this device; retry later.'**
  String failureProviderErrorText(String provider);

  /// No description provided for @failureRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Rate limited'**
  String get failureRateLimited;

  /// No description provided for @failureRateLimitedText.
  ///
  /// In en, this message translates to:
  /// **'{provider} is limiting requests. Elarni retries later; wait before refreshing again.'**
  String failureRateLimitedText(String provider);

  /// No description provided for @failureDenied.
  ///
  /// In en, this message translates to:
  /// **'Access refused'**
  String get failureDenied;

  /// No description provided for @failureDeniedText.
  ///
  /// In en, this message translates to:
  /// **'{provider} refused the request. The subscription may have expired, run out of traffic or reached its device limit. Contact the provider.'**
  String failureDeniedText(String provider);

  /// No description provided for @failureLinkRemoved.
  ///
  /// In en, this message translates to:
  /// **'Link removed'**
  String get failureLinkRemoved;

  /// No description provided for @failureLinkRemovedText.
  ///
  /// In en, this message translates to:
  /// **'{provider} removed or changed this link. Ask the provider for a new one.'**
  String failureLinkRemovedText(String provider);

  /// No description provided for @reductionStatus.
  ///
  /// In en, this message translates to:
  /// **'Reduction: {status}'**
  String reductionStatus(Object status);

  /// No description provided for @routingDataStatus.
  ///
  /// In en, this message translates to:
  /// **'Routing data: {status}'**
  String routingDataStatus(Object status);

  /// No description provided for @routingProfileGone.
  ///
  /// In en, this message translates to:
  /// **'This routing profile no longer exists.'**
  String get routingProfileGone;

  /// No description provided for @routingProfileRemoved.
  ///
  /// In en, this message translates to:
  /// **'Routing profile removed'**
  String get routingProfileRemoved;

  /// No description provided for @happRoutingJson.
  ///
  /// In en, this message translates to:
  /// **'Happ routing JSON'**
  String get happRoutingJson;

  /// No description provided for @editNamed.
  ///
  /// In en, this message translates to:
  /// **'Edit {name}'**
  String editNamed(Object name);

  /// No description provided for @deleteFailed.
  ///
  /// In en, this message translates to:
  /// **'Delete failed.'**
  String get deleteFailed;

  /// No description provided for @deleteSubscriptionNamedQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete {name} and its stored nodes?'**
  String deleteSubscriptionNamedQuestion(Object name);

  /// No description provided for @deleteSubscriptionQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete subscription?'**
  String get deleteSubscriptionQuestion;

  /// No description provided for @showFailed.
  ///
  /// In en, this message translates to:
  /// **'Show failed.'**
  String get showFailed;

  /// No description provided for @hiddenServers.
  ///
  /// In en, this message translates to:
  /// **'Hidden servers'**
  String get hiddenServers;

  /// No description provided for @deviceIdNotReset.
  ///
  /// In en, this message translates to:
  /// **'Device ID not reset.'**
  String get deviceIdNotReset;

  /// No description provided for @deviceIdResetHelp.
  ///
  /// In en, this message translates to:
  /// **'{name} will see this device as new. If it limits devices, the new ID needs a free slot, and the old one may hold a slot until {name} removes it. Your other subscriptions keep their IDs.'**
  String deviceIdResetHelp(Object name);

  /// No description provided for @resetDeviceIdQuestion.
  ///
  /// In en, this message translates to:
  /// **'Reset device ID for {name}?'**
  String resetDeviceIdQuestion(Object name);

  /// No description provided for @hideFailed.
  ///
  /// In en, this message translates to:
  /// **'Hide failed.'**
  String get hideFailed;

  /// No description provided for @serversStayHidden.
  ///
  /// In en, this message translates to:
  /// **'They stay hidden after refreshes. Show them again from Hidden servers.'**
  String get serversStayHidden;

  /// No description provided for @serversRemovedFrom.
  ///
  /// In en, this message translates to:
  /// **'They are removed from {name}.'**
  String serversRemovedFrom(Object name);

  /// No description provided for @deleteCountQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete {count}?'**
  String deleteCountQuestion(Object count);

  /// No description provided for @hideCountQuestion.
  ///
  /// In en, this message translates to:
  /// **'Hide {count}?'**
  String hideCountQuestion(Object count);

  /// No description provided for @serverStaysHidden.
  ///
  /// In en, this message translates to:
  /// **'{name} stays hidden after refreshes. Show it again from Hidden servers.'**
  String serverStaysHidden(Object name);

  /// No description provided for @deleteNamedQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String deleteNamedQuestion(Object name);

  /// No description provided for @deleteServerQuestion.
  ///
  /// In en, this message translates to:
  /// **'Delete server?'**
  String get deleteServerQuestion;

  /// No description provided for @hideServerQuestion.
  ///
  /// In en, this message translates to:
  /// **'Hide server?'**
  String get hideServerQuestion;

  /// No description provided for @configNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Config not saved. It must be valid Xray JSON for one server.'**
  String get configNotSaved;

  /// No description provided for @copyConfigFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not copy the config.'**
  String get copyConfigFailed;

  /// No description provided for @nextRefreshReplacesEdits.
  ///
  /// In en, this message translates to:
  /// **'{name}’s next refresh replaces your edits.'**
  String nextRefreshReplacesEdits(Object name);

  /// No description provided for @serverConfigUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Server config unavailable.'**
  String get serverConfigUnavailable;

  /// No description provided for @refreshToShowConfig.
  ///
  /// In en, this message translates to:
  /// **'Refresh {name} to show this server’s config.'**
  String refreshToShowConfig(Object name);

  /// No description provided for @providerHidesConfig.
  ///
  /// In en, this message translates to:
  /// **'The provider hides this server’s config.'**
  String get providerHidesConfig;

  /// No description provided for @renameFailed.
  ///
  /// In en, this message translates to:
  /// **'Rename failed.'**
  String get renameFailed;

  /// No description provided for @emptyUsesProviderName.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the provider’s name.'**
  String get emptyUsesProviderName;

  /// No description provided for @renameSubscription.
  ///
  /// In en, this message translates to:
  /// **'Rename subscription'**
  String get renameSubscription;

  /// No description provided for @downloadOptionsNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Subscription download options could not be saved.'**
  String get downloadOptionsNotSaved;

  /// No description provided for @checkHostsAndRanges.
  ///
  /// In en, this message translates to:
  /// **'Check the host names and fragmentation ranges.'**
  String get checkHostsAndRanges;

  /// No description provided for @refreshWholeHours.
  ///
  /// In en, this message translates to:
  /// **'Refresh takes whole hours from 1 to 168.'**
  String get refreshWholeHours;

  /// No description provided for @fragmentIntervalRangeHelp.
  ///
  /// In en, this message translates to:
  /// **'0–1000, or a range such as 10-100'**
  String get fragmentIntervalRangeHelp;

  /// No description provided for @fragmentIntervalMs.
  ///
  /// In en, this message translates to:
  /// **'Fragment interval (ms)'**
  String get fragmentIntervalMs;

  /// No description provided for @fragmentLengthRangeHelp.
  ///
  /// In en, this message translates to:
  /// **'1–65535, or a range such as 80-250'**
  String get fragmentLengthRangeHelp;

  /// No description provided for @fragmentLengthBytes.
  ///
  /// In en, this message translates to:
  /// **'Fragment length (bytes)'**
  String get fragmentLengthBytes;

  /// No description provided for @fragmentClientHello.
  ///
  /// In en, this message translates to:
  /// **'Fragment TLS ClientHello'**
  String get fragmentClientHello;

  /// No description provided for @httpHostHelp.
  ///
  /// In en, this message translates to:
  /// **'Provider host for domain fronting. HTTPS subscriptions only.'**
  String get httpHostHelp;

  /// No description provided for @httpHostOptional.
  ///
  /// In en, this message translates to:
  /// **'HTTP Host (optional)'**
  String get httpHostOptional;

  /// No description provided for @connectAddressHelp.
  ///
  /// In en, this message translates to:
  /// **'Provider host or IP; TLS still verifies the subscription hostname.'**
  String get connectAddressHelp;

  /// No description provided for @connectAddressOptional.
  ///
  /// In en, this message translates to:
  /// **'Connect address (optional)'**
  String get connectAddressOptional;

  /// No description provided for @userAgentHelp.
  ///
  /// In en, this message translates to:
  /// **'For providers that serve only the clients they recognize.'**
  String get userAgentHelp;

  /// No description provided for @userAgentOptional.
  ///
  /// In en, this message translates to:
  /// **'User agent (optional)'**
  String get userAgentOptional;

  /// No description provided for @fallbackHostsWarning.
  ///
  /// In en, this message translates to:
  /// **'Tried in order after download failures. The subscription path and token are sent to these hosts. Only add hosts supplied by your provider. HTTP 404 and 410 stop retries.'**
  String get fallbackHostsWarning;

  /// No description provided for @fallbackHostsHelp.
  ///
  /// In en, this message translates to:
  /// **'One host per line, up to eight. No scheme, port or path.'**
  String get fallbackHostsHelp;

  /// No description provided for @fallbackHosts.
  ///
  /// In en, this message translates to:
  /// **'Fallback hosts'**
  String get fallbackHosts;

  /// No description provided for @refreshFollowAppHelp.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to follow the app setting ({hours} h). 1–168.'**
  String refreshFollowAppHelp(Object hours);

  /// No description provided for @refreshFollowProviderHelp.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to follow the provider. 1–168.'**
  String get refreshFollowProviderHelp;

  /// No description provided for @providerHours.
  ///
  /// In en, this message translates to:
  /// **'Provider: {hours} h'**
  String providerHours(Object hours);

  /// No description provided for @refreshEveryHoursOverride.
  ///
  /// In en, this message translates to:
  /// **'Refresh every (hours) · override'**
  String get refreshEveryHoursOverride;

  /// No description provided for @subscriptionDownloads.
  ///
  /// In en, this message translates to:
  /// **'Subscription downloads'**
  String get subscriptionDownloads;

  /// No description provided for @sharingUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Sharing unavailable. Refresh the subscription and check whether the provider allows sharing.'**
  String get sharingUnavailable;

  /// No description provided for @copyDetailsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not copy connection details.'**
  String get copyDetailsFailed;

  /// No description provided for @anyoneCanUseDetails.
  ///
  /// In en, this message translates to:
  /// **'Anyone with this code or copied text can use these connection details.'**
  String get anyoneCanUseDetails;

  /// No description provided for @configTooLargeForQr.
  ///
  /// In en, this message translates to:
  /// **'This configuration is too large for a QR code. Use Copy.'**
  String get configTooLargeForQr;

  /// No description provided for @connectionQrCode.
  ///
  /// In en, this message translates to:
  /// **'Connection QR code'**
  String get connectionQrCode;

  /// No description provided for @backupNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Backup could not be saved.'**
  String get backupNotSaved;

  /// No description provided for @backupNotRestored.
  ///
  /// In en, this message translates to:
  /// **'Backup could not be restored.'**
  String get backupNotRestored;

  /// No description provided for @backupNotSavedCheck.
  ///
  /// In en, this message translates to:
  /// **'Backup could not be saved. Refresh subscriptions and check provider sharing restrictions.'**
  String get backupNotSavedCheck;

  /// No description provided for @restoreFailedCheck.
  ///
  /// In en, this message translates to:
  /// **'Restore failed. Check the password and backup file.'**
  String get restoreFailedCheck;

  /// No description provided for @backupUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This catalog cannot be backed up: a restore accepts at most 4,096 servers and names up to 1,024 bytes.'**
  String get backupUnsupported;

  /// No description provided for @restoreRollbackFailed.
  ///
  /// In en, this message translates to:
  /// **'Restore failed and recovery is incomplete. Restart Elarni.'**
  String get restoreRollbackFailed;

  /// No description provided for @refreshBeforeBackup.
  ///
  /// In en, this message translates to:
  /// **'Refresh every subscription before creating a backup.'**
  String get refreshBeforeBackup;

  /// No description provided for @sharingDisabledByProvider.
  ///
  /// In en, this message translates to:
  /// **'A provider has disabled sharing and backups.'**
  String get sharingDisabledByProvider;

  /// No description provided for @encryptedBackupSaved.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup saved.'**
  String get encryptedBackupSaved;

  /// No description provided for @backupRestored.
  ///
  /// In en, this message translates to:
  /// **'Backup restored. Refresh subscription and routing data before connecting.'**
  String get backupRestored;

  /// No description provided for @chooseBackupAndRestore.
  ///
  /// In en, this message translates to:
  /// **'Choose backup and restore'**
  String get chooseBackupAndRestore;

  /// No description provided for @saveBackup.
  ///
  /// In en, this message translates to:
  /// **'Save backup'**
  String get saveBackup;

  /// No description provided for @backupPasswordRules.
  ///
  /// In en, this message translates to:
  /// **'Use at least 12 characters and matching passwords.'**
  String get backupPasswordRules;

  /// No description provided for @confirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get confirmPassword;

  /// No description provided for @atLeast12Characters.
  ///
  /// In en, this message translates to:
  /// **'At least 12 characters'**
  String get atLeast12Characters;

  /// No description provided for @backupPassword.
  ///
  /// In en, this message translates to:
  /// **'Backup password'**
  String get backupPassword;

  /// No description provided for @createBackupHelp.
  ///
  /// In en, this message translates to:
  /// **'Saves subscriptions, servers, group choices and routing in a password-protected file. Refresh subscriptions first; providers that disable sharing also disable backup. Keep the password: it cannot be recovered.'**
  String get createBackupHelp;

  /// No description provided for @restoreBackupReplacesHelp.
  ///
  /// In en, this message translates to:
  /// **'Replaces subscriptions, servers and routing. Automatic failover is disabled. Refresh subscriptions and downloaded routing data afterward. Tunnel settings and login credentials stay on this device.'**
  String get restoreBackupReplacesHelp;

  /// No description provided for @trustedWifiRules.
  ///
  /// In en, this message translates to:
  /// **'Use up to 64 names of at most 32 bytes each, without tabs.'**
  String get trustedWifiRules;

  /// No description provided for @oneNetworkPerLine.
  ///
  /// In en, this message translates to:
  /// **'One network name per line'**
  String get oneNetworkPerLine;

  /// No description provided for @oneCidrPerLine.
  ///
  /// In en, this message translates to:
  /// **'One CIDR per line'**
  String get oneCidrPerLine;

  /// No description provided for @icmpDisconnectsTunnel.
  ///
  /// In en, this message translates to:
  /// **'Elarni will disconnect the tunnel for this test and restore it afterward.'**
  String get icmpDisconnectsTunnel;

  /// No description provided for @runIcmpTestQuestion.
  ///
  /// In en, this message translates to:
  /// **'Run ICMP test?'**
  String get runIcmpTestQuestion;

  /// No description provided for @credentialsNotApplied.
  ///
  /// In en, this message translates to:
  /// **'Credentials could not be applied.'**
  String get credentialsNotApplied;

  /// No description provided for @saveAndEnable.
  ///
  /// In en, this message translates to:
  /// **'Save & enable'**
  String get saveAndEnable;

  /// No description provided for @credentialRules.
  ///
  /// In en, this message translates to:
  /// **'Use 1–255 bytes per field, without control characters; usernames cannot contain a colon.'**
  String get credentialRules;

  /// No description provided for @enterPassword.
  ///
  /// In en, this message translates to:
  /// **'Enter password'**
  String get enterPassword;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @enterUsername.
  ///
  /// In en, this message translates to:
  /// **'Enter username'**
  String get enterUsername;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @setProxyCredentials.
  ///
  /// In en, this message translates to:
  /// **'Set credentials for SOCKS5 and HTTP connections.'**
  String get setProxyCredentials;

  /// No description provided for @proxyCredentialsStored.
  ///
  /// In en, this message translates to:
  /// **'Stored securely for your account. Existing credentials are never displayed.'**
  String get proxyCredentialsStored;

  /// No description provided for @proxyAuthentication.
  ///
  /// In en, this message translates to:
  /// **'Proxy authentication'**
  String get proxyAuthentication;

  /// No description provided for @useValidRanges.
  ///
  /// In en, this message translates to:
  /// **'Use valid increasing ranges within the displayed limits.'**
  String get useValidRanges;

  /// No description provided for @fragmentIntervalHelp.
  ///
  /// In en, this message translates to:
  /// **'A value or range from 0 to 1000'**
  String get fragmentIntervalHelp;

  /// No description provided for @intervalMs.
  ///
  /// In en, this message translates to:
  /// **'Interval (ms)'**
  String get intervalMs;

  /// No description provided for @fragmentLengthHelp.
  ///
  /// In en, this message translates to:
  /// **'A value or range from 1 to 65535'**
  String get fragmentLengthHelp;

  /// No description provided for @fragmentPacketsHelp.
  ///
  /// In en, this message translates to:
  /// **'tlshello or a packet range, such as 1-3'**
  String get fragmentPacketsHelp;

  /// No description provided for @fragmentPackets.
  ///
  /// In en, this message translates to:
  /// **'Packets'**
  String get fragmentPackets;

  /// No description provided for @feedNotSaved.
  ///
  /// In en, this message translates to:
  /// **'The feed could not be saved.'**
  String get feedNotSaved;

  /// No description provided for @feedNeedsHttps.
  ///
  /// In en, this message translates to:
  /// **'Enter an https:// address, or leave it empty to turn the check off.'**
  String get feedNeedsHttps;

  /// No description provided for @feedEmptyTurnsOff.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to turn the check off.'**
  String get feedEmptyTurnsOff;

  /// No description provided for @feedAddress.
  ///
  /// In en, this message translates to:
  /// **'Feed address'**
  String get feedAddress;

  /// No description provided for @useDifferentPorts.
  ///
  /// In en, this message translates to:
  /// **'Use different ports between 1 and 65535.'**
  String get useDifferentPorts;

  /// No description provided for @httpPort.
  ///
  /// In en, this message translates to:
  /// **'HTTP port'**
  String get httpPort;

  /// No description provided for @socksPort.
  ///
  /// In en, this message translates to:
  /// **'SOCKS5 port'**
  String get socksPort;

  /// No description provided for @listenerPorts.
  ///
  /// In en, this message translates to:
  /// **'Listener ports'**
  String get listenerPorts;

  /// No description provided for @retrySelectedServer.
  ///
  /// In en, this message translates to:
  /// **'Retry selected server'**
  String get retrySelectedServer;

  /// No description provided for @checkConnection.
  ///
  /// In en, this message translates to:
  /// **'Check connection'**
  String get checkConnection;

  /// No description provided for @refreshStatus.
  ///
  /// In en, this message translates to:
  /// **'Refresh status'**
  String get refreshStatus;

  /// No description provided for @diagnosticsContents.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics contain connection state and selected runtime counters. Credentials, subscription URLs and browsing destinations are excluded. Nothing is uploaded.'**
  String get diagnosticsContents;

  /// No description provided for @recoveryTriesAllowedBackups.
  ///
  /// In en, this message translates to:
  /// **'Only your allowed backup servers may be tried.'**
  String get recoveryTriesAllowedBackups;

  /// No description provided for @recoveryStaysOnServer.
  ///
  /// In en, this message translates to:
  /// **'Recovery stays on your selected server.'**
  String get recoveryStaysOnServer;

  /// No description provided for @passingCheckScope.
  ///
  /// In en, this message translates to:
  /// **'A passing check verifies one target at that time. It does not verify every app or website.'**
  String get passingCheckScope;

  /// No description provided for @connectionStateLine.
  ///
  /// In en, this message translates to:
  /// **'Connection: {state}'**
  String connectionStateLine(Object state);

  /// No description provided for @connectionTroubleshooting.
  ///
  /// In en, this message translates to:
  /// **'Connection troubleshooting'**
  String get connectionTroubleshooting;

  /// No description provided for @subscriptionProfile.
  ///
  /// In en, this message translates to:
  /// **'Subscription profile'**
  String get subscriptionProfile;

  /// No description provided for @customProfile.
  ///
  /// In en, this message translates to:
  /// **'Custom profile'**
  String get customProfile;

  /// No description provided for @originalVersion.
  ///
  /// In en, this message translates to:
  /// **'Original version'**
  String get originalVersion;

  /// No description provided for @skippedGeodata.
  ///
  /// In en, this message translates to:
  /// **'Direct, Block and domestic DNS rules skip codes the geofiles lack: {codes}.'**
  String skippedGeodata(String codes);

  /// No description provided for @geofileDetails.
  ///
  /// In en, this message translates to:
  /// **'{bytes} bytes · Original {original} bytes\nUpdated {updated}'**
  String geofileDetails(String bytes, String original, String updated);

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @managedListsError.
  ///
  /// In en, this message translates to:
  /// **'Managed lists: {error}'**
  String managedListsError(String error);

  /// No description provided for @serverName.
  ///
  /// In en, this message translates to:
  /// **'Server name'**
  String get serverName;

  /// No description provided for @diagnosticsSection.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnosticsSection;

  /// No description provided for @recordConnectionDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Record connection diagnostics'**
  String get recordConnectionDiagnostics;

  /// No description provided for @recordConnectionDiagnosticsHelp.
  ///
  /// In en, this message translates to:
  /// **'Records connection timing, byte counts and errors while connected, so a problem can be traced. No sites, addresses, credentials or content. Uses little CPU; changing it reconnects.'**
  String get recordConnectionDiagnosticsHelp;

  /// No description provided for @markAction.
  ///
  /// In en, this message translates to:
  /// **'Mark'**
  String get markAction;

  /// No description provided for @markProblemNow.
  ///
  /// In en, this message translates to:
  /// **'Mark a problem now'**
  String get markProblemNow;

  /// No description provided for @markProblemNowHelp.
  ///
  /// In en, this message translates to:
  /// **'Also on the main screen while recording.'**
  String get markProblemNowHelp;

  /// No description provided for @saveRecordingAsZip.
  ///
  /// In en, this message translates to:
  /// **'Save recording as ZIP'**
  String get saveRecordingAsZip;

  /// No description provided for @problemMarkedAt.
  ///
  /// In en, this message translates to:
  /// **'Problem marked at {time}. Export the recording when you are done.'**
  String problemMarkedAt(String time);

  /// No description provided for @markNotSaved.
  ///
  /// In en, this message translates to:
  /// **'The mark could not be saved.'**
  String get markNotSaved;

  /// No description provided for @recordingSaved.
  ///
  /// In en, this message translates to:
  /// **'Recording saved.'**
  String get recordingSaved;

  /// No description provided for @recordingEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing is recorded yet. Turn on Record connection diagnostics, reproduce the problem, then export.'**
  String get recordingEmpty;

  /// No description provided for @recordingNotSaved.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be saved. Choose a writable location and retry.'**
  String get recordingNotSaved;

  /// No description provided for @recordingConnectionDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Recording connection diagnostics'**
  String get recordingConnectionDiagnostics;

  /// No description provided for @markProblem.
  ///
  /// In en, this message translates to:
  /// **'Mark problem'**
  String get markProblem;

  /// Per-app list entry for traffic whose app could not be identified (rule "-1").
  ///
  /// In en, this message translates to:
  /// **'Unidentified traffic'**
  String get perAppUnknownOwner;

  /// No description provided for @perAppUnknownOwnerHelp.
  ///
  /// In en, this message translates to:
  /// **'Traffic without an app: WSL, virtual machines, closed connections'**
  String get perAppUnknownOwnerHelp;

  /// No description provided for @perAppRunningNow.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 program running} other{{count} programs running}}'**
  String perAppRunningNow(int count);

  /// No description provided for @perAppNotRunning.
  ///
  /// In en, this message translates to:
  /// **'Not running now'**
  String get perAppNotRunning;

  /// No description provided for @perAppWarningMissing.
  ///
  /// In en, this message translates to:
  /// **'Not found on this computer.'**
  String get perAppWarningMissing;

  /// No description provided for @perAppWarningFolder.
  ///
  /// In en, this message translates to:
  /// **'This is a folder. A folder rule ends with a separator and matches the programs inside.'**
  String get perAppWarningFolder;

  /// No description provided for @perAppWarningNotFolder.
  ///
  /// In en, this message translates to:
  /// **'This is a file, not a folder.'**
  String get perAppWarningNotFolder;

  /// No description provided for @perAppWarningScript.
  ///
  /// In en, this message translates to:
  /// **'A script: its interpreter runs, not the script. Add the program it starts.'**
  String get perAppWarningScript;

  /// No description provided for @perAppWarningSymlink.
  ///
  /// In en, this message translates to:
  /// **'A link: the program runs as the file it points to.'**
  String get perAppWarningSymlink;

  /// No description provided for @perAppWarningCase.
  ///
  /// In en, this message translates to:
  /// **'The letter case differs from the file on disk, and rules compare it.'**
  String get perAppWarningCase;

  /// No description provided for @perAppWarningLauncher.
  ///
  /// In en, this message translates to:
  /// **'A launcher: it starts another program, which this rule does not match.'**
  String get perAppWarningLauncher;

  /// No description provided for @perAppWarningBundleName.
  ///
  /// In en, this message translates to:
  /// **'A bare name matches a program file, not an app bundle. Pick the app from the list.'**
  String get perAppWarningBundleName;

  /// No description provided for @perAppWarningVersioned.
  ///
  /// In en, this message translates to:
  /// **'Names one version of the app, so it stops matching after the next update.'**
  String get perAppWarningVersioned;

  /// No description provided for @perAppWarningUnknown.
  ///
  /// In en, this message translates to:
  /// **'This rule may not match any program.'**
  String get perAppWarningUnknown;

  /// No description provided for @perAppSuggestedRule.
  ///
  /// In en, this message translates to:
  /// **'Suggested rule: {rule}'**
  String perAppSuggestedRule(String rule);

  /// No description provided for @perAppUseSuggested.
  ///
  /// In en, this message translates to:
  /// **'Use suggested rule'**
  String get perAppUseSuggested;

  /// No description provided for @perAppConnections.
  ///
  /// In en, this message translates to:
  /// **'Recent connections'**
  String get perAppConnections;

  /// No description provided for @perAppConnectionsHelp.
  ///
  /// In en, this message translates to:
  /// **'Connections apps opened while Elarni is connected, newest first, with where each one went. It names the program behind an app\'s traffic, such as a helper or updater, so you can add it. Kept in memory until you disconnect.'**
  String get perAppConnectionsHelp;

  /// No description provided for @perAppConnectionsDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Connect to see which apps open connections and where they go.'**
  String get perAppConnectionsDisconnected;

  /// No description provided for @perAppConnectionsOff.
  ///
  /// In en, this message translates to:
  /// **'Per-app routing is off, so apps are not named. Turn it on and save to see them.'**
  String get perAppConnectionsOff;

  /// No description provided for @perAppConnectionsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No connections yet.'**
  String get perAppConnectionsEmpty;

  /// No description provided for @perAppConnectionsSearch.
  ///
  /// In en, this message translates to:
  /// **'Search apps and addresses'**
  String get perAppConnectionsSearch;

  /// No description provided for @perAppConnectionNoApp.
  ///
  /// In en, this message translates to:
  /// **'App not looked up'**
  String get perAppConnectionNoApp;

  /// No description provided for @perAppConnectionDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get perAppConnectionDirect;

  /// No description provided for @perAppConnectionProxy.
  ///
  /// In en, this message translates to:
  /// **'Through a server'**
  String get perAppConnectionProxy;

  /// No description provided for @perAppConnectionBlocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get perAppConnectionBlocked;

  /// No description provided for @perAppConnectionDns.
  ///
  /// In en, this message translates to:
  /// **'DNS'**
  String get perAppConnectionDns;

  /// No description provided for @perAppConnectionRouting.
  ///
  /// In en, this message translates to:
  /// **'Routing'**
  String get perAppConnectionRouting;

  /// No description provided for @perAppConnectionListed.
  ///
  /// In en, this message translates to:
  /// **'Per-app rule'**
  String get perAppConnectionListed;

  /// No description provided for @perAppConnectionNotListed.
  ///
  /// In en, this message translates to:
  /// **'Not listed'**
  String get perAppConnectionNotListed;

  /// No description provided for @perAppConnectionAdd.
  ///
  /// In en, this message translates to:
  /// **'Add to list'**
  String get perAppConnectionAdd;

  /// No description provided for @perAppConnectionAdded.
  ///
  /// In en, this message translates to:
  /// **'{name} added. Save changes to apply.'**
  String perAppConnectionAdded(String name);

  /// No description provided for @perAppConnectionOpenedReset.
  ///
  /// In en, this message translates to:
  /// **'Open before Elarni connected · Closed, so the app reconnects through per-app routing'**
  String get perAppConnectionOpenedReset;

  /// No description provided for @perAppConnectionOpenedKept.
  ///
  /// In en, this message translates to:
  /// **'Open before Elarni connected · Skips per-app routing until the app reconnects'**
  String get perAppConnectionOpenedKept;

  /// No description provided for @perAppConnectionsRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart {apps}: their connections opened before Elarni connected skip per-app routing until they reconnect.'**
  String perAppConnectionsRestart(String apps);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
