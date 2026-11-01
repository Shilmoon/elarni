import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tunnel_channel.dart';
import 'strings.dart';

ThemeData elarniTheme({
  required Brightness brightness,
  required Color accent,
  required bool windows,
  bool linux = false,
}) {
  final dark = brightness == Brightness.dark;
  final surface = dark ? const Color(0xff202124) : Colors.white;
  final secondary = dark ? const Color(0xffaeb3bf) : const Color(0xff626a7c);
  final border = dark ? const Color(0xff3b3e45) : const Color(0xffdfe2e9);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        surface: surface,
      ).copyWith(
        primary: dark ? Color.lerp(accent, Colors.white, .45)! : accent,
        onPrimary: dark ? const Color(0xff10151d) : Colors.white,
        onSurface: dark ? const Color(0xfff3f4f7) : const Color(0xff111827),
        onSurfaceVariant: secondary,
        outline: border,
        outlineVariant: border,
        surfaceContainerLow: dark
            ? const Color(0xff25272c)
            : const Color(0xfff6f7f9),
        surfaceContainerHighest: dark
            ? const Color(0xff34373e)
            : const Color(0xffe8eaf0),
      );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  final base = ThemeData(
    useMaterial3: true,
    platform: linux
        ? TargetPlatform.linux
        : windows
        ? TargetPlatform.windows
        : TargetPlatform.macOS,
    fontFamily: linux
        ? 'sans'
        : windows
        ? 'Segoe UI'
        : '.AppleSystemUIFont',
    colorScheme: scheme,
    scaffoldBackgroundColor: surface,
    visualDensity: VisualDensity.standard,
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 15),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w500,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 40),
        shape: shape,
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 40),
        shape: shape,
        foregroundColor: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerLow,
        side: BorderSide(color: border),
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 40),
        shape: shape,
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        minimumSize: const Size(40, 40),
        iconSize: 21,
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: TextStyle(color: secondary, fontSize: 14),
      labelStyle: TextStyle(color: secondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: accent, width: 2),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: secondary,
      minVerticalPadding: 12,
      subtitleTextStyle: base.textTheme.bodyMedium?.copyWith(
        color: secondary,
        height: 1.4,
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      tilePadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: border)),
        elevation: const WidgetStatePropertyAll(2),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: border),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: dark ? const Color(0xff70c4bd) : const Color(0xff58aaa5),
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
  );
}

enum DesktopPage { home, subscriptions, routing, settings }

/// Shared desktop single-choice control. Values stay owned by the caller so a
/// failed save or refreshed profile is immediately reflected in the menu.
class ElarniSelect<T> extends StatefulWidget {
  const ElarniSelect({
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.hint,
    this.isExpanded = false,
    super.key,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? label;
  final Widget? hint;
  final bool isExpanded;

  @override
  State<ElarniSelect<T>> createState() => _ElarniSelectState<T>();
}

class _ElarniSelectState<T> extends State<ElarniSelect<T>> {
  final _controller = MenuController();
  final _focus = FocusNode();
  final _anchorKey = GlobalKey();
  final _menuStorage = PageStorageBucket();
  double _menuWidth = 210;

  bool get _enabled =>
      widget.onChanged != null && widget.items.any((item) => item.enabled);

  void _open() {
    if (!_enabled) return;
    // Measure after layout; LayoutBuilder prevents AlertDialog from measuring
    // its intrinsic height. The popup must match the actual constrained button.
    final box = _anchorKey.currentContext!.findRenderObject()! as RenderBox;
    setState(() => _menuWidth = box.size.width);
    _controller.open();
  }

  @override
  void didUpdateWidget(covariant ElarniSelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _controller.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_enabled) _controller.close();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = widget.items
        .where((item) => item.value == widget.value)
        .firstOrNull;
    final firstEnabled = widget.items.where((item) => item.enabled).firstOrNull;
    final textStyle = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w400,
    );
    final control = SizedBox(
      key: _anchorKey,
      width: widget.isExpanded ? double.infinity : 210,
      // Menu scroll offsets must not share an ExpansionTile's stored bool.
      child: PageStorage(
        bucket: _menuStorage,
        child: MenuAnchor(
          controller: _controller,
          childFocusNode: _focus,
          crossAxisUnconstrained: false,
          alignmentOffset: const Offset(0, 5),
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            fixedSize: WidgetStatePropertyAll(
              Size(_menuWidth, double.infinity),
            ),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
            backgroundColor: WidgetStatePropertyAll(scheme.surface),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(2),
            shadowColor: WidgetStatePropertyAll(
              Colors.black.withValues(alpha: .3),
            ),
            side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          menuChildren: [
            for (final item in widget.items)
              Semantics(
                selected: item == selected,
                child: MenuItemButton(
                  autofocus: item == (selected ?? firstEnabled),
                  onPressed: !_enabled || !item.enabled
                      ? null
                      : () {
                          _focus.requestFocus();
                          widget.onChanged?.call(item.value);
                        },
                  style: ButtonStyle(
                    minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
                    padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: WidgetStatePropertyAll(textStyle),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.disabled)
                          ? theme.disabledColor
                          : scheme.onSurface,
                    ),
                    backgroundColor: WidgetStatePropertyAll(
                      item == selected
                          ? scheme.primary.withValues(alpha: .14)
                          : Colors.transparent,
                    ),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        child: item == selected
                            ? ExcludeSemantics(
                                child: Icon(
                                  CupertinoIcons.check_mark,
                                  size: 16,
                                  color: scheme.primary,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 9),
                      Expanded(child: item.child),
                    ],
                  ),
                ),
              ),
          ],
          builder: (context, controller, child) => CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.arrowDown): _open,
              const SingleActivator(LogicalKeyboardKey.arrowUp): _open,
            },
            child: Semantics(
              label: widget.label,
              expanded: controller.isOpen,
              child: OutlinedButton(
                focusNode: _focus,
                onPressed: !_enabled
                    ? null
                    : () => controller.isOpen ? controller.close() : _open(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: textStyle,
                  foregroundColor: scheme.onSurface,
                  backgroundColor: scheme.surfaceContainerLow,
                  side: BorderSide(color: scheme.outline),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child:
                          selected?.child ?? widget.hint ?? Text(l10n.select),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      CupertinoIcons.chevron_up_chevron_down,
                      size: 15,
                      color: _enabled
                          ? scheme.onSurfaceVariant
                          : theme.disabledColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.label == null) return control;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label!,
          style: textStyle.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        control,
      ],
    );
  }
}

/// A setting row gives long labels and scaled text room above the selector.
class ElarniSelectTile extends StatelessWidget {
  const ElarniSelectTile({
    required this.title,
    required this.trailing,
    this.subtitle,
    this.contentPadding,
    this.onTap,
    super.key,
  });

  final Widget title;
  final Widget trailing;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 440 &&
          MediaQuery.textScalerOf(context).scale(1) < 1.5) {
        return ListTile(
          onTap: onTap,
          contentPadding: contentPadding,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
        );
      }
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding:
              (contentPadding ?? const EdgeInsets.symmetric(horizontal: 16))
                  .add(const EdgeInsets.symmetric(vertical: 12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              if (subtitle != null) ...[const SizedBox(height: 4), subtitle!],
              const SizedBox(height: 10),
              trailing,
            ],
          ),
        ),
      );
    },
  );
}

class ElarniImportButton extends StatelessWidget {
  const ElarniImportButton({
    required this.busy,
    required this.onSelected,
    this.importing = false,
    super.key,
  });

  // Busy disables the button for any work; only an import changes its label.
  final bool busy, importing;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final source in [
        ('file', l10n.importFromFile, CupertinoIcons.doc),
        (
          'clipboard',
          l10n.importFromClipboard,
          CupertinoIcons.doc_on_clipboard,
        ),
        ('qrImage', l10n.importFromQrImage, CupertinoIcons.qrcode),
        ('camera', l10n.importScanQr, CupertinoIcons.viewfinder),
      ])
        MenuItemButton(
          key: Key('import-${source.$1}'),
          leadingIcon: Icon(source.$3, size: 19),
          onPressed: busy ? null : () => onSelected(source.$1),
          child: Text(source.$2),
        ),
    ],
    builder: (context, controller, child) => OutlinedButton.icon(
      key: const Key('import-toggle'),
      onPressed: busy
          ? null
          : () => controller.isOpen ? controller.close() : controller.open(),
      icon: const Icon(CupertinoIcons.square_arrow_down, size: 18),
      label: Text(importing ? l10n.importingEllipsis : l10n.importAction),
    ),
  );
}

/// Keeps setting explanations beside their label, available by hover or click.
class ElarniHelpLabel extends StatefulWidget {
  const ElarniHelpLabel(this.title, {required this.help, super.key});

  final String title;
  final String help;

  @override
  State<ElarniHelpLabel> createState() => _ElarniHelpLabelState();
}

class _ElarniHelpLabelState extends State<ElarniHelpLabel> {
  final _tooltip = GlobalKey<TooltipState>();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(widget.title)),
      const SizedBox(width: 4),
      Tooltip(
        key: _tooltip,
        constraints: const BoxConstraints(maxWidth: 300),
        message: widget.help,
        child: IconButton(
          onPressed: () => _tooltip.currentState?.ensureTooltipVisible(),
          icon: Icon(
            CupertinoIcons.question_circle,
            size: 18,
            semanticLabel: l10n.helpFor(widget.title),
          ),
        ),
      ),
    ],
  );
}

/// The same Cupertino control on both desktop platforms, with a full row target.
class ElarniSwitchTile extends StatelessWidget {
  const ElarniSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.contentPadding,
    super.key,
  });
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: contentPadding,
    title: title,
    subtitle: subtitle,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: CupertinoSwitch(
      value: value,
      activeTrackColor: Theme.of(context).colorScheme.primary,
      onChanged: onChanged,
    ),
  );
}

/// Compact checkbox rows for Settings and the structured routing editor.
class ElarniCheckboxTile extends StatelessWidget {
  const ElarniCheckboxTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.contentPadding,
    super.key,
  });

  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: contentPadding,
    title: title,
    subtitle: subtitle,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: Checkbox(
      semanticLabel: switch (title) {
        Text(:final data) => data,
        ElarniHelpLabel(:final title) => title,
        _ => null,
      },
      value: value,
      onChanged: onChanged == null ? null : (value) => onChanged!(value!),
    ),
  );
}

enum SettingsCategory {
  general(CupertinoIcons.slider_horizontal_3),
  appearance(CupertinoIcons.paintbrush),
  connection(CupertinoIcons.globe),
  dns(CupertinoIcons.globe),
  advanced(CupertinoIcons.gear_alt),
  ping(CupertinoIcons.waveform_path),
  backup(CupertinoIcons.arrow_clockwise),
  system(CupertinoIcons.info_circle),
  routes(CupertinoIcons.list_bullet);

  const SettingsCategory(this.icon);
  final IconData icon;
  String get label => switch (this) {
    general => l10n.settingsGeneral,
    appearance => l10n.settingsAppearance,
    connection => l10n.settingsConnection,
    dns => 'DNS',
    advanced => l10n.settingsAdvanced,
    ping => l10n.settingsServerTests,
    backup => l10n.settingsBackupAndRepair,
    system => l10n.settingsSystemInfo,
    routes => l10n.settingsRouteTable,
  };
}

class ElarniSettings extends StatelessWidget {
  const ElarniSettings({
    required this.category,
    required this.onSelect,
    required this.children,
    this.help,
    super.key,
  });
  final SettingsCategory category;
  final ValueChanged<SettingsCategory> onSelect;
  final List<Widget> children;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 740 ||
            MediaQuery.textScalerOf(context).scale(1) >= 1.5;
        final content = ListView(
          key: ValueKey('settings-list-${category.name}'),
          padding: EdgeInsets.all(compact ? 16 : 32),
          children: [
            if (help case final help?)
              DefaultTextStyle.merge(
                style: Theme.of(context).textTheme.titleLarge,
                child: ElarniHelpLabel(category.label, help: help),
              )
            else
              Text(
                category.label,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            const SizedBox(height: 24),
            ...children,
          ],
        );
        if (compact) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: ElarniSelect<SettingsCategory>(
                  key: const Key('settings-category'),
                  value: category,
                  isExpanded: true,
                  label: l10n.settingsCategory,
                  items: [
                    for (final value in SettingsCategory.values)
                      DropdownMenuItem(value: value, child: Text(value.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) onSelect(value);
                  },
                ),
              ),
              Expanded(child: content),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 212,
              child: Material(
                color: scheme.surfaceContainerLow,
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 28,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                      child: Text(
                        l10n.settings,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    for (final group in {
                      l10n.settingsGroupPreferences: [
                        SettingsCategory.general,
                        SettingsCategory.appearance,
                      ],
                      l10n.settingsGroupNetwork: [
                        SettingsCategory.connection,
                        SettingsCategory.dns,
                        SettingsCategory.advanced,
                        SettingsCategory.ping,
                      ],
                      l10n.settingsGroupSupport: [
                        SettingsCategory.backup,
                        SettingsCategory.system,
                        SettingsCategory.routes,
                      ],
                    }.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
                        child: Semantics(
                          header: true,
                          child: Text(
                            group.key,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      for (final value in group.value)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: ListTile(
                            key: Key('settings-tab-${value.name}'),
                            selected: value == category,
                            selectedTileColor: scheme.primary.withValues(
                              alpha: .12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            dense: true,
                            title: Text(
                              value.label,
                              style: const TextStyle(fontSize: 14),
                            ),
                            onTap: () => onSelect(value),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: content,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class ElarniShell extends StatelessWidget {
  const ElarniShell({
    required this.page,
    required this.onNavigate,
    required this.onImport,
    required this.importBusy,
    required this.child,
    this.importing = false,
    super.key,
  });

  final DesktopPage page;
  final ValueChanged<DesktopPage> onNavigate;
  final ValueChanged<String> onImport;
  final bool importBusy, importing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final labels =
                constraints.maxWidth >= 1100 &&
                MediaQuery.textScalerOf(context).scale(1) < 1.5;
            final sidebarWidth = labels ? 176.0 : 68.0;
            Widget destination(
              DesktopPage target,
              IconData icon,
              String label,
            ) {
              final selected = page == target;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Tooltip(
                  message: label,
                  child: Semantics(
                    selected: selected,
                    button: true,
                    child: Material(
                      color: selected
                          ? scheme.primary.withValues(alpha: .14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        key: Key('nav-${target.name}'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => onNavigate(target),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 13,
                          ),
                          child: Row(
                            mainAxisSize: compact
                                ? MainAxisSize.min
                                : MainAxisSize.max,
                            mainAxisAlignment: labels
                                ? MainAxisAlignment.start
                                : MainAxisAlignment.center,
                            children: [
                              Icon(
                                icon,
                                size: 23,
                                color: selected
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              if (labels) ...[
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            final toolbar = Container(
              constraints: const BoxConstraints(minHeight: 60),
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 20,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border(
                  bottom: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  // The sidebar already switches pages in a wide window.
                  if (page != DesktopPage.home && compact) ...[
                    IconButton(
                      key: const Key('settings-back'),
                      tooltip: l10n.backToHome,
                      onPressed: () => onNavigate(DesktopPage.home),
                      icon: const Icon(CupertinoIcons.chevron_left, size: 20),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Elarni',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.titleLarge?.copyWith(fontSize: 19),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Image.asset(
                          'assets/branding/elarni-app-icon.png',
                          width: 28,
                          height: 28,
                          excludeFromSemantics: true,
                        ),
                      ],
                    ),
                  ),
                  ElarniImportButton(
                    busy: importBusy,
                    importing: importing,
                    onSelected: onImport,
                  ),
                ],
              ),
            );
            final content = Column(
              children: [
                if (compact)
                  Container(
                    color: scheme.surfaceContainerLow,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        destination(
                          DesktopPage.home,
                          CupertinoIcons.house,
                          l10n.home,
                        ),
                        destination(
                          DesktopPage.subscriptions,
                          CupertinoIcons.rectangle_stack,
                          l10n.subscriptions,
                        ),
                        destination(
                          DesktopPage.routing,
                          CupertinoIcons.arrow_branch,
                          l10n.routing,
                        ),
                        destination(
                          DesktopPage.settings,
                          CupertinoIcons.gear_alt,
                          l10n.settings,
                        ),
                      ],
                    ),
                  ),
                Expanded(child: child),
              ],
            );
            return Column(
              children: [
                toolbar,
                Expanded(
                  child: compact
                      ? content
                      : Row(
                          children: [
                            Container(
                              width: sidebarWidth,
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerLow,
                                border: Border(
                                  right: BorderSide(
                                    color: scheme.outlineVariant,
                                  ),
                                ),
                              ),
                              child: Column(
                                children: [
                                  const SizedBox(height: 12),
                                  destination(
                                    DesktopPage.home,
                                    page == DesktopPage.home
                                        ? CupertinoIcons.house_fill
                                        : CupertinoIcons.house,
                                    l10n.home,
                                  ),
                                  destination(
                                    DesktopPage.subscriptions,
                                    CupertinoIcons.rectangle_stack,
                                    l10n.subscriptions,
                                  ),
                                  destination(
                                    DesktopPage.routing,
                                    CupertinoIcons.arrow_branch,
                                    l10n.routing,
                                  ),
                                  const Spacer(),
                                  destination(
                                    DesktopPage.settings,
                                    CupertinoIcons.gear_alt,
                                    l10n.settings,
                                  ),
                                  const SizedBox(height: 18),
                                ],
                              ),
                            ),
                            Expanded(child: content),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Account figures reported by the provider, never session traffic or an
/// assumed billing period. A missing value has no meaningful progress fraction.
class SubscriptionUsage {
  SubscriptionUsage(Map<String, Object?> metadata, DateTime now) {
    num? number(String key) {
      final value = metadata[key];
      return value is num && value.isFinite && value >= 0 ? value : null;
    }

    final total = number('total');
    final upload = number('upload');
    final download = number('download');
    if (total == 0) {
      data = l10n.unlimited;
      unlimitedData = true;
    } else if (total != null && upload != null && download != null) {
      final remaining = (total - upload - download).clamp(0, total);
      data = remaining == 0
          ? l10n.dataExhausted
          : l10n.amountLeft(bytes(remaining));
      dataFraction = (remaining / total).toDouble();
      exhausted = remaining == 0;
    }
    final expire = number('expire');
    if (expire == 0) {
      time = l10n.noExpiry;
      noExpiry = true;
    } else if (expire != null && expire <= 253402300799) {
      final remaining = expire - now.millisecondsSinceEpoch / 1000;
      expired = remaining <= 0;
      final days = (remaining / Duration.secondsPerDay).ceil();
      time = expired
          ? l10n.expired
          : remaining < Duration.secondsPerDay
          ? l10n.lessThanDayLeft
          : l10n.daysLeft(days);
    }
  }

  String time = l10n.notProvided;
  String data = l10n.notProvided;
  double? dataFraction;
  bool unlimitedData = false;
  bool noExpiry = false;
  bool expired = false;
  bool exhausted = false;

  static String bytes(num count) {
    for (final (size, unit) in [
      (1073741824, l10n.gibibytes),
      (1048576, l10n.mebibytes),
      (1024, l10n.kibibytes),
    ]) {
      if (count >= size) {
        final value = count / size;
        return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} $unit';
      }
    }
    return l10n.bytesCount(count.toStringAsFixed(0));
  }
}

class ProtocolTag extends StatelessWidget {
  const ProtocolTag(this.protocol, {super.key});
  final String protocol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: l10n.protocolTooltip(protocol),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            protocol,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class LatencyBadge extends StatelessWidget {
  const LatencyBadge(
    this.latencyMs, {
    this.labelKey,
    this.semanticsLabel,
    super.key,
  });

  final int latencyMs;
  final Key? labelKey;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (foreground, background) = switch (latencyMs) {
      < 100 =>
        dark
            ? (const Color(0xff86efac), const Color(0xff173b29))
            : (const Color(0xff166534), const Color(0xffdcfce7)),
      < 300 =>
        dark
            ? (const Color(0xfffde047), const Color(0xff453810))
            : (const Color(0xff854d0e), const Color(0xfffef9c3)),
      _ =>
        dark
            ? (const Color(0xfffca5a5), const Color(0xff492326))
            : (const Color(0xff991b1b), const Color(0xfffee2e2)),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: background,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        child: Text(
          l10n.latencyMs(latencyMs),
          key: labelKey,
          semanticsLabel: semanticsLabel,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: foreground,
          ),
        ),
      ),
    );
  }
}

/// Provider-authored content stays attributed and never becomes app guidance.
class ProviderNotice extends StatefulWidget {
  const ProviderNotice({
    required this.group,
    required this.onOpenLink,
    this.initiallyExpanded = false,
    this.compact = false,
    super.key,
  });

  final SubscriptionGroup group;
  final VoidCallback? onOpenLink;
  final bool initiallyExpanded;
  final bool compact;

  static List<String> messages(SubscriptionGroup group) => {
    for (final key in ['announcement', 'bannerText'])
      if (group.metadata[key] case final String text)
        if (text.trim().isNotEmpty) text.trim(),
  }.toList();

  @override
  State<ProviderNotice> createState() => _ProviderNoticeState();
}

class _ProviderNoticeState extends State<ProviderNotice> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ExpansionTile restores this same value while building. Mirror it before
    // its callback so restoring an open notice does not rebuild its ancestor.
    final stored = PageStorage.maybeOf(context)?.readState(context);
    _expanded = stored is bool ? stored : widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final messages = ProviderNotice.messages(widget.group);
    if (messages.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.compact ? double.infinity : 440,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              key: ValueKey('provider-notice:${widget.group.id}'),
              initiallyExpanded: widget.initiallyExpanded,
              onExpansionChanged: (value) {
                if (value != _expanded) setState(() => _expanded = value);
              },
              shape: const Border(),
              collapsedShape: const Border(),
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              leading: widget.compact
                  ? Icon(
                      CupertinoIcons.chat_bubble,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    )
                  : null,
              title: LayoutBuilder(
                builder: (context, constraints) {
                  final title = Text(
                    l10n.messageFrom(widget.group.name),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                  if (!widget.compact || _expanded) return title;
                  final narrow =
                      constraints.maxWidth < 400 ||
                      MediaQuery.textScalerOf(context).scale(1) >= 1.5;
                  final excerpt = Text(
                    messages.first.replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: narrow ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 14,
                    ),
                  );
                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [title, const SizedBox(height: 4), excerpt],
                    );
                  }
                  return Row(
                    children: [
                      Flexible(child: title),
                      const SizedBox(width: 14),
                      Expanded(child: excerpt),
                    ],
                  );
                },
              ),
              subtitle: _expanded || widget.compact
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        messages.first.replaceAll(RegExp(r'\s+'), ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
              children: [
                for (var i = 0; i < messages.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: SelectableText(
                        messages[i],
                        key: PageStorageKey(
                          'provider-text:${widget.group.id}:$i',
                        ),
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (widget.group.actions.contains('banner'))
                        TextButton.icon(
                          onPressed: widget.onOpenLink,
                          icon: const Icon(
                            CupertinoIcons.arrow_up_right_square,
                            size: 16,
                          ),
                          label: Text(
                            widget.group.metadata['bannerButtonText']
                                    as String? ??
                                l10n.openProviderPage,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SubscriptionSummary extends StatelessWidget {
  const SubscriptionSummary({
    required this.group,
    required this.onOpen,
    this.refreshFailed = false,
    super.key,
  });
  final SubscriptionGroup group;
  final VoidCallback onOpen;
  final bool refreshFailed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 340,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton(
            key: const Key('current-subscription'),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              foregroundColor: scheme.onSurface,
            ),
            onPressed: onOpen,
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.checkmark_shield,
                  color: scheme.onSurfaceVariant,
                  size: 25,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(group.name, style: const TextStyle(fontSize: 16)),
                ),
                const SizedBox(width: 8),
                const Icon(CupertinoIcons.chevron_right, size: 21),
              ],
            ),
          ),
          SubscriptionUsageIndicators(
            group: group,
            refreshFailed: refreshFailed,
          ),
        ],
      ),
    );
  }
}

/// Reported allowance and warnings for the Home subscription summary.
class SubscriptionUsageIndicators extends StatelessWidget {
  const SubscriptionUsageIndicators({
    required this.group,
    this.refreshFailed = false,
    super.key,
  });

  final SubscriptionGroup group;
  final bool refreshFailed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usage = SubscriptionUsage(group.metadata, DateTime.now());
    Widget metric(
      String id,
      String label,
      String value, {
      double? fraction,
      bool warning = false,
      bool unlimited = false,
    }) {
      return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              runSpacing: 4,
              children: [
                Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
                if (unlimited)
                  Icon(
                    CupertinoIcons.infinite,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                    semanticLabel: '$label: $value',
                  )
                else
                  Text(
                    value,
                    style: TextStyle(
                      color: warning ? scheme.error : scheme.onSurface,
                    ),
                  ),
              ],
            ),
            // Unlimited allowances use a full bar without announcing 100%.
            if (unlimited || fraction != null) ...[
              const SizedBox(height: 8),
              ExcludeSemantics(
                excluding: unlimited,
                child: LinearProgressIndicator(
                  key: Key('subscription-$id-progress'),
                  value: unlimited ? 1 : fraction,
                  minHeight: 8,
                  color: warning ? scheme.error : null,
                  semanticsLabel: l10n.remainingSemantics(label, value),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!group.isLocal) ...[
          metric(
            'time',
            l10n.usageTime,
            usage.time,
            warning: usage.expired,
            unlimited: usage.noExpiry,
          ),
          metric(
            'data',
            l10n.usageData,
            usage.data,
            fraction: usage.dataFraction,
            warning: usage.exhausted,
            unlimited: usage.unlimitedData,
          ),
          if (refreshFailed ||
              group.status != 'ready' ||
              group.metadata['enabled'] == false) ...[
            const SizedBox(height: 14),
            Text(
              group.metadata['enabled'] == false
                  ? l10n.accountDisabledByProvider
                  : refreshFailed || group.status == 'refresh_failed'
                  ? l10n.refreshFailedLastReported
                  : group.status == 'refreshing'
                  ? l10n.refreshingLastReported
                  : group.status == 'pending'
                  ? l10n.notDownloadedYet
                  : l10n.providerAttentionLastReported,
              style: TextStyle(color: scheme.error, fontSize: 13),
            ),
          ],
        ],
      ],
    );
  }
}
