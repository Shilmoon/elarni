import 'package:flutter/widgets.dart';

import 'l10n/app_localizations.dart';

export 'l10n/app_localizations.dart';

/// The language MaterialApp resolved, kept so code without a BuildContext
/// (controllers, failure descriptions) speaks it too. English until the app
/// resolves one, as in tests that build a bare MaterialApp.
Locale appLocale = const Locale('en');

AppLocalizations get l10n => lookupAppLocalizations(appLocale);

/// MaterialApp's default resolution, remembered in [appLocale].
Locale resolveAppLocale(List<Locale>? preferred, Iterable<Locale> supported) =>
    appLocale = basicLocaleListResolution(preferred, supported);
