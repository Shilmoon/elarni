import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tunnel_channel.dart';
import 'update_check.dart';
import 'strings.dart';

// Only desktop preferences, reminder date and opaque catalog IDs live here. Profiles stay in the
// platform's encrypted catalog; desktop controls call the existing tunnel owner.
final class DesktopIntegration extends ChangeNotifier {
  static const channel = MethodChannel('com.elarni/desktop');
  static const accents = <String, Color>{
    'evergreen': Color(0xff284d42),
    'blue': Color(0xff006ef0),
    'teal': Color(0xff006b60),
    'purple': Color(0xff5546e8),
    'orange': Color(0xff8c5000),
  };
  static final languages = [
    'system',
    for (final locale in AppLocalizations.supportedLocales) locale.languageCode,
  ];
  ThemeMode theme = ThemeMode.system;
  // 'system' or the language code of one of the app's locales.
  String language = 'system';
  String accent = 'evergreen', sort = 'provider';
  Set<String> pinned = {};
  bool expiryReminders = false, _notifying = false;
  bool favoritesFirst = true;
  int lastExpiryReminderDay = 0;
  bool loginWarningDismissed = false;
  // An empty feed keeps the update check off; Not now stores the version it hid.
  String updateFeedURL = '', dismissedUpdate = '';
  AvailableUpdate? availableUpdate;

  /// The last check of this feed and version, and whether it read the feed.
  ({DateTime at, bool read})? updateChecked;
  String? _appVersion, _updateCheckedFor;
  bool _checkingUpdate = false;
  bool available = false, saving = false, _closed = false;

  /// The native host answered, even if its cosmetic preferences were unusable.
  bool hostAvailable = false;
  String? error;
  ({
    String state,
    bool canConnect,
    bool canDisconnect,
    String language,
  })? _status,
      _desiredStatus;
  bool _statusSending = false;
  Timer? _statusRetry;
  int _statusRetrySeconds = 1;
  static String get _statusError => l10n.desktopStatusNotUpdated;
  void Function(String)? onAction;

  Future<void> load() async {
    channel.setMethodCallHandler((call) async {
      if (!_closed &&
          call.method == 'action' &&
          const [
            'connect',
            'disconnect',
            'settings',
          ].contains(call.arguments)) {
        onAction?.call(call.arguments as String);
      }
    });
    try {
      final raw = await channel.invokeMethod<String>('getPreferences');
      hostAvailable = true;
      if (_closed) return;
      if (raw == null || raw.length > 64 * 1024) throw const FormatException();
      final value = Map<String, Object?>.from(jsonDecode(raw) as Map);
      final nextTheme = ThemeMode.values.byName(
        value['theme'] as String? ?? 'system',
      );
      final nextAccent = value['accent'] as String? ?? 'evergreen';
      final nextLanguage = value['language'] as String? ?? 'system';
      final nextSort = value['sort'] as String? ?? 'provider';
      final nextPins = (value['pinned'] as List? ?? []).cast<String>().toSet();
      final nextFeed = value['updateFeedURL'] as String? ?? '';
      final nextDismissed = value['dismissedUpdate'] as String? ?? '';
      if ((value['version'] ?? 1) != 1 ||
          !accents.containsKey(nextAccent) ||
          !languages.contains(nextLanguage) ||
          !['provider', 'alphabet', 'latency'].contains(nextSort) ||
          nextPins.length > 1024 ||
          nextPins.any(
            (id) => !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id),
          ) ||
          (nextFeed.isNotEmpty && !isHttpsURL(nextFeed)) ||
          nextDismissed.length > 64)
        throw const FormatException();
      theme = nextTheme;
      accent = nextAccent;
      language = nextLanguage;
      sort = nextSort;
      pinned = nextPins;
      expiryReminders = value['expiryReminders'] == true;
      favoritesFirst = value['favoritesFirst'] != false;
      lastExpiryReminderDay = value['lastExpiryReminderDay'] as int? ?? 0;
      loginWarningDismissed = value['loginWarningDismissed'] == true;
      updateFeedURL = nextFeed;
      dismissedUpdate = nextDismissed;
      available = true;
    } on MissingPluginException {
      // Native desktop integration is absent in the headless widget host.
    } on Object {
      hostAvailable = true;
      if (!_closed) error = l10n.appPreferencesNotLoaded;
    }
    if (!_closed) notifyListeners();
    unawaited(checkForUpdate());
  }

  Future<void> update({
    ThemeMode? theme,
    String? accent,
    String? language,
    String? sort,
    Set<String>? pinned,
    bool? expiryReminders,
    bool? favoritesFirst,
    int? lastExpiryReminderDay,
    bool? loginWarningDismissed,
    String? updateFeedURL,
    String? dismissedUpdate,
  }) async {
    if (_closed || saving || !available)
      throw StateError('Desktop preferences unavailable');
    if (updateFeedURL != null &&
        updateFeedURL.isNotEmpty &&
        !isHttpsURL(updateFeedURL))
      throw ArgumentError.value(updateFeedURL, 'updateFeedURL');
    if (language != null && !languages.contains(language))
      throw ArgumentError.value(language, 'language');
    saving = true;
    notifyListeners();
    try {
      if (expiryReminders == true &&
          !this.expiryReminders &&
          await channel.invokeMethod<bool>('requestNotifications') != true) {
        throw PlatformException(code: 'notifications_denied');
      }
      final next = {
        'version': 1,
        'theme': (theme ?? this.theme).name,
        'accent': accent ?? this.accent,
        'language': language ?? this.language,
        'sort': sort ?? this.sort,
        'pinned': (pinned ?? this.pinned).toList()..sort(),
        'expiryReminders': expiryReminders ?? this.expiryReminders,
        'favoritesFirst': favoritesFirst ?? this.favoritesFirst,
        'lastExpiryReminderDay':
            lastExpiryReminderDay ?? this.lastExpiryReminderDay,
        'loginWarningDismissed':
            loginWarningDismissed ?? this.loginWarningDismissed,
        'updateFeedURL': updateFeedURL ?? this.updateFeedURL,
        'dismissedUpdate': dismissedUpdate ?? this.dismissedUpdate,
      };
      await channel.invokeMethod<void>('setPreferences', {
        'json': jsonEncode(next),
      });
      if (_closed) return;
      this.theme = theme ?? this.theme;
      this.accent = accent ?? this.accent;
      this.language = language ?? this.language;
      this.sort = sort ?? this.sort;
      this.pinned = pinned ?? this.pinned;
      this.expiryReminders = expiryReminders ?? this.expiryReminders;
      this.favoritesFirst = favoritesFirst ?? this.favoritesFirst;
      this.lastExpiryReminderDay =
          lastExpiryReminderDay ?? this.lastExpiryReminderDay;
      this.loginWarningDismissed =
          loginWarningDismissed ?? this.loginWarningDismissed;
      this.dismissedUpdate = dismissedUpdate ?? this.dismissedUpdate;
      if (updateFeedURL != null) {
        // Saving the feed, even unchanged, checks it again now.
        this.updateFeedURL = updateFeedURL;
        _updateCheckedFor = null;
        availableUpdate = null;
        updateChecked = null;
        unawaited(checkForUpdate());
      }
      error = null;
    } on Object {
      if (!_closed) error = l10n.appPreferencesNotSaved;
      rethrow;
    } finally {
      saving = false;
      if (!_closed) notifyListeners();
    }
  }

  /// The running version; the update check waits until the host reports it.
  set appVersion(String? value) {
    if (value == _appVersion) return;
    _appVersion = value;
    unawaited(checkForUpdate());
  }

  /// Reads the feed once a day, or hourly while it cannot be read. A newer
  /// release only raises a notice the user can dismiss.
  Future<void> checkForUpdate() async {
    final feed = updateFeedURL, version = _appVersion, at = DateTime.now();
    final last = updateChecked;
    if (_closed ||
        !available ||
        _checkingUpdate ||
        feed.isEmpty ||
        version == null ||
        _updateCheckedFor == '$feed\n$version' &&
            last != null &&
            at.difference(last.at) < Duration(hours: last.read ? 24 : 1))
      return;
    _checkingUpdate = true;
    AvailableUpdate? found;
    var read = false;
    try {
      final update = parseUpdateFeed(
        await updateFeedFetch(
          Uri.parse(feed),
        ).timeout(const Duration(seconds: 30)),
      );
      read = update != null;
      if (update != null && (compareVersions(update.version, version) ?? 0) > 0)
        found = update;
    } on Object {
      // An unreachable or unreadable feed only means no notice.
    } finally {
      _checkingUpdate = false;
    }
    // A feed saved while this check ran is checked on its own.
    if (_closed || feed != updateFeedURL) return;
    _updateCheckedFor = '$feed\n$version';
    updateChecked = (at: at, read: read);
    availableUpdate = found;
    notifyListeners();
  }

  Future<void> remindExpiring(
    SubscriptionSnapshot snapshot, {
    DateTime? now,
  }) async {
    if (_closed || !available || !expiryReminders || saving || _notifying)
      return;
    final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final day = seconds ~/ Duration.secondsPerDay;
    if (lastExpiryReminderDay >= day) return;
    final count = snapshot.subscriptions.where((group) {
      final expiry = group.metadata['expire'];
      return !group.isLocal &&
          expiry is int &&
          expiry > seconds &&
          expiry <= seconds + 3 * Duration.secondsPerDay;
    }).length;
    if (count == 0) return;
    _notifying = true;
    try {
      await channel.invokeMethod<void>('showExpiryReminder', {'count': count});
      if (_closed) return;
      // Keep the in-session receipt even if persisting preferences fails.
      lastExpiryReminderDay = day;
      await update(lastExpiryReminderDay: day);
    } on Object {
      if (!_closed) {
        error = l10n.remindersUnavailable;
        notifyListeners();
      }
    } finally {
      _notifying = false;
    }
  }

  void status(
    String state, {
    required bool canConnect,
    required bool canDisconnect,
  }) {
    if (_closed || !available) return;
    final next = (
      state: state,
      canConnect: canConnect,
      canDisconnect: canDisconnect,
      // The tray, dialogs and notifications speak the language the app resolved.
      language: appLocale.languageCode,
    );
    if (_desiredStatus != next) {
      _desiredStatus = next;
      _statusRetry?.cancel();
      _statusRetry = null;
      _statusRetrySeconds = 1;
    }
    unawaited(_sendStatus());
  }

  Future<void> _sendStatus() async {
    if (_closed ||
        _statusSending ||
        _statusRetry != null ||
        _desiredStatus == null ||
        _desiredStatus == _status)
      return;
    final value = _desiredStatus!;
    _statusSending = true;
    var changed = false;
    try {
      await channel.invokeMethod<void>('setStatus', {
        'state': value.state,
        'canConnect': value.canConnect,
        'canDisconnect': value.canDisconnect,
        'language': value.language,
      });
      if (_closed) return;
      _status = value;
      _statusRetrySeconds = 1;
      if (error == _statusError) {
        error = null;
        changed = true;
      }
    } on Object {
      if (_closed) return;
      _status = null;
      if (_desiredStatus == value) {
        changed = error != _statusError;
        error = _statusError;
        _statusRetry = Timer(Duration(seconds: _statusRetrySeconds), () {
          _statusRetry = null;
          unawaited(_sendStatus());
        });
        _statusRetrySeconds = (_statusRetrySeconds * 2).clamp(1, 30);
      }
    } finally {
      _statusSending = false;
      if (!_closed) {
        if (_desiredStatus != value) unawaited(_sendStatus());
        if (changed) notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _statusRetry?.cancel();
    onAction = null;
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
