// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get noLogLinesYet =>
      'Записей пока нет. Ядро пишет их во время работы.';

  @override
  String get loggingOff =>
      'Журнал выключен. Выберите уровень, чтобы записывать журнал ядра.';

  @override
  String get saveEllipsis => 'Сохранить…';

  @override
  String get copy => 'Копировать';

  @override
  String get logLevel => 'Уровень';

  @override
  String get logNotSaved => 'Не удалось сохранить журнал.';

  @override
  String get saved => 'Сохранено';

  @override
  String get copied => 'Скопировано';

  @override
  String get logLevelNotSaved => 'Не удалось сохранить уровень журнала.';

  @override
  String get logLevelAppliesNextConnection =>
      'Уровень применится со следующего подключения.';

  @override
  String get close => 'Закрыть';

  @override
  String get logs => 'Журнал';

  @override
  String get logLevelDebug => 'Отладка';

  @override
  String get logLevelInfo => 'Информация';

  @override
  String get logLevelWarning => 'Предупреждения';

  @override
  String get logLevelError => 'Ошибки';

  @override
  String get logLevelOff => 'Выключен';

  @override
  String get issueOperationFailedRemedy =>
      'Обновите состояние и повторите попытку с выбранным сервером. Если ошибка повторяется, экспортируйте диагностику.';

  @override
  String get issueOperationFailed => 'Операция подключения не удалась.';

  @override
  String get issueCancelledRemedy => 'Ваше ручное действие имеет приоритет.';

  @override
  String get issueCancelled => 'Операция отменена.';

  @override
  String get issuePerAppTargetMissingRemedy =>
      'Выберите для него другую цель в «Маршрутизации приложений».';

  @override
  String get issuePerAppTargetMissing =>
      'Приложение в «Маршрутизации приложений» использует сервер, которого больше нет.';

  @override
  String get issueStorageUnavailableRemedy =>
      'Перезапустите Elarni. Если ошибка повторится, восстановите зашифрованную резервную копию.';

  @override
  String get issueStorageUnavailable =>
      'Elarni не удалось прочитать или сохранить свой каталог.';

  @override
  String get issueBusyRemedy => 'Дождитесь её завершения и повторите попытку.';

  @override
  String get issueBusy => 'Выполняется другая операция.';

  @override
  String get issueVpnGuardStaleRemedy =>
      'Используйте «Исправить настройку VPN» и разрешите запрос прав администратора.';

  @override
  String get issueVpnGuardStale =>
      'DNS заблокирован аварийно завершившимся туннелем.';

  @override
  String get issueVpnGuardBusyRemedy =>
      'Отключите другого пользователя или системную службу и повторите попытку.';

  @override
  String get issueVpnGuardBusy =>
      'На этом компьютере уже подключён другой VPN Elarni.';

  @override
  String get issueVpnFirewallUnavailableRemedy =>
      'Установите nftables (команду nft) и повторите попытку.';

  @override
  String get issueVpnFirewallUnavailable =>
      'Нет инструмента межсетевого экрана для VPN.';

  @override
  String get issueDisconnectUnconfirmedRemedy =>
      'Обновите состояние перед повторным подключением или используйте «Исправить настройку VPN».';

  @override
  String get issueDisconnectUnconfirmed => 'Не удалось подтвердить отключение.';

  @override
  String get issueProviderUnavailableRemedy =>
      'Повторите попытку с выбранным сервером. Если проблема останется, используйте «Исправить настройку VPN».';

  @override
  String get issueProviderUnavailable => 'Среда VPN недоступна.';

  @override
  String get issueCheckFailedRemedy =>
      'Повторите проверку. Тайм-аут, сбой целевого адреса или проблема аутентификации могут требовать разных действий.';

  @override
  String get issueCheckFailed => 'Проверка соединения не прошла.';

  @override
  String get issueStatusUnavailableRemedy =>
      'Обновите состояние. Последнее известное состояние не подтверждает текущее подключение.';

  @override
  String get issueStatusUnavailable => 'Состояние подключения недоступно.';

  @override
  String get issuePreviousRestoredRemedy =>
      'Проверьте доступ, прежде чем пробовать другой сервер.';

  @override
  String get issuePreviousRestored =>
      'Замена не удалась; прежняя конфигурация восстановлена.';

  @override
  String get issueRecoveryRequiredRemedy =>
      'Отключитесь перед повторной попыткой. Если не получится, используйте «Исправить настройку VPN».';

  @override
  String get issueRecoveryRequired =>
      'Не удалось безопасно восстановить подключение.';

  @override
  String get issueInvalidConfigurationRemedy =>
      'Проверьте её настройки или обновите подписку.';

  @override
  String get issueInvalidConfiguration =>
      'Выбранную конфигурацию нельзя использовать.';

  @override
  String get issueInvalidRecoveryRemedy =>
      'Заново выберите текущий сервер, разрешённые резервные серверы и адреса проверки соединения.';

  @override
  String get issueInvalidRecovery =>
      'Настройки восстановления неполны или устарели.';

  @override
  String get issueMissingCredentialsRemedy =>
      'Обновите или заново импортируйте эту подписку.';

  @override
  String get issueMissingCredentials => 'Учётные данные сервера недоступны.';

  @override
  String get issueRecoveryExhaustedRemedy =>
      'Повторите попытку с выбранным сервером или проверьте разрешённые резервные серверы.';

  @override
  String get issueRecoveryExhausted =>
      'Автовосстановление не нашло рабочего доступа.';

  @override
  String get issueUnsupportedPolicyRemedy =>
      'В macOS проверкам нужен полный туннель без исключений маршрутов и своих правил, а Xray TUN должен быть выключен. Настройки маршрутизации сохранены.';

  @override
  String get issueUnsupportedPolicy =>
      'Автоматические проверки трафика не поддерживают такую маршрутизацию.';

  @override
  String get issueConnectionFailedRemedy =>
      'Повторите попытку с этим сервером и проверьте его настройки или подписку.';

  @override
  String get issueConnectionFailed =>
      'Выбранному серверу не удалось обеспечить рабочий доступ.';

  @override
  String get issueCheckTargetFailedRemedy =>
      'Проверьте адрес проверки и настройки DNS. Это не значит, что сервер не работает.';

  @override
  String get issueCheckTargetFailed =>
      'Проверка соединения не смогла проверить целевой адрес.';

  @override
  String get issueListenerUnavailableRemedy =>
      'Закройте мешающее приложение или смените порт в настройках подключения.';

  @override
  String get issueListenerUnavailable =>
      'Порт локального прокси занят или недоступен.';

  @override
  String get issueVpnConfigurationFailedRemedy =>
      'Проверьте разрешения VPN в системных настройках и повторите попытку.';

  @override
  String get issueVpnConfigurationFailed =>
      'Системе не удалось подготовить VPN.';

  @override
  String get issuePermissionDeniedRemedy =>
      'Повторите попытку и разрешите системный запрос.';

  @override
  String get issuePermissionDenied => 'Разрешение на VPN не выдано.';

  @override
  String get savingEllipsis => 'Сохранение…';

  @override
  String get save => 'Сохранить';

  @override
  String get cancel => 'Отмена';

  @override
  String get expectedResponseBodyOptional =>
      'Ожидаемое тело ответа (необязательно)';

  @override
  String get expectedHttpStatus => 'Ожидаемый HTTP-статус';

  @override
  String get recoverySecondUrlOptional =>
      'Необязательно для восстановления того же сервера';

  @override
  String get checkUrl => 'Адрес проверки';

  @override
  String get secondCheckUrl => 'Второй адрес проверки';

  @override
  String get recoveryChecksHelp =>
      'Пока восстановление включено, проверки соединения отправляют через подключение небольшой запрос. Выбирайте надёжные адреса с предсказуемым ответом. Для резервных серверов нужны два разных хоста проверки.';

  @override
  String get recoveryTcpFirstHelp =>
      'Когда сервер на UDP или на порту, отличном от 443, перестаёт отвечать, первыми идут резервные на TCP 443. Если проходят только серверы с российским входом, первыми идут они.';

  @override
  String recoveryBackupNumber(Object number) {
    return 'Резервный $number';
  }

  @override
  String get recoveryLatencyHelp =>
      'Разрешённые серверы из любой подписки для сравнения. Восстановление берёт самый быстрый рабочий и переключается только при заметном улучшении. Если выбрать другой сервер вручную, он станет основным, а эти серверы останутся.';

  @override
  String get recoveryOrderedHelp =>
      'Разрешённые резервные серверы из любой подписки пробуются в порядке, в котором вы их выбрали. Если выбрать другой сервер вручную, он станет основным, а эти резервные останутся.';

  @override
  String get lowestLatency => 'Наименьшая задержка';

  @override
  String get recoveryUseAllowedBackups => 'Использовать разрешённые резервные';

  @override
  String get recoveryReconnectThisServer => 'Переподключаться к этому серверу';

  @override
  String get recovery => 'Восстановление';

  @override
  String get recoveryIntro =>
      'Выбранный сервер остаётся выбранным. Переход на резервный сервер требует вашего разрешения ниже. «Стоп» отменяет восстановление.';

  @override
  String get connectionRecovery => 'Восстановление подключения';

  @override
  String get recoveryChooseBackup =>
      'Выберите хотя бы один разрешённый резервный сервер.';

  @override
  String get recoveryTargetsSameHost =>
      'Используйте два разных хоста проверки, чтобы результаты были независимыми.';

  @override
  String recoveryTargetInvalid(Object number) {
    return 'Укажите правильный адрес проверки и успешный HTTP-статус для цели $number.';
  }

  @override
  String get off => 'Выкл.';

  @override
  String get proxyNeedsScheme => 'Укажите адрес socks5:// или http://.';

  @override
  String get proxyNotLocal =>
      'Используйте прокси на этом устройстве, например 127.0.0.1.';

  @override
  String get proxyNeedsPort => 'Добавьте порт прокси, например 127.0.0.1:1080.';

  @override
  String get proxyAddressOnly =>
      'Укажите только адрес и порт, без логина и пути.';

  @override
  String get proxyIsOwnPort =>
      'Это собственный порт прокси Elarni. Укажите порт другого приложения.';

  @override
  String get routeEnforcementWithIncludeAll =>
      '«Принудительные маршруты туннеля» нельзя совмещать с «Включать все сети». Выключите одно из них.';

  @override
  String get routeEnforcementWithBlock =>
      '«Принудительные маршруты туннеля» нельзя совмещать с «Блокировать трафик без VPN». Выключите одно из них.';

  @override
  String get routeEnforcementDefaultRoutes =>
      '«Принудительным маршрутам туннеля» нужны конкретные включённые маршруты. Замените 0.0.0.0/0 и ::/0 конкретными маршрутами или выключите принудительность.';

  @override
  String get providerAttentionLastReported =>
      'Нужно обратиться к провайдеру · Последние полученные данные';

  @override
  String get notDownloadedYet => 'Ещё не загружено';

  @override
  String get refreshingLastReported =>
      'Обновление · Последние полученные данные';

  @override
  String get refreshFailedLastReported =>
      'Обновление не удалось · Последние полученные данные';

  @override
  String get accountDisabledByProvider => 'Аккаунт отключён провайдером';

  @override
  String remainingSemantics(Object label, Object value) {
    return '$label, осталось: $value';
  }

  @override
  String get openProviderPage => 'Открыть страницу провайдера';

  @override
  String messageFrom(Object name) {
    return 'Сообщение от $name';
  }

  @override
  String latencyMs(Object ms) {
    return '$ms мс';
  }

  @override
  String protocolTooltip(Object protocol) {
    return 'Протокол: $protocol';
  }

  @override
  String get notProvided => 'Не указано';

  @override
  String get lessThanDayLeft => 'Осталось меньше дня';

  @override
  String get expired => 'Срок истёк';

  @override
  String get noExpiry => 'Бессрочно';

  @override
  String get dataExhausted => 'Трафик исчерпан';

  @override
  String amountLeft(Object amount) {
    return 'Осталось $amount';
  }

  @override
  String get unlimited => 'Безлимит';

  @override
  String get settings => 'Настройки';

  @override
  String get routing => 'Маршрутизация';

  @override
  String get subscriptions => 'Подписки';

  @override
  String get home => 'Главная';

  @override
  String get backToHome => 'Назад на главную';

  @override
  String get settingsGroupSupport => 'Поддержка';

  @override
  String get settingsGroupNetwork => 'Сеть';

  @override
  String get settingsGroupPreferences => 'Предпочтения';

  @override
  String get settingsCategory => 'Раздел настроек';

  @override
  String helpFor(Object title) {
    return 'Справка: $title';
  }

  @override
  String get importingEllipsis => 'Импорт…';

  @override
  String get importAction => 'Импорт';

  @override
  String get importScanQr => 'Сканировать QR';

  @override
  String get importFromQrImage => 'Из изображения QR';

  @override
  String get importFromClipboard => 'Из буфера обмена';

  @override
  String get importFromFile => 'Из файла';

  @override
  String get liveCameraPreview => 'Изображение с камеры';

  @override
  String get scanQrCode => 'Сканировать QR-код';

  @override
  String get cameraUnavailable =>
      'Камера недоступна. Проверьте разрешения камеры и закройте другие приложения, которые её используют.';

  @override
  String get remindersUnavailable =>
      'Напоминания о подписках недоступны. Проверьте разрешения на уведомления.';

  @override
  String get appPreferencesNotSaved =>
      'Не удалось сохранить настройки приложения.';

  @override
  String get appPreferencesNotLoaded =>
      'Не удалось загрузить настройки приложения.';

  @override
  String get openElarniLink => 'Открыть ссылку Elarni?';

  @override
  String get select => 'Выбрать';

  @override
  String daysLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Осталось $days дня',
      many: 'Осталось $days дней',
      few: 'Осталось $days дня',
      one: 'Остался $days день',
    );
    return '$_temp0';
  }

  @override
  String get gibibytes => 'ГБ';

  @override
  String get mebibytes => 'МБ';

  @override
  String get kibibytes => 'КБ';

  @override
  String bytesCount(String count) {
    return '$count Б';
  }

  @override
  String get settingsGeneral => 'Общие';

  @override
  String get settingsAppearance => 'Внешний вид';

  @override
  String get settingsConnection => 'Подключение';

  @override
  String get settingsAdvanced => 'Дополнительно';

  @override
  String get settingsServerTests => 'Проверка серверов';

  @override
  String get settingsBackupAndRepair => 'Резервная копия и исправление';

  @override
  String get settingsSystemInfo => 'О системе';

  @override
  String get settingsRouteTable => 'Таблица маршрутов';

  @override
  String get usageTime => 'Время';

  @override
  String get usageData => 'Трафик';

  @override
  String get desktopStatusNotUpdated =>
      'Не удалось обновить состояние приложения.';

  @override
  String get linkAsksDisconnect => 'Ссылка просит Elarni отключиться.';

  @override
  String get linkImportsRoutingProfile =>
      'Ссылка хочет импортировать профиль маршрутизации.';

  @override
  String get linkImportsClientProfile =>
      'Ссылка хочет импортировать профиль клиента.';

  @override
  String get disconnect => 'Отключить';

  @override
  String appRoutingUses(String engine) {
    return 'Маршрутизация приложений работает через $engine. В режиме обхода неуказанные и неопознанные процессы идут по обычной маршрутизации. В режиме «Только выбранные» они подключаются напрямую.';
  }

  @override
  String get systemWideVpn => 'Системный VPN';

  @override
  String get connectionMode => 'Режим подключения';

  @override
  String get connectionModeHelp =>
      'Системный VPN подключает все приложения; разрешение администратора запрашивается при первом подключении VPN в этом сеансе приложения. Системный прокси направляет настройку прокси этого компьютера в Elarni без разрешения администратора; его используют только приложения, которые её учитывают, например браузеры. Только локальный прокси открывает порты ниже для приложений, которые вы настроите сами.';

  @override
  String get connectionModeServiceHelp =>
      'Системный VPN подключает все приложения; разрешение администратора запрашивается при первом подключении VPN в этом сеансе приложения, если не включено «Подключаться без разрешения администратора». Системный прокси направляет настройку прокси этого компьютера в Elarni без разрешения администратора; его используют только приложения, которые её учитывают, например браузеры. Только локальный прокси открывает порты ниже для приложений, которые вы настроите сами.';

  @override
  String get systemProxy => 'Системный прокси';

  @override
  String get localProxyOnly => 'Только локальный прокси';

  @override
  String get systemProxyMode => 'Режим системного прокси';

  @override
  String get systemProxyListeners =>
      'В режиме системного прокси приложения на этом компьютере используют HTTP-порт без входа.';

  @override
  String get updateDraft => 'Обновить черновик';

  @override
  String get loadProfile => 'Загрузить профиль';

  @override
  String perAppProfileLoaded(Object platform) {
    return 'Профиль $platform загружен. Проверьте приложения и нажмите «Сохранить изменения», чтобы применить.';
  }

  @override
  String get backToApps => 'Назад к приложениям';

  @override
  String get routingProfileJson => 'JSON профиля маршрутизации';

  @override
  String get executableNamesOrPaths =>
      'Имена исполняемых файлов или полные пути';

  @override
  String loadRoutingProfileHelp(Object platform) {
    return 'Загрузите профиль маршрутизации $platform в этот черновик. «Сохранить изменения» применит его.';
  }

  @override
  String get executableRulesHelp =>
      'Одно имя или путь исполняемого файла на строку, до 256. Папка, оканчивающаяся на /, включает исполняемые файлы внутри неё.';

  @override
  String routingProfileContents(Object platform) {
    return 'Профили маршрутизации содержат только режим, правила исполняемых файлов и цели приложений, кроме серверов. Делитесь ими с другим устройством $platform; пути, возможно, придётся поправить.';
  }

  @override
  String get appRoutingNotFirewall =>
      'DNS и локальные SOCKS/HTTP-слушатели сохраняют свои правила. Маршрутизация приложений — не межсетевой экран и не аварийный выключатель.';

  @override
  String get macMatchingHelp =>
      'Выбор .app включает все исполняемые файлы внутри его пакета. Остальные имена и пути учитывают регистр.';

  @override
  String get windowsMatchingHelp =>
      'Windows сравнивает имена .exe и полные пути без учёта регистра. Вспомогательные исполняемые файлы выбирайте отдельно.';

  @override
  String get linuxMatchingHelp =>
      'Linux сравнивает имена и пути исполняемых файлов с учётом регистра. Вспомогательные процессы выбирайте отдельно.';

  @override
  String get pasteRoutingProfile => 'Вставить профиль маршрутизации';

  @override
  String get editExecutableRules => 'Изменить правила исполняемых файлов';

  @override
  String get howAppRoutingWorks => 'Как работает маршрутизация приложений';

  @override
  String get done => 'Готово';

  @override
  String get chooseAppFile => 'Выбрать файл приложения';

  @override
  String get copyRoutingProfile => 'Скопировать профиль маршрутизации';

  @override
  String perAppProfileCopied(Object platform) {
    return 'Профиль $platform скопирован вместе с именами и путями приложений.';
  }

  @override
  String get profileAndExecutableTools => 'Профиль и исполняемые файлы';

  @override
  String get noMatchingApps => 'Нет подходящих приложений.';

  @override
  String get noAppsFound =>
      'Приложения не найдены. Выберите файл приложения ниже.';

  @override
  String get loadingApps => 'Загрузка приложений…';

  @override
  String get runningApps => 'Запущенные приложения';

  @override
  String get installedAndRunningApps => 'Установленные и запущенные приложения';

  @override
  String get refreshAppList => 'Обновить список приложений';

  @override
  String get searchApps => 'Поиск приложений';

  @override
  String get addApps => 'Добавить приложения';

  @override
  String get saveChanges => 'Сохранить изменения';

  @override
  String get perAppTargetsHelp =>
      'Каждое приложение может подключаться напрямую, идти по вашим правилам маршрутизации, быть заблокированным, использовать сервер из любой подписки или локальный SOCKS5- или HTTP-прокси, например ByeByeDPI. Только трафик VPN; правила DNS и локального прокси не меняются.';

  @override
  String get targetDirect => 'Напрямую';

  @override
  String get targetFollowRouting => 'По правилам маршрутизации';

  @override
  String get otherApps => 'Другие приложения';

  @override
  String removeApp(Object name) {
    return 'Убрать $name';
  }

  @override
  String get details => 'Подробнее';

  @override
  String get executableRule => 'Правило исполняемого файла';

  @override
  String get appBundleIncludesHelpers =>
      'Пакет приложения · со вспомогательными';

  @override
  String get noAppsSelected =>
      'Приложения не выбраны. Добавьте приложения, чтобы создать правило маршрутизации.';

  @override
  String get selectedApps => 'Выбранные приложения';

  @override
  String get perAppOnlySelected => 'Только выбранные';

  @override
  String get perAppBypassSelected => 'Выбранные в обход';

  @override
  String get perAppRouting => 'Маршрутизация приложений';

  @override
  String get perAppRoutingIntro =>
      'Выберите, какие приложения используют VPN. Действует для всех подписок.';

  @override
  String get perAppOffHelp =>
      'Все приложения идут по вашим правилам маршрутизации. Выбор приложений сохранён.';

  @override
  String get perAppOnlyHelp =>
      'Выбранные приложения идут по вашим правилам маршрутизации, если вы не выбрали для них другую цель. Все остальные приложения подключаются напрямую.';

  @override
  String get perAppBypassHelp =>
      'Выбранные приложения подключаются напрямую, если вы не выбрали для них другую цель. Остальные приложения идут по вашим правилам маршрутизации.';

  @override
  String get macRulesCaseSensitive =>
      'Имена и пути учитывают регистр. Путь, оканчивающийся на /, включает исполняемые файлы в этой папке.';

  @override
  String get macBundleRuleHelp =>
      'Это правило включает все исполняемые файлы внутри пакета приложения.';

  @override
  String get windowsRulesCaseInsensitive =>
      'Имена и пути исполняемых файлов не учитывают регистр. Другие вспомогательные исполняемые файлы выбирайте отдельно.';

  @override
  String get linuxRulesCaseSensitive =>
      'Имена и пути учитывают регистр. Вспомогательные исполняемые файлы выбирайте отдельно.';

  @override
  String get appListUnavailable =>
      'Список приложений недоступен. Выберите файл приложения или измените правила исполняемых файлов.';

  @override
  String get closeAppChooser => 'Закрыть выбор приложений';

  @override
  String get localProxyEllipsis => 'Локальный прокси…';

  @override
  String get targetMissingServer => 'Сервер не найден';

  @override
  String targetServer(Object name) {
    return 'Сервер · $name';
  }

  @override
  String targetLocalProxy(Object address) {
    return 'Локальный прокси · $address';
  }

  @override
  String get perAppOperationFailed =>
      'Операция не удалась. Попробуйте ещё раз; черновик сохранён.';

  @override
  String get perAppLauncherRule =>
      'Snap, Flatpak и скрипты-лаунчеры запускают другую программу, поэтому их правила ничего не находят. Запустите приложение и выберите его в списке приложений.';

  @override
  String get useProxy => 'Использовать прокси';

  @override
  String get proxyAddress => 'Адрес прокси';

  @override
  String get localProxyHelp =>
      'SOCKS5- или HTTP-прокси другого приложения, например ByeByeDPI.';

  @override
  String get localProxy => 'Локальный прокси';

  @override
  String perAppOtherPlatformProfile(Object profilePlatform, Object platform) {
    return 'Это профиль $profilePlatform. Импортируйте профиль $platform или выберите приложения на этом устройстве.';
  }

  @override
  String get perAppUnsupportedProfile =>
      'Неподдерживаемый профиль маршрутизации приложений.';

  @override
  String get perAppProfileTooLarge => 'Профиль больше 512 КБ.';

  @override
  String get perAppUnixPathsOnWindows =>
      'Пути исполняемых файлов macOS и Unix нельзя использовать в профиле Windows. Выберите приложения на этом компьютере.';

  @override
  String get perAppMacBundlesOnLinux =>
      'Пакеты приложений macOS нельзя использовать в профиле Linux. Выберите исполняемые файлы Linux.';

  @override
  String perAppWindowsPathsElsewhere(Object platform) {
    return 'Пути исполняемых файлов Windows нельзя использовать в профиле $platform. Выберите приложения на этом устройстве.';
  }

  @override
  String get perAppAndroidPackages =>
      'Используйте имена пакетов Android, например com.example.app. Выберите приложения на этом устройстве.';

  @override
  String get perAppInvalidProfile =>
      'Укажите поддерживаемый режим и до 256 имён или путей, каждое не длиннее 1024 байт и без управляющих символов, с целями только для указанных приложений. Активному режиму нужно хотя бы одно приложение.';

  @override
  String get perAppUnsupportedPlatform => 'Неподдерживаемая платформа профиля.';

  @override
  String get targetBlock => 'Блокировать';

  @override
  String get validateAndSave => 'Проверить и сохранить';

  @override
  String get rulesTab => 'Правила';

  @override
  String get routingAndDns => 'Маршрутизация и DNS';

  @override
  String get reduceRoutingDataHelp =>
      'Применяется при обновлении данных маршрутизации. Сохраняет полные подходящие записи и оригиналы; при сбое используются полные файлы.';

  @override
  String get reduceRoutingDataSize => 'Уменьшать размер данных маршрутизации';

  @override
  String get resolveWhenNeeded => 'Разрешать при необходимости';

  @override
  String get resolveIfNoRuleMatches =>
      'Разрешать, если ни одно правило не подошло';

  @override
  String get keepDomainNames => 'Не разрешать домены';

  @override
  String get resolveDomainsForRouting => 'Разрешать домены для маршрутизации';

  @override
  String get ruleGroupOrder => 'Порядок групп правил';

  @override
  String get profileName => 'Название профиля';

  @override
  String get directDnsDomainsHint =>
      'Один домен, суффикс domain:, имя full: или тег geosite: на строку.';

  @override
  String get domainsUsingDirectDns => 'Домены с прямым DNS';

  @override
  String get explicitDomainRulesHelp =>
      'Подходящие домены используют прямой DNS, все остальные — удалённый. Если выключено, остаётся прежний порядок с запасным вариантом. Начальное подключение DoH идёт через выбранный прокси.';

  @override
  String get useExplicitDomainRules => 'Явные правила по доменам';

  @override
  String get chooseDnsByDomain => 'Выбор DNS по домену';

  @override
  String get resolverIp => 'IP-адрес резолвера';

  @override
  String get bootstrapIp => 'IP-адрес сервера DoH';

  @override
  String get resolverType => 'Тип резолвера';

  @override
  String get remoteDns => 'Удалённый DNS';

  @override
  String get directDns => 'Прямой DNS';

  @override
  String get keepDomainIdentityHelp =>
      'Использует Fake DNS. С обычным DNS правила по доменам зависят от поддерживаемого распознавания HTTP/TLS/QUIC; для зашифрованных имён и других протоколов могут понадобиться правила по IP.';

  @override
  String get keepDomainIdentity => 'Сохранять домены для маршрутизации';

  @override
  String get ipRulesHint =>
      'Один адрес IPv4/IPv6, CIDR или цель geoip: на строку.';

  @override
  String get ipAddressesAndNetworks => 'IP-адреса и сети';

  @override
  String get domainRulesHint =>
      'Один домен или цель full:, domain:, regexp: или geosite: на строку.';

  @override
  String get domains => 'Домены';

  @override
  String get addPreset => 'Добавить набор';

  @override
  String get russianSitesPresetHelp =>
      '.ru, .рф, .su и другие домены этих сервисов';

  @override
  String get russianSitesDirect => 'Российские сайты напрямую';

  @override
  String get connectDirectly => 'Подключаться напрямую';

  @override
  String get unmatchedTraffic => 'Остальной трафик';

  @override
  String get routingChangeFailed =>
      'Не удалось изменить маршрутизацию. Сохранён последний рабочий профиль.';

  @override
  String routingIpTargetsInvalid(String field) {
    return '$field: нужны IP-адреса, правильные CIDR или ссылки geoip:.';
  }

  @override
  String routingDnsNeedsResolver(String dns) {
    return '$dns: нужны тип резолвера и IP-адрес.';
  }

  @override
  String routingDnsNeedsHttpsUrl(String dns) {
    return '$dns: нужен адрес HTTPS без учётных данных и фрагмента.';
  }

  @override
  String get domesticDns => 'Прямой DNS';

  @override
  String get directRules => 'Правила «Напрямую»';

  @override
  String get proxyRules => 'Правила «Прокси»';

  @override
  String get blockRules => 'Правила «Блокировка»';

  @override
  String get ruleGroupBlock => 'Блокировка';

  @override
  String get ruleGroupDirect => 'Напрямую';

  @override
  String get ruleGroupProxy => 'Прокси';

  @override
  String get httpsUrl => 'Адрес HTTPS';

  @override
  String get routingProfilesNotLoaded =>
      'Не удалось загрузить профили маршрутизации.';

  @override
  String get connectionStoppedUnexpectedly =>
      'Подключение неожиданно прервалось. Переподключитесь, чтобы повторить.';

  @override
  String get groupSelectionFailed =>
      'Не удалось выбрать сервер в группе. Восстановлен сохранённый выбор.';

  @override
  String get serverIpPreferenceNotApplied =>
      'Не удалось применить настройку IP сервера.';

  @override
  String get telegramNotOpened =>
      'Не удалось открыть Telegram. Проверьте, что он установлен.';

  @override
  String get couldNotImport =>
      'Не удалось импортировать. Используйте ссылку подписки, конфигурацию клиента или профиль маршрутизации.';

  @override
  String get selectServerFirstRoutingLink =>
      'Сначала выберите сервер. Эта ссылка маршрутизации включает свой профиль для подписки выбранного сервера.';

  @override
  String get unsupportedProfileTryJson =>
      'Этот профиль использует неподдерживаемые настройки. Попробуйте формат Xray JSON от провайдера.';

  @override
  String get subscriptionAddedFirstDownloadFailed =>
      'Подписка добавлена, но первая загрузка не удалась. Обновите, чтобы повторить.';

  @override
  String get clipboardEmpty =>
      'Буфер обмена пуст. Сначала скопируйте ссылку или конфигурацию.';

  @override
  String get downloadPageNotOpened => 'Не удалось открыть страницу загрузки.';

  @override
  String get providerLinkNotOpened => 'Не удалось открыть ссылку провайдера.';

  @override
  String get continueAction => 'Продолжить';

  @override
  String get approveUnsafeSubscription => 'Одобрить небезопасную подписку?';

  @override
  String get contactProvider => 'Связаться с провайдером';

  @override
  String get vpnSetupNotRepaired => 'Не удалось исправить настройку VPN.';

  @override
  String get vpnSetupReset =>
      'Настройка VPN сброшена. Подключитесь, чтобы попробовать снова.';

  @override
  String get repair => 'Исправить';

  @override
  String get repairVpnMacBody =>
      'Останавливает подключение и удаляет сохранённую настройку VPN в macOS. «Подключить» создаст её заново с выбранным сервером и настройками.';

  @override
  String get repairVpnDesktopBody =>
      'Останавливает подключение и закрывает вспомогательный процесс туннеля. В Windows также снимает блокировку DNS, оставленную неожиданно остановившимся помощником, — для этого нужны права администратора. Следующее подключение VPN запустит новый помощник и тоже может их запросить.';

  @override
  String get repairVpnSetupQuestion => 'Исправить настройку VPN?';

  @override
  String get favoriteNotSaved =>
      'Не удалось сохранить избранное. Попробуйте ещё раз.';

  @override
  String get subscriptionsNotLoaded => 'Не удалось загрузить подписки.';

  @override
  String get hideVpnIconBody =>
      'Это меняет исключённые сетевые маршруты, а не только скрывает значок.';

  @override
  String get hideVpnIconQuestion => 'Скрыть значок VPN?';

  @override
  String settingNotApplied(Object details) {
    return 'Не удалось применить настройку. $details';
  }

  @override
  String get settingNotAppliedCheck =>
      'Не удалось применить настройку. Проверьте текущие настройки и состояние туннеля перед повторным подключением.';

  @override
  String get settingsReloaded =>
      'Настройки перезагружены. Повторите изменение.';

  @override
  String get pingFailedForNode => 'Проверка этого сервера не удалась.';

  @override
  String get pingIcmpRestoreFailed =>
      'ICMP завершён, но прежнее подключение туннеля восстановить не удалось.';

  @override
  String get pingIcmpNoReplyRestored =>
      'Нет ответа ICMP. Прежнее подключение туннеля восстановлено.';

  @override
  String get pingIcmpUnavailable =>
      'ICMP недоступен, пока подключён системный VPN. Используйте проверку TCP или HTTP.';

  @override
  String get pingDirectTcpUnsupported =>
      'Пропущено: транспорт этого сервера не поддерживает прямой TCP. Используйте проверку через прокси.';

  @override
  String get pingNeedsDisconnect =>
      'Пропущено: при подключении эта проверка не доходит до сервера. Отключитесь, чтобы проверить его.';

  @override
  String get routeTableUnreadable =>
      'Не удалось прочитать текущую таблицу маршрутов.';

  @override
  String get systemInfoUnavailable => 'Сведения о системе недоступны.';

  @override
  String get systemSettingsNotLoaded =>
      'Не удалось загрузить системные настройки.';

  @override
  String get allowWithoutLogin => 'Разрешить без логина';

  @override
  String allowWithoutLoginBody(Object ports) {
    return 'В режиме локального прокси любая программа на этом устройстве, включая вредоносные и программы других пользователей, сможет отправлять трафик через ваш сервер на $ports. Доступ из локальной сети выключится.';
  }

  @override
  String get allowAppsWithoutLogin => 'Разрешить приложениям без логина?';

  @override
  String portSingle(Object port) {
    return 'порту $port';
  }

  @override
  String portsPair(Object socks, Object http) {
    return 'портах $socks и $http';
  }

  @override
  String get tunnelSettingsNotLoaded =>
      'Не удалось загрузить настройки туннеля.';

  @override
  String get chooseWritableLocation =>
      'Выберите доступное для записи место и повторите попытку.';

  @override
  String get diagnosticsNotSaved => 'Не удалось сохранить диагностику.';

  @override
  String pingTested(int tested, int total) {
    return 'Проверено серверов: $tested из $total.';
  }

  @override
  String pingSkippedIncompatible(int count) {
    return 'Пропущено $count: не подходят для этого способа проверки.';
  }

  @override
  String pingSkippedWhileConnected(int count) {
    return 'Пропущено $count: отключитесь, чтобы проверить их.';
  }

  @override
  String get refreshFailedSentence => 'Обновление не удалось.';

  @override
  String get lastWorkingServersKept => 'Последние рабочие серверы сохранены.';

  @override
  String get catalogLimit =>
      'Elarni хранит до 1024 подписок и 256 профилей маршрутизации. Удалите лишние и повторите попытку.';

  @override
  String get dismissMessage => 'Закрыть сообщение';

  @override
  String get addSubscriptionToStart =>
      'Добавьте подписку или импортируйте профиль, чтобы начать.';

  @override
  String get noSubscriptionsYet => 'Подписок пока нет';

  @override
  String get refreshProfiles => 'Обновить профили';

  @override
  String get routeTableHelp => 'Текущие числовые маршруты IPv4 и IPv6.';

  @override
  String get openServerList => 'Открыть список серверов';

  @override
  String get expectedBodyHelp =>
      'Точный текст; оставьте пустым для HTTP 204 или HEAD.';

  @override
  String get expectedResponseBody => 'Ожидаемое тело ответа';

  @override
  String get testUrl => 'Адрес для проверки';

  @override
  String get httpRequest => 'HTTP-запрос';

  @override
  String secondsTimeout(Object seconds) {
    return 'Тайм-аут $seconds с';
  }

  @override
  String get timeout => 'Тайм-аут';

  @override
  String get testMode => 'Режим проверки';

  @override
  String get httpMethod => 'Метод HTTP';

  @override
  String get currentRulesActiveTunnel => 'Текущие правила / активный туннель';

  @override
  String get testType => 'Тип проверки';

  @override
  String get refreshingEllipsis => 'Обновление…';

  @override
  String get refresh => 'Обновить';

  @override
  String get exportDiagnostics => 'Экспорт диагностики';

  @override
  String get troubleshootConnection => 'Диагностика подключения';

  @override
  String get versions => 'Версии';

  @override
  String xrayCoreVersion(Object version) {
    return 'Ядро Xray $version';
  }

  @override
  String get unavailable => 'Недоступно';

  @override
  String get physicalMemory => 'Физическая память';

  @override
  String get activeCpus => 'Активные процессоры';

  @override
  String get cpuCount => 'Число процессоров';

  @override
  String get appArchitecture => 'Архитектура приложения';

  @override
  String get operatingSystem => 'Операционная система';

  @override
  String get repairVpnSetup => 'Исправить настройку VPN';

  @override
  String get reviewRepair => 'Исправить…';

  @override
  String get connectionRepair => 'Исправление подключения';

  @override
  String get restoreBackupHelp =>
      'Отключитесь, прежде чем заменять сохранённые профили и маршрутизацию.';

  @override
  String get restoreBackup => 'Восстановить копию';

  @override
  String get restore => 'Восстановление';

  @override
  String get createEncryptedBackup => 'Создать зашифрованную копию';

  @override
  String get export => 'Экспорт';

  @override
  String get backups => 'Резервные копии';

  @override
  String get showMonitoringOnMain => 'Показывать мониторинг на главном экране';

  @override
  String get monitoring => 'Мониторинг';

  @override
  String get enableSniffing => 'Включить сниффинг';

  @override
  String get udpMaxConnections => 'Максимум UDP-соединений';

  @override
  String get tcpMaxConnections => 'Максимум TCP-соединений';

  @override
  String get connectionIdleTimeout => 'Тайм-аут простоя соединения (секунды)';

  @override
  String get xrayMemoryLimit => 'Лимит памяти Xray (МБ)';

  @override
  String get resources => 'Ресурсы';

  @override
  String get defaultMuxHelp =>
      'Импортированные настройки mux важнее. Эта настройка действует только для VLESS и не включает mux для Hysteria.';

  @override
  String get enableDefaultVlessMux => 'Включить mux для VLESS по умолчанию';

  @override
  String fragmentationSummary(Object packets, Object length, Object interval) {
    return '$packets · $length байт · $interval мс';
  }

  @override
  String get fragmentationOptions => 'Параметры фрагментации';

  @override
  String get edit => 'Изменить';

  @override
  String get fragmentationHelp =>
      'VLESS поверх TCP или XHTTP с TLS или Reality. XHTTP поверх HTTP/3 и существующие цепочки dialer не поддерживаются.';

  @override
  String get enableFragmentation => 'Включить фрагментацию';

  @override
  String get transport => 'Транспорт';

  @override
  String get resolveServerHelp =>
      'Фиксирует IP-адреса серверов до переподключения, сохраняя имена TLS и заголовки транспорта.';

  @override
  String get resolveServerBeforeConnecting =>
      'Разрешать адрес сервера перед подключением';

  @override
  String get noEnabledRoutingProfiles =>
      'Нет включённых профилей маршрутизации. Включите профиль в разделе «Маршрутизация».';

  @override
  String get editDns => 'Изменить DNS';

  @override
  String get routingProfiles => 'Профили маршрутизации';

  @override
  String get routingProfile => 'Профиль маршрутизации';

  @override
  String get providerProfile => 'Профиль провайдера';

  @override
  String get dnsSettingsHelp => 'Выберите, какой профиль задаёт настройки DNS.';

  @override
  String get dnsSettings => 'Настройки DNS';

  @override
  String get allowLanHelp =>
      'Требует аутентификации. Используйте доверенную локальную сеть: аутентификация SOCKS5 и HTTP не шифрует соединение клиента.';

  @override
  String get allowLan => 'Разрешить подключения из локальной сети (IPv4)';

  @override
  String get requireProxyAuthHelp =>
      'Оба слушателя используют сохранённые учётные данные. Отключение аутентификации отключает и доступ из локальной сети.';

  @override
  String get requireProxyAuth => 'Требовать аутентификацию SOCKS5 и HTTP';

  @override
  String get allowAppsWithoutLoginHelp =>
      'В режиме локального прокси любая программа на этом устройстве сможет использовать ваш прокси и ваш сервер. При включённом VPN слушателям всё равно нужен логин. Также отключает доступ из локальной сети.';

  @override
  String get allowAppsWithoutLoginToggle => 'Разрешить приложениям без логина';

  @override
  String get set => 'Задать';

  @override
  String get change => 'Изменить';

  @override
  String get hide => 'Скрыть';

  @override
  String get show => 'Показать';

  @override
  String get notConfigured => 'Не настроено';

  @override
  String get proxyLoginHelp =>
      'Приложения, использующие SOCKS5- или HTTP-прокси, входят с этим именем пользователя и паролем.';

  @override
  String get proxyLogin => 'Логин прокси';

  @override
  String get listenersHelp =>
      'Слушатели работают, пока туннель активен на любом бэкенде. При включённом VPN они всегда требуют логин: ваши сохранённые учётные данные, если аутентификация включена, иначе случайные для каждого подключения, чтобы другие приложения не могли ими пользоваться.';

  @override
  String get socksAndHttpPorts => 'Порты SOCKS5 и HTTP';

  @override
  String get httpInbound => 'HTTP-вход';

  @override
  String get useAppDefault => 'Как в приложении';

  @override
  String get serverIpType => 'Тип IP сервера';

  @override
  String get shareLinkServers => 'Серверы из ссылок';

  @override
  String get defaultIpTypeHelp => 'Для серверов без своей настройки.';

  @override
  String get defaultIpType => 'Тип IP по умолчанию';

  @override
  String get serverAddressing => 'Адресация серверов';

  @override
  String get blockTrafficMacHelp =>
      'macOS держит весь трафик внутри туннеля, в том числе во время переподключения. Исключения маршрутов не действуют.';

  @override
  String get blockTrafficDesktopHelp =>
      'Если VPN неожиданно остановится, ничего не уйдёт с этого устройства мимо него, пока вы не переподключитесь или не используете «Исправить настройку VPN». Отключение снимает блокировку. Нужен системный VPN; нельзя совмещать с «Принудительными маршрутами туннеля».';

  @override
  String get blockTrafficWithoutVpn => 'Блокировать трафик без VPN';

  @override
  String get connectWithoutAdminApprovalHelp =>
      'Служба Elarni VPN запускает помощник VPN для этой учётной записи Windows, поэтому подключение не требует разрешения. Включение и выключение один раз запросят разрешение.';

  @override
  String get connectWithoutAdminApproval =>
      'Подключаться без разрешения администратора';

  @override
  String get accentColor => 'Цвет акцента';

  @override
  String get dark => 'Тёмная';

  @override
  String get light => 'Светлая';

  @override
  String get followSystem => 'Как в системе';

  @override
  String get theme => 'Тема';

  @override
  String get language => 'Язык';

  @override
  String get languageName => 'Русский';

  @override
  String get feedUnreadable => 'Не удалось прочитать источник.';

  @override
  String get upToDate => 'Установлена последняя версия';

  @override
  String updateAvailable(Object version) {
    return 'Доступна версия Elarni $version';
  }

  @override
  String get updateFeedHelp =>
      'Elarni раз в день читает этот адрес и показывает на главной уведомление, если там указана более новая версия. Elarni ничего не скачивает и не устанавливает. Используйте JSON-файл с \"version\" и \"url\" или адрес API GitHub releases/latest; только https.';

  @override
  String get updateFeed => 'Источник обновлений';

  @override
  String get updates => 'Обновления';

  @override
  String get favoritesFirst => 'Сначала избранные';

  @override
  String get alphabetical => 'По алфавиту';

  @override
  String get providerOrder => 'Как у провайдера';

  @override
  String get serverOrder => 'Порядок серверов';

  @override
  String get subscriptionExpiryRemindersHelp =>
      'Раз в день, пока Elarni работает, если подписка заканчивается в ближайшие три дня.';

  @override
  String get subscriptionExpiryReminders => 'Напоминания об окончании подписок';

  @override
  String get subscriptionAutoUpdateHelp =>
      'Обновляет все подписки, пока Elarni работает. По умолчанию: 4 часа.';

  @override
  String get subscriptionAutoUpdateHours => 'Автообновление подписок (часы)';

  @override
  String get macDisconnectsWhenSleeping => 'macOS отключает VPN во время сна.';

  @override
  String disconnectsWhenSleeps(Object platform) {
    return 'Отключается, когда $platform засыпает.';
  }

  @override
  String get disconnectOnSleep => 'Отключаться в режиме сна';

  @override
  String get loginStateUnavailable => 'Состояние регистрации недоступно.';

  @override
  String get loginApprovalRequired =>
      'Нужно разрешение в настройках «Объекты входа» macOS.';

  @override
  String get launchAtLogin => 'Запускать при входе в систему';

  @override
  String get windowsWifiLocationHelp =>
      'Windows скрывает от Elarni имя сети Wi-Fi. Включите «Службы определения местоположения» и «Разрешить классическим приложениям доступ к расположению» в «Параметры › Конфиденциальность и защита › Расположение».';

  @override
  String get noTrustedWifi => 'Нет. Подключение в любой сети Wi-Fi.';

  @override
  String get trustedWifiNetworks => 'Доверенные сети Wi-Fi';

  @override
  String get untrustedWifiMacHelp =>
      'Подключение к сети Wi-Fi не из списка доверенных включает VPN, даже если вы ещё не нажали «Подключить». Доверенные и проводные сети оставляют VPN как есть. «Отключить» приостанавливает это до следующего «Подключить».';

  @override
  String get untrustedWifiDesktopHelp =>
      'Подключение к сети Wi-Fi не из списка доверенных включает VPN. Доверенные сети, проводные и мобильные подключения, а также остановленное вами подключение остаются как есть до следующей сети.';

  @override
  String get connectOnUntrustedWifi =>
      'Подключаться в недоверенных сетях Wi-Fi';

  @override
  String get onDemandMacHelp =>
      '«По требованию» управляет автоматическим подключением, когда сеть снова доступна.';

  @override
  String get onDemand => 'По требованию';

  @override
  String get recoveryBackupsSummary => 'Только разрешённые резервные серверы.';

  @override
  String get recoveryFixedSummary =>
      'Переподключение только к выбранному серверу.';

  @override
  String get recoveryOffSummary => 'Выключено. Выбор сервера сохраняется.';

  @override
  String get configure => 'Настроить';

  @override
  String get none => 'Нет';

  @override
  String get excludedRoutes => 'Исключённые маршруты';

  @override
  String get includedRoutes => 'Включённые маршруты';

  @override
  String get compatibilityRouteExclusionsHelp =>
      'Добавляет исключения маршрутов, которые использует обходной способ скрытия значка. Скрытие значка VPN не проверено.';

  @override
  String get compatibilityRouteExclusions => 'Совместимые исключения маршрутов';

  @override
  String get includeAllNetworksHelp =>
      'Маршруты VPN действуют в режиме системного VPN. «Включать все сети» захватывает оба семейства IP и учитывает ваши исключения.';

  @override
  String get includeAllNetworks => 'Включать все сети';

  @override
  String get enforceRoutesMacHelp =>
      'Принудительности нужны конкретные включённые маршруты; маршруты по умолчанию, такие как 0.0.0.0/0 и ::/0, не поддерживаются. Для полного туннеля выключите принудительность и включите «Блокировать трафик без VPN» в настройках подключения.';

  @override
  String get enforceRoutesDesktopHelp =>
      'Маршруты VPN действуют в режиме системного VPN. Принудительность не даёт трафику обойти туннель по указанным включённым маршрутам, пока подключение активно.';

  @override
  String get enforceTunnelRoutes => 'Принудительные маршруты туннеля';

  @override
  String get advancedNetworkRoutes => 'Дополнительные сетевые маршруты';

  @override
  String get memoryLimitAutomatic => 'автоматически';

  @override
  String megabytesValue(String value) {
    return '$value МБ';
  }

  @override
  String gigabytesValue(String value) {
    return '$value ГБ';
  }

  @override
  String extensionMemory(String value) {
    return 'RSS расширения: $value МБ';
  }

  @override
  String xrayHeap(String heap, String limit) {
    return 'Куча Xray: $heap МБ / $limit';
  }

  @override
  String get softLimit => '(мягкий лимит)';

  @override
  String sessionsSummary(Object tcp, Object udp) {
    return 'Сессии: $tcp TCP / $udp UDP';
  }

  @override
  String trafficSummary(Object up, Object down) {
    return 'Трафик, байт: $up отправлено / $down получено';
  }

  @override
  String packetsSummary(Object incoming, Object outgoing) {
    return 'Пакеты: $incoming входящих / $outgoing исходящих';
  }

  @override
  String listenersSummary(String scope, Object socks, String http) {
    return 'Настроено ($scope): SOCKS5 $socks; HTTP $http.';
  }

  @override
  String get listenLan => 'локальная сеть IPv4';

  @override
  String get listenLoopback => 'только это устройство';

  @override
  String get httpOff => 'выкл.';

  @override
  String get testModeDouble => 'Двойной';

  @override
  String get testModeDefault => 'Обычный';

  @override
  String get proxyHead => 'HEAD через прокси';

  @override
  String get proxyGet => 'GET через прокси';

  @override
  String get directIcmp => 'Прямой ICMP';

  @override
  String get directTcp => 'Прямой TCP';

  @override
  String get testThroughProxy => 'Через прокси';

  @override
  String get automatic => 'Автоматически';

  @override
  String get useProfile => 'Как в профиле';

  @override
  String get loginServiceNotFound =>
      'macOS не нашла это приложение как службу входа.';

  @override
  String get loginNotRegistered => 'Не зарегистрировано.';

  @override
  String get loginRegistered => 'Зарегистрировано для вашей учётной записи.';

  @override
  String get searchServers => 'Поиск серверов';

  @override
  String get filterRecent => 'Недавние';

  @override
  String get filterFavorites => 'Избранные';

  @override
  String get filterAll => 'Все';

  @override
  String get servers => 'Серверы';

  @override
  String get showAgain => 'Показать снова';

  @override
  String hiddenServersCount(int count) {
    return 'Скрытые серверы · $count';
  }

  @override
  String get noMatchingServers => 'Нет подходящих серверов';

  @override
  String get noServersInSubscription => 'В этой подписке нет серверов';

  @override
  String get delete => 'Удалить';

  @override
  String get selectUnreachable => 'Выбрать недоступные';

  @override
  String selectedCount(int count) {
    return 'Выбрано: $count';
  }

  @override
  String get setByYourProvider => 'Задано провайдером';

  @override
  String get noCustomRouting => 'Без своей маршрутизации';

  @override
  String refreshNamed(Object name) {
    return 'Обновить «$name»';
  }

  @override
  String get accountDisabled => 'Аккаунт отключён';

  @override
  String get rename => 'Переименовать';

  @override
  String get shareLinksFormat => 'Ссылки';

  @override
  String get originalSubscription => 'Исходная подписка';

  @override
  String get subscriptionFormat => 'Формат подписки';

  @override
  String get downloadOptions => 'Параметры загрузки';

  @override
  String get shareSubscription => 'Поделиться подпиской';

  @override
  String get accountDetails => 'Данные аккаунта';

  @override
  String get providerSupport => 'Поддержка провайдера';

  @override
  String get pinSubscription => 'Закрепить подписку';

  @override
  String get unpinSubscription => 'Открепить подписку';

  @override
  String get subscriptionActions => 'Действия с подпиской';

  @override
  String get testSubscriptionNodes => 'Проверить серверы этой подписки';

  @override
  String get testAllNodes => 'Проверить все серверы';

  @override
  String get useNodePingForIcmp =>
      'Для ICMP используйте кнопку «Пинг» у сервера';

  @override
  String get testing => 'Проверка…';

  @override
  String get otherLocations => 'Другие местоположения';

  @override
  String lowestLatencySemantics(int ms) {
    String _temp0 = intl.Intl.pluralLogic(
      ms,
      locale: localeName,
      other: 'Наименьшая задержка: $ms миллисекунды',
      many: 'Наименьшая задержка: $ms миллисекунд',
      few: 'Наименьшая задержка: $ms миллисекунды',
      one: 'Наименьшая задержка: $ms миллисекунда',
    );
    return '$_temp0';
  }

  @override
  String get clearSearch => 'Очистить поиск';

  @override
  String get noServersYet => 'Серверов пока нет';

  @override
  String get showAllServers => 'Показать все серверы';

  @override
  String get noSuccessfulConnections => 'Успешных подключений пока нет';

  @override
  String get noFavoriteServers => 'Нет избранных серверов';

  @override
  String get onboardingStep3Proxy =>
      'Нажмите «Подключить». Через локальный прокси идут только настроенные на него приложения; чтобы подключить все приложения, включите «Системный VPN» в «Настройки › Подключение».';

  @override
  String get onboardingStep3Vpn =>
      'Нажмите «Подключить». Разрешение администратора запрашивается при первом подключении VPN в этом сеансе приложения.';

  @override
  String get onboardingStep3Mac =>
      'Нажмите «Подключить». macOS один раз попросит разрешить конфигурацию VPN.';

  @override
  String get openFile => 'Открыть файл';

  @override
  String get pasteLink => 'Вставить ссылку';

  @override
  String get onboardingStep2 => 'Добавьте её здесь.';

  @override
  String get onboardingStep1 =>
      'Получите у провайдера ссылку на подписку или QR-код. У Elarni нет собственных серверов.';

  @override
  String get onboardingTitle => 'Подключитесь в три шага';

  @override
  String get serverActions => 'Действия с сервером';

  @override
  String get open => 'Открыть';

  @override
  String get openInTelegram => 'Открыть в Telegram';

  @override
  String get checkExit => 'Проверить выход';

  @override
  String get checking => 'Проверка…';

  @override
  String get serverConfig => 'Конфигурация сервера';

  @override
  String exitMismatch(Object server, Object named, Object exit) {
    return 'В названии «$server» указано: $named, но выход — $exit.';
  }

  @override
  String get addFavorite => 'Добавить в избранное';

  @override
  String get removeFavorite => 'Убрать из избранного';

  @override
  String get unknownLocation => 'Неизвестное местоположение';

  @override
  String selectNamed(Object name) {
    return 'Выбрать $name';
  }

  @override
  String get deleteServer => 'Удалить сервер';

  @override
  String get hideServer => 'Скрыть сервер';

  @override
  String get renameServer => 'Переименовать сервер';

  @override
  String get ping => 'Пинг';

  @override
  String get skipped => 'Пропущен';

  @override
  String get localProxyMode => 'Режим локального прокси';

  @override
  String get selectServerToConnect => 'Выберите сервер, чтобы подключиться.';

  @override
  String get chooseServer => 'Выберите сервер';

  @override
  String get stateConnectionFailed => 'Ошибка подключения';

  @override
  String get stateReconnecting => 'Переподключение…';

  @override
  String get stateDisconnecting => 'Отключение…';

  @override
  String get stateConnectedNoTraffic => 'Подключено · нет трафика';

  @override
  String get stateConnected => 'Подключено';

  @override
  String get stateConnecting => 'Подключение…';

  @override
  String get statePreparing => 'Подготовка…';

  @override
  String get stateReadyToConnect => 'Готово к подключению';

  @override
  String get stateDisconnected => 'Отключено';

  @override
  String get connectionStatusUnavailable => 'Состояние подключения недоступно';

  @override
  String get connect => 'Подключить';

  @override
  String get notNow => 'Не сейчас';

  @override
  String get download => 'Скачать';

  @override
  String get requireLogin => 'Требовать логин';

  @override
  String get anyProgramCanUseProxy =>
      'Им может пользоваться любая программа на этом устройстве.';

  @override
  String get localProxyWithoutLogin =>
      'Ваш локальный прокси принимает приложения без логина';

  @override
  String get liftBlock => 'Снять блокировку';

  @override
  String get reconnect => 'Переподключить';

  @override
  String get connectionStoppedUnexpectedlyShort =>
      'Подключение неожиданно прервалось.';

  @override
  String get trafficBlockedUntilReconnect =>
      'Трафик заблокирован до переподключения';

  @override
  String deleteProfileAndRulesQuestion(Object name) {
    return 'Удалить «$name» и его правила?';
  }

  @override
  String get deleteRoutingProfileQuestion => 'Удалить профиль маршрутизации?';

  @override
  String get reset => 'Сбросить';

  @override
  String replaceEditsQuestion(Object name) {
    return 'Заменить ваши изменения в «$name» версией из подписки?';
  }

  @override
  String get resetRoutingProfileQuestion => 'Сбросить профиль маршрутизации?';

  @override
  String get resetToSubscriptionVersion => 'Вернуть версию из подписки';

  @override
  String get duplicate => 'Дублировать';

  @override
  String get editJson => 'Изменить JSON';

  @override
  String get refreshRoutingData => 'Обновить данные маршрутизации';

  @override
  String get profileDetails => 'Сведения о профиле';

  @override
  String get editRoutingAndDns => 'Изменить маршрутизацию и DNS';

  @override
  String actionsFor(Object name) {
    return 'Действия для $name';
  }

  @override
  String enableProfile(Object name) {
    return 'Включить $name';
  }

  @override
  String get managedListsNeedAttention => 'Управляемые списки требуют внимания';

  @override
  String get downloadNeedsAttention => 'Загрузка требует внимания';

  @override
  String get otherProfiles => 'Другие профили';

  @override
  String get routingEmptyHelp =>
      'Нажмите «Импорт», чтобы добавить файл, ссылку или QR-код маршрутизации.';

  @override
  String get noRoutingProfiles => 'Нет профилей маршрутизации';

  @override
  String get deviceIdHelp =>
      'Elarni отправляет каждому провайдеру свой ID устройства, созданный из случайного ключа на этом устройстве. Провайдеры не могут связать ваши ID между собой. Переименованная подписка, изменённый интервал обновления и ваш выбор маршрутизации сохраняются после обновления.';

  @override
  String get registeredByProvider => 'Зарегистрировано · задано провайдером';

  @override
  String get loading => 'Загрузка';

  @override
  String get deviceId => 'ID устройства';

  @override
  String everyHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Каждые $hours ч',
      one: 'Каждый $hours ч',
    );
    return '$_temp0';
  }

  @override
  String get refreshes => 'Обновление';

  @override
  String get appSetting => 'Настройка приложения';

  @override
  String get yourOverride => 'Ваше значение';

  @override
  String get updated => 'Обновлено';

  @override
  String get providerNotice => 'Сообщение провайдера';

  @override
  String get providerAsksKeepSettings =>
      'Провайдер просит не менять его настройки. Изменить их всё равно можно.';

  @override
  String get providerRouting => 'Маршрутизация провайдера';

  @override
  String get providerRoutingDisabled => 'Отключена';

  @override
  String get expires => 'Истекает';

  @override
  String get quota => 'Лимит';

  @override
  String get dataUsed => 'Использовано трафика';

  @override
  String get online => 'В сети';

  @override
  String get offline => 'Не в сети';

  @override
  String get providerStatus => 'Состояние провайдера';

  @override
  String get detailAccount => 'Аккаунт';

  @override
  String get accountDisabledValue => 'Отключён';

  @override
  String get detailInformation => 'Сведения';

  @override
  String get lastReportedProviderInfo =>
      'Последние полученные от провайдера сведения';

  @override
  String get statusReady => 'Готова';

  @override
  String get statusDeviceLimit => 'Достигнут лимит устройств у провайдера';

  @override
  String get statusDeviceRequired => 'Провайдер требует регистрации устройства';

  @override
  String get statusRefreshing => 'Обновляется';

  @override
  String get refreshFailed => 'Не удалось обновить';

  @override
  String get statusApprovalRequired => 'Нужно подтверждение';

  @override
  String get riskPrivateTarget =>
      'Эта подписка подключается к частной или локальной сети.';

  @override
  String get riskLoopbackTarget =>
      'Эта подписка подключается к этому компьютеру.';

  @override
  String get riskCleartextHttp =>
      'Эта подписка использует незашифрованное HTTP-подключение.';

  @override
  String get connectionNotChecked => 'Подключение не проверялось';

  @override
  String get trafficPassesThroughServer => 'Трафик проходит через сервер';

  @override
  String get recoveryInProgress => 'Идёт восстановление…';

  @override
  String get automaticChecksUnavailable =>
      'Автоматические проверки недоступны для этой настройки маршрутизации';

  @override
  String get automaticCheckFailed =>
      'Автоматическая проверка подключения не пройдена';

  @override
  String get latestAutomaticCheckPassed =>
      'Последняя автоматическая проверка пройдена';

  @override
  String get automaticTrafficChecksUnavailable =>
      'Автоматические проверки трафика недоступны для этой настройки маршрутизации';

  @override
  String serverPassedNoTraffic(Object time) {
    return 'Сервер не передавал трафик в $time. Повторная проверка каждую минуту.';
  }

  @override
  String get connectionCheckUnavailable =>
      'Проверка подключения недоступна для этой настройки маршрутизации';

  @override
  String get checkingConnection => 'Проверка подключения…';

  @override
  String lastKnownState(Object state) {
    return 'Последнее известное состояние: $state';
  }

  @override
  String get refreshStatusToCheck =>
      'Обновите состояние, чтобы проверить подключение';

  @override
  String get whitelistModeRussianFirst =>
      'Режим белого списка: сначала серверы со входом в России';

  @override
  String staleHttpCheckAt(String time) {
    return 'Устаревшая HTTP-проверка в $time';
  }

  @override
  String connectionCheckPassedAt(String time) {
    return 'Проверка подключения пройдена в $time';
  }

  @override
  String connectionCheckFailedAt(String time) {
    return 'Проверка подключения не пройдена в $time';
  }

  @override
  String get probeTcpEndpoint => 'Узел TCP';

  @override
  String get probeIcmpEndpoint => 'Узел ICMP';

  @override
  String get probeActiveConnectionHttp => 'HTTP через активное подключение';

  @override
  String get probeProxyHttp => 'HTTP через прокси';

  @override
  String get timeUnavailable => 'время неизвестно';

  @override
  String secondsAgo(int seconds) {
    return '$seconds с назад';
  }

  @override
  String minutesAgo(int minutes) {
    return '$minutes мин назад';
  }

  @override
  String get stale => 'устарело';

  @override
  String connectedAt(String when) {
    return 'Подключено $when';
  }

  @override
  String get configurationChanged => 'конфигурация изменена';

  @override
  String get shortMonths =>
      'янв. февр. мар. апр. мая июн. июл. авг. сент. окт. нояб. дек.';

  @override
  String expiredOn(String date) {
    return 'истекла $date';
  }

  @override
  String expiresOn(String date) {
    return 'истекает $date';
  }

  @override
  String get exhausted => 'Исчерпан';

  @override
  String profileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count профиля',
      many: '$count профилей',
      few: '$count профиля',
      one: '$count профиль',
    );
    return '$_temp0';
  }

  @override
  String get profileFromSubscription => 'Из подписки';

  @override
  String get profileCustom => 'Свой';

  @override
  String get profileEdited => 'Изменён';

  @override
  String youHaveVersion(String version) {
    return 'У вас версия $version. Она продолжит работать; обновитесь, когда будет удобно.';
  }

  @override
  String connectionStateSemantics(String state) {
    return 'Состояние подключения: $state';
  }

  @override
  String exitAt(String country, String ip) {
    return 'Выход: $country · $ip';
  }

  @override
  String get unknownCountry => 'неизвестная страна';

  @override
  String get checkingExit => 'Проверка выхода…';

  @override
  String get exitCheckFailed => 'Не удалось проверить выход';

  @override
  String get unsupportedTest => 'Проверка не поддерживается';

  @override
  String get testServerLatency => 'Проверить задержку сервера';

  @override
  String serverCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count сервера',
      many: '$count серверов',
      few: '$count сервера',
      one: '$count сервер',
    );
    return '$_temp0';
  }

  @override
  String get runtime => 'Среда выполнения';

  @override
  String get failureFetch => 'Ошибка загрузки';

  @override
  String get failureFetchText =>
      'Загрузка не удалась. Проверьте сеть этого устройства и повторите.';

  @override
  String get failureDns => 'Адрес не найден';

  @override
  String get failureDnsText =>
      'Не удалось определить адрес. Проверьте сеть и DNS этого устройства и повторите.';

  @override
  String get failureProviderUnreachable => 'Провайдер недоступен';

  @override
  String failureProviderUnreachableText(String provider) {
    return 'Сервер провайдера «$provider» не ответил. Возможно, ваша сеть его блокирует или он не работает. Повторите позже или попросите у провайдера зеркало.';
  }

  @override
  String get failureProviderError => 'Ошибка провайдера';

  @override
  String failureProviderErrorText(String provider) {
    return 'Сервер провайдера «$provider» сообщил об ошибке. С Elarni и этим устройством всё в порядке; повторите позже.';
  }

  @override
  String get failureRateLimited => 'Слишком много запросов';

  @override
  String failureRateLimitedText(String provider) {
    return 'Провайдер «$provider» ограничивает запросы. Elarni повторит позже; подождите, прежде чем обновлять снова.';
  }

  @override
  String get failureDenied => 'Доступ запрещён';

  @override
  String failureDeniedText(String provider) {
    return 'Провайдер «$provider» отклонил запрос. Возможно, подписка истекла, закончился трафик или достигнут лимит устройств. Свяжитесь с провайдером.';
  }

  @override
  String get failureLinkRemoved => 'Ссылка удалена';

  @override
  String failureLinkRemovedText(String provider) {
    return 'Провайдер «$provider» удалил или изменил эту ссылку. Попросите у провайдера новую.';
  }

  @override
  String reductionStatus(Object status) {
    return 'Сокращение: $status';
  }

  @override
  String routingDataStatus(Object status) {
    return 'Данные маршрутизации: $status';
  }

  @override
  String get routingProfileGone => 'Этого профиля маршрутизации больше нет.';

  @override
  String get routingProfileRemoved => 'Профиль маршрутизации удалён';

  @override
  String get happRoutingJson => 'JSON маршрутизации Happ';

  @override
  String editNamed(Object name) {
    return 'Изменить «$name»';
  }

  @override
  String get deleteFailed => 'Не удалось удалить.';

  @override
  String deleteSubscriptionNamedQuestion(Object name) {
    return 'Удалить «$name» и сохранённые серверы?';
  }

  @override
  String get deleteSubscriptionQuestion => 'Удалить подписку?';

  @override
  String get showFailed => 'Не удалось показать.';

  @override
  String get hiddenServers => 'Скрытые серверы';

  @override
  String get deviceIdNotReset => 'ID устройства не сброшен.';

  @override
  String deviceIdResetHelp(Object name) {
    return 'Для «$name» это устройство станет новым. Если провайдер ограничивает число устройств, новому ID нужно свободное место, а старый может занимать место, пока провайдер «$name» его не удалит. Остальные подписки сохранят свои ID.';
  }

  @override
  String resetDeviceIdQuestion(Object name) {
    return 'Сбросить ID устройства для «$name»?';
  }

  @override
  String get hideFailed => 'Не удалось скрыть.';

  @override
  String get serversStayHidden =>
      'Они останутся скрытыми после обновлений. Вернуть их можно в «Скрытых серверах».';

  @override
  String serversRemovedFrom(Object name) {
    return 'Они будут удалены из «$name».';
  }

  @override
  String deleteCountQuestion(Object count) {
    return 'Удалить $count?';
  }

  @override
  String hideCountQuestion(Object count) {
    return 'Скрыть $count?';
  }

  @override
  String serverStaysHidden(Object name) {
    return '«$name» останется скрытым после обновлений. Вернуть его можно в «Скрытых серверах».';
  }

  @override
  String deleteNamedQuestion(Object name) {
    return 'Удалить «$name»?';
  }

  @override
  String get deleteServerQuestion => 'Удалить сервер?';

  @override
  String get hideServerQuestion => 'Скрыть сервер?';

  @override
  String get configNotSaved =>
      'Конфигурация не сохранена. Нужен корректный Xray JSON для одного сервера.';

  @override
  String get copyConfigFailed => 'Не удалось скопировать конфигурацию.';

  @override
  String nextRefreshReplacesEdits(Object name) {
    return 'Следующее обновление «$name» заменит ваши правки.';
  }

  @override
  String get serverConfigUnavailable => 'Конфигурация сервера недоступна.';

  @override
  String refreshToShowConfig(Object name) {
    return 'Обновите «$name», чтобы увидеть конфигурацию этого сервера.';
  }

  @override
  String get providerHidesConfig =>
      'Провайдер скрывает конфигурацию этого сервера.';

  @override
  String get renameFailed => 'Не удалось переименовать.';

  @override
  String get emptyUsesProviderName =>
      'Оставьте пустым, чтобы использовать имя от провайдера.';

  @override
  String get renameSubscription => 'Переименовать подписку';

  @override
  String get downloadOptionsNotSaved =>
      'Не удалось сохранить параметры загрузки подписки.';

  @override
  String get checkHostsAndRanges =>
      'Проверьте имена хостов и диапазоны фрагментации.';

  @override
  String get refreshWholeHours =>
      'Обновление задаётся целыми часами от 1 до 168.';

  @override
  String get fragmentIntervalRangeHelp =>
      '0–1000 или диапазон, например 10-100';

  @override
  String get fragmentIntervalMs => 'Интервал фрагментов (мс)';

  @override
  String get fragmentLengthRangeHelp => '1–65535 или диапазон, например 80-250';

  @override
  String get fragmentLengthBytes => 'Длина фрагмента (байт)';

  @override
  String get fragmentClientHello => 'Фрагментировать TLS ClientHello';

  @override
  String get httpHostHelp =>
      'Хост провайдера для domain fronting. Только для подписок по HTTPS.';

  @override
  String get httpHostOptional => 'HTTP Host (необязательно)';

  @override
  String get connectAddressHelp =>
      'Хост или IP провайдера; TLS всё равно проверяет имя хоста подписки.';

  @override
  String get connectAddressOptional => 'Адрес подключения (необязательно)';

  @override
  String get userAgentHelp =>
      'Для провайдеров, которые обслуживают только знакомые им клиенты.';

  @override
  String get userAgentOptional => 'User agent (необязательно)';

  @override
  String get fallbackHostsWarning =>
      'Пробуются по порядку после ошибок загрузки. Этим хостам отправляются путь и токен подписки. Добавляйте только хосты, которые дал провайдер. HTTP 404 и 410 останавливают повторы.';

  @override
  String get fallbackHostsHelp =>
      'Один хост на строку, не больше восьми. Без схемы, порта и пути.';

  @override
  String get fallbackHosts => 'Резервные хосты';

  @override
  String refreshFollowAppHelp(Object hours) {
    return 'Оставьте пустым, чтобы следовать настройке приложения ($hours ч). 1–168.';
  }

  @override
  String get refreshFollowProviderHelp =>
      'Оставьте пустым, чтобы следовать провайдеру. 1–168.';

  @override
  String providerHours(Object hours) {
    return 'Провайдер: $hours ч';
  }

  @override
  String get refreshEveryHoursOverride =>
      'Обновлять каждые (часы) · своё значение';

  @override
  String get subscriptionDownloads => 'Загрузка подписки';

  @override
  String get sharingUnavailable =>
      'Обмен недоступен. Обновите подписку и проверьте, разрешает ли провайдер обмен.';

  @override
  String get copyDetailsFailed => 'Не удалось скопировать данные подключения.';

  @override
  String get anyoneCanUseDetails =>
      'Любой, у кого есть этот код или скопированный текст, может использовать эти данные подключения.';

  @override
  String get configTooLargeForQr =>
      'Эта конфигурация слишком велика для QR-кода. Используйте «Копировать».';

  @override
  String get connectionQrCode => 'QR-код подключения';

  @override
  String get backupNotSaved => 'Не удалось сохранить копию.';

  @override
  String get backupNotRestored => 'Не удалось восстановить копию.';

  @override
  String get backupNotSavedCheck =>
      'Не удалось сохранить копию. Обновите подписки и проверьте, разрешает ли провайдер обмен.';

  @override
  String get restoreFailedCheck =>
      'Восстановление не удалось. Проверьте пароль и файл копии.';

  @override
  String get backupUnsupported =>
      'Этот каталог нельзя сохранить в копию: восстановление принимает не более 4096 серверов и имена до 1024 байт.';

  @override
  String get restoreRollbackFailed =>
      'Восстановление не удалось, и откат не завершён. Перезапустите Elarni.';

  @override
  String get refreshBeforeBackup =>
      'Перед созданием копии обновите все подписки.';

  @override
  String get sharingDisabledByProvider =>
      'Провайдер запретил обмен и резервное копирование.';

  @override
  String get encryptedBackupSaved => 'Зашифрованная копия сохранена.';

  @override
  String get backupRestored =>
      'Копия восстановлена. Перед подключением обновите подписки и данные маршрутизации.';

  @override
  String get chooseBackupAndRestore => 'Выбрать копию и восстановить';

  @override
  String get saveBackup => 'Сохранить копию';

  @override
  String get backupPasswordRules =>
      'Нужно не меньше 12 символов и совпадающие пароли.';

  @override
  String get confirmPassword => 'Повторите пароль';

  @override
  String get atLeast12Characters => 'Не меньше 12 символов';

  @override
  String get backupPassword => 'Пароль копии';

  @override
  String get createBackupHelp =>
      'Сохраняет подписки, серверы, выбор в группах и маршрутизацию в файл, защищённый паролем. Сначала обновите подписки; провайдеры, запрещающие обмен, запрещают и резервное копирование. Сохраните пароль: восстановить его нельзя.';

  @override
  String get restoreBackupReplacesHelp =>
      'Заменяет подписки, серверы и маршрутизацию. Автоматическое переключение выключается. После этого обновите подписки и загруженные данные маршрутизации. Настройки туннеля и учётные данные входа остаются на этом устройстве.';

  @override
  String get trustedWifiRules =>
      'Не больше 64 имён, каждое до 32 байт, без табуляций.';

  @override
  String get oneNetworkPerLine => 'Одно имя сети на строку';

  @override
  String get oneCidrPerLine => 'Один CIDR на строку';

  @override
  String get icmpDisconnectsTunnel =>
      'Elarni отключит туннель на время проверки и затем восстановит его.';

  @override
  String get runIcmpTestQuestion => 'Запустить проверку ICMP?';

  @override
  String get credentialsNotApplied => 'Не удалось применить учётные данные.';

  @override
  String get saveAndEnable => 'Сохранить и включить';

  @override
  String get credentialRules =>
      'Каждое поле — от 1 до 255 байт, без управляющих символов; имя пользователя не может содержать двоеточие.';

  @override
  String get enterPassword => 'Введите пароль';

  @override
  String get password => 'Пароль';

  @override
  String get enterUsername => 'Введите имя пользователя';

  @override
  String get username => 'Имя пользователя';

  @override
  String get setProxyCredentials =>
      'Задайте учётные данные для подключений SOCKS5 и HTTP.';

  @override
  String get proxyCredentialsStored =>
      'Хранятся в защищённом хранилище вашей учётной записи. Сохранённые учётные данные никогда не показываются.';

  @override
  String get proxyAuthentication => 'Аутентификация прокси';

  @override
  String get useValidRanges =>
      'Укажите корректные возрастающие диапазоны в показанных пределах.';

  @override
  String get fragmentIntervalHelp => 'Значение или диапазон от 0 до 1000';

  @override
  String get intervalMs => 'Интервал (мс)';

  @override
  String get fragmentLengthHelp => 'Значение или диапазон от 1 до 65535';

  @override
  String get fragmentPacketsHelp =>
      'tlshello или диапазон пакетов, например 1-3';

  @override
  String get fragmentPackets => 'Пакеты';

  @override
  String get feedNotSaved => 'Не удалось сохранить источник.';

  @override
  String get feedNeedsHttps =>
      'Укажите адрес https:// или оставьте поле пустым, чтобы выключить проверку.';

  @override
  String get feedEmptyTurnsOff => 'Оставьте пустым, чтобы выключить проверку.';

  @override
  String get feedAddress => 'Адрес источника';

  @override
  String get useDifferentPorts => 'Укажите разные порты от 1 до 65535.';

  @override
  String get httpPort => 'Порт HTTP';

  @override
  String get socksPort => 'Порт SOCKS5';

  @override
  String get listenerPorts => 'Порты прослушивания';

  @override
  String get retrySelectedServer => 'Повторить с выбранным сервером';

  @override
  String get checkConnection => 'Проверить подключение';

  @override
  String get refreshStatus => 'Обновить состояние';

  @override
  String get diagnosticsContents =>
      'Диагностика содержит состояние подключения и некоторые счётчики работы. Учётные данные, адреса подписок и посещаемые адреса не включаются. Ничего не отправляется.';

  @override
  String get recoveryTriesAllowedBackups =>
      'Пробуются только разрешённые вами резервные серверы.';

  @override
  String get recoveryStaysOnServer =>
      'Восстановление остаётся на выбранном сервере.';

  @override
  String get passingCheckScope =>
      'Успешная проверка подтверждает одну цель в момент проверки. Она не подтверждает работу каждого приложения или сайта.';

  @override
  String connectionStateLine(Object state) {
    return 'Подключение: $state';
  }

  @override
  String get connectionTroubleshooting => 'Диагностика подключения';

  @override
  String get subscriptionProfile => 'Профиль из подписки';

  @override
  String get customProfile => 'Свой профиль';

  @override
  String get originalVersion => 'Исходная версия';

  @override
  String skippedGeodata(String codes) {
    return 'Правила «Напрямую», «Блокировать» и прямого DNS пропускают коды, которых нет в геофайлах: $codes.';
  }

  @override
  String geofileDetails(String bytes, String original, String updated) {
    return '$bytes Б · исходный размер $original Б\nОбновлено $updated';
  }

  @override
  String get unknown => 'Неизвестно';

  @override
  String managedListsError(String error) {
    return 'Управляемые списки: $error';
  }

  @override
  String get serverName => 'Имя сервера';

  @override
  String get diagnosticsSection => 'Диагностика';

  @override
  String get recordConnectionDiagnostics =>
      'Записывать диагностику подключения';

  @override
  String get recordConnectionDiagnosticsHelp =>
      'Пока есть подключение, записывает время соединений, объёмы трафика и ошибки, чтобы проблему можно было отследить. Без сайтов, адресов, учётных данных и содержимого. Почти не нагружает процессор; изменение переподключает.';

  @override
  String get markAction => 'Отметить';

  @override
  String get markProblemNow => 'Отметить проблему сейчас';

  @override
  String get markProblemNowHelp => 'Также на главном экране во время записи.';

  @override
  String get saveRecordingAsZip => 'Сохранить запись в ZIP';

  @override
  String problemMarkedAt(String time) {
    return 'Проблема отмечена в $time. Когда закончите, экспортируйте запись.';
  }

  @override
  String get markNotSaved => 'Не удалось сохранить отметку.';

  @override
  String get recordingSaved => 'Запись сохранена.';

  @override
  String get recordingEmpty =>
      'Пока ничего не записано. Включите «Записывать диагностику подключения», воспроизведите проблему и экспортируйте запись.';

  @override
  String get recordingNotSaved =>
      'Не удалось сохранить запись. Выберите место, доступное для записи, и повторите.';

  @override
  String get recordingConnectionDiagnostics =>
      'Идёт запись диагностики подключения';

  @override
  String get markProblem => 'Отметить проблему';
}
