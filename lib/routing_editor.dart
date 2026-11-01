import 'dart:convert';

import 'package:flutter/material.dart';
import 'elarni_widgets.dart';
import 'strings.dart';

/// Russian national zones and the other domains these services use (v2fly
/// domain-list-community); banks, Gosuslugi and marketplaces have no desktop apps to match.
const russianSitesPreset = <String>[
  'domain:ru',
  'domain:xn--p1ai',
  'domain:su',
  'domain:ozon.com',
  'domain:ozonusercontent.com',
  'domain:ozon.kz',
  'domain:wbstatic.net',
  'domain:wbcontent.net',
  'domain:wb.kz',
  'domain:paywb.com',
  'domain:yandex.net',
  'domain:yandex.com',
  'domain:yastatic.net',
  'domain:yastat.net',
  'domain:yandexcloud.net',
  'domain:yandex.cloud',
  'domain:ya.cc',
  'domain:yadi.sk',
  'domain:naydex.net',
  'domain:vk.com',
  'domain:vk.me',
  'domain:userapi.com',
  'domain:vkuser.net',
  'domain:vk-cdn.net',
  'domain:vkuseraudio.net',
  'domain:vkuservideo.net',
  'domain:vkuserlive.net',
  'domain:vkcache.com',
  'domain:mycdn.me',
  'domain:mvk.com',
  'domain:sberbank.com',
  'domain:tbank-online.com',
  'domain:tinkoff-group.com',
  'domain:tinkoffmobile.com',
  'domain:vtb.com',
  'domain:vtb-direct.com',
  'domain:alfa.me',
  'domain:alfabank.st',
];

class RoutingEditor extends StatefulWidget {
  const RoutingEditor({
    super.key,
    required this.json,
    this.onSave,
    this.initialSection = 0,
  });
  final String json;
  final Future<bool> Function(String)? onSave;
  final int initialSection;

  @override
  State<RoutingEditor> createState() => _RoutingEditorState();
}

class _RoutingEditorState extends State<RoutingEditor> {
  late final Map<String, dynamic> _profile;
  final _fields = <String, TextEditingController>{};
  late bool _explicitDNS;
  String? _error;
  bool _saving = false;
  late int _section;
  final _expanded = <String>{'Direct', 'Remote'};
  String _dnsName(String role) =>
      role == 'Remote' ? l10n.remoteDns : l10n.domesticDns;

  static const _lists = <String>[
    'DomesticDNSDomains',
    'DirectSites',
    'DirectIp',
    'ProxySites',
    'ProxyIp',
    'BlockSites',
    'BlockIp',
  ];

  @override
  void initState() {
    super.initState();
    _section = widget.initialSection;
    _profile = Map<String, dynamic>.from(jsonDecode(widget.json) as Map);
    _profile['FakeDNS'] ??= _profile['FakeDns'] ?? 'false';
    _explicitDNS = _profile['DomesticDNSDomains'] is List;
    for (final key in <String>[
      'Name',
      'RemoteDNSDomain',
      'RemoteDNSIP',
      'DomesticDNSDomain',
      'DomesticDNSIP',
      ..._lists,
    ]) {
      var value = _profile[key];
      if (key == 'RemoteDNSIP' && (value == null || value == '')) {
        value = _profile['RemoteDNSIp'] ?? _profile['RemoteDns'];
      }
      if (key == 'DomesticDNSIP' && (value == null || value == '')) {
        value = _profile['DomesticDNSIp'] ?? _profile['DomesticDns'];
      }
      _fields[key] = TextEditingController(
        text: value is List ? value.join('\n') : value?.toString() ?? '',
      );
    }
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  bool _enabled(String key) => _profile[key] == true || _profile[key] == 'true';

  // Mirrors the per-target checks of native decode_routing: routing.rs
  // validation and the IP rule check in compiler.rs (native/elarni-domain).
  static bool _validIpTarget(String text) {
    // Rust char::is_whitespace; RegExp \s differs at U+0085 and U+FEFF.
    if (RegExp(
          r'[\t-\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]',
        ).hasMatch(text) ||
        utf8.encode(text).length > 512) {
      return false;
    }
    final target = text.replaceFirst(RegExp('^!+'), '');
    if (RegExp('^(geoip|ext|ext-ip):').hasMatch(target)) return true;
    final slash = target.indexOf('/');
    final address = slash < 0 ? target : target.substring(0, slash);
    final List<int> bytes;
    try {
      // Unlike InternetAddress.tryParse, these match Rust's IpAddr grammar on
      // every platform: no scope IDs and no leading zeros.
      bytes = address.contains(':')
          ? Uri.parseIPv6Address(address)
          : Uri.parseIPv4Address(address);
    } on Object {
      // Some malformed input such as 1:2:3:4:5:6:7::8 throws IndexError.
      return false;
    }
    if (slash < 0) return true;
    final prefix = target.substring(slash + 1);
    // Rust u8 parsing: an optional + and decimal digits.
    final bits = RegExp(r'^\+?[0-9]+$').hasMatch(prefix)
        ? int.tryParse(prefix)
        : null;
    return bits != null && bits <= bytes.length * 8;
  }

  Widget _text(String key, String label, {String? hint, bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(
          key: ValueKey('routing-field:$key'),
          controller: _fields[key],
          enabled: enabled,
          minLines: _lists.contains(key) ? 2 : 1,
          maxLines: _lists.contains(key) ? 5 : 1,
          decoration: InputDecoration(
            labelText: label,
            helperText: hint,
            helperMaxLines: 3,
          ),
        ),
      );

  Widget _choice(
    String key,
    String label,
    List<String> choices, {
    Map<String, String> labels = const {},
  }) => ElarniSelectTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    trailing: ElarniSelect<String>(
      value: choices.contains(_profile[key]) ? _profile[key] as String : null,
      hint: Text(l10n.select),
      items: choices
          .map(
            (value) => DropdownMenuItem(
              value: value,
              child: Text(labels[value] ?? value),
            ),
          )
          .toList(),
      onChanged: (value) => setState(() => _profile[key] = value),
    ),
  );

  Future<void> _save() async {
    if (_saving) return;
    for (final entry in _fields.entries) {
      final text = entry.value.text.trim();
      if (_lists.contains(entry.key)) {
        _profile[entry.key] = text
            .split(RegExp(r'[\r\n]+'))
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList();
      } else {
        _profile[entry.key] = entry.key == 'Name' && text.isEmpty ? null : text;
      }
    }
    if (!_explicitDNS) _profile.remove('DomesticDNSDomains');
    for (final key in ['DirectIp', 'ProxyIp', 'BlockIp']) {
      if (!(_profile[key] as List).cast<String>().every(_validIpTarget)) {
        setState(() => _error = l10n.routingIpTargetsInvalid(key));
        return;
      }
    }
    for (final alias in [
      'RemoteDNSIp',
      'RemoteDns',
      'DomesticDNSIp',
      'DomesticDns',
      'FakeDns',
    ]) {
      _profile.remove(alias);
    }
    for (final role in ['Remote', 'Domestic']) {
      final ip = _fields['${role}DNSIP']!.text.trim();
      final type = _profile['${role}DNSType'];
      // DoH needs no bootstrap IP; any IP is a plain address, as the compiler reads it.
      final validIp = ip.isEmpty
          ? type == 'DoH'
          : RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(ip) && _validIpTarget(ip);
      if (!validIp || !const ['DoH', 'DoU'].contains(type)) {
        setState(() => _error = l10n.routingDnsNeedsResolver(_dnsName(role)));
        return;
      }
      if (type == 'DoH') {
        final url = Uri.tryParse(_fields['${role}DNSDomain']!.text.trim());
        if (url == null ||
            url.scheme != 'https' ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty ||
            url.hasFragment) {
          setState(() => _error = l10n.routingDnsNeedsHttpsUrl(_dnsName(role)));
          return;
        }
      }
    }
    final content = jsonEncode(_profile);
    final route = ModalRoute.of(context);
    setState(() => _saving = true);
    try {
      if (widget.onSave != null && !await widget.onSave!(content)) {
        if (mounted) setState(() => _error = l10n.routingChangeFailed);
        return;
      }
      if (mounted && route?.isCurrent == true) Navigator.pop(context, content);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Keeps the user's lines first and adds each preset entry once.
  void _addSites(String key, List<String> sites) {
    final field = _fields[key]!;
    final current = field.text
        .split(RegExp(r'[\r\n]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    field.text = [
      ...current,
      ...sites.where((site) => !current.contains(site)),
    ].join('\n');
  }

  Widget _rules() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ElarniSelectTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.unmatchedTraffic),
        trailing: ElarniSelect<bool>(
          value: _enabled('GlobalProxy'),
          items: [
            DropdownMenuItem(value: true, child: Text(l10n.useProxy)),
            DropdownMenuItem(value: false, child: Text(l10n.connectDirectly)),
          ],
          onChanged: (value) =>
              setState(() => _profile['GlobalProxy'] = value.toString()),
        ),
      ),
      for (final action in ['Direct', 'Proxy', 'Block'])
        ExpansionTile(
          key: PageStorageKey('routing-rules:$action'),
          title: Text(switch (action) {
            'Direct' => l10n.directRules,
            'Proxy' => l10n.proxyRules,
            _ => l10n.blockRules,
          }),
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: _expanded.contains(action),
          onExpansionChanged: (open) =>
              open ? _expanded.add(action) : _expanded.remove(action),
          children: [
            if (action == 'Direct')
              Align(
                alignment: Alignment.centerRight,
                child: MenuAnchor(
                  menuChildren: [
                    MenuItemButton(
                      onPressed: () =>
                          _addSites('DirectSites', russianSitesPreset),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.russianSitesDirect),
                          Text(
                            l10n.russianSitesPresetHelp,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                  builder: (context, controller, child) => TextButton.icon(
                    key: Key('routing-preset:$action'),
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l10n.addPreset),
                  ),
                ),
              ),
            _text('${action}Sites', l10n.domains, hint: l10n.domainRulesHint),
            _text(
              '${action}Ip',
              l10n.ipAddressesAndNetworks,
              hint: l10n.ipRulesHint,
            ),
          ],
        ),
    ],
  );

  Widget _dns() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ElarniCheckboxTile(
        contentPadding: EdgeInsets.zero,
        title: ElarniHelpLabel(
          l10n.keepDomainIdentity,
          help: l10n.keepDomainIdentityHelp,
        ),
        value: _enabled('FakeDNS'),
        onChanged: (value) => setState(() {
          _profile.remove('FakeDns');
          _profile['FakeDNS'] = value.toString();
        }),
      ),
      for (final role in ['Remote', 'Domestic'])
        ExpansionTile(
          key: PageStorageKey('routing-dns:$role'),
          title: Text(role == 'Remote' ? l10n.remoteDns : l10n.directDns),
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: _expanded.contains(role),
          onExpansionChanged: (open) =>
              open ? _expanded.add(role) : _expanded.remove(role),
          children: [
            _choice(
              '${role}DNSType',
              l10n.resolverType,
              ['DoH', 'DoU'],
              labels: const {'DoH': 'DNS over HTTPS', 'DoU': 'UDP'},
            ),
            if (_profile['${role}DNSType'] == 'DoH')
              _text('${role}DNSDomain', l10n.httpsUrl),
            _text(
              '${role}DNSIP',
              _profile['${role}DNSType'] == 'DoH'
                  ? l10n.bootstrapIp
                  : l10n.resolverIp,
            ),
          ],
        ),
      ExpansionTile(
        key: const PageStorageKey('routing-dns:domains'),
        title: Text(l10n.chooseDnsByDomain),
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: _expanded.contains('domains'),
        onExpansionChanged: (open) =>
            open ? _expanded.add('domains') : _expanded.remove('domains'),
        children: [
          ElarniCheckboxTile(
            contentPadding: EdgeInsets.zero,
            title: ElarniHelpLabel(
              l10n.useExplicitDomainRules,
              help: l10n.explicitDomainRulesHelp,
            ),
            value: _explicitDNS,
            onChanged: (value) => setState(() => _explicitDNS = value),
          ),
          _text(
            'DomesticDNSDomains',
            l10n.domainsUsingDirectDns,
            hint: l10n.directDnsDomainsHint,
            enabled: _explicitDNS,
          ),
        ],
      ),
    ],
  );

  Widget _advanced() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _text('Name', l10n.profileName),
      _choice(
        'RouteOrder',
        l10n.ruleGroupOrder,
        [
          'block-direct-proxy',
          'block-proxy-direct',
          'direct-block-proxy',
          'direct-proxy-block',
          'proxy-block-direct',
          'proxy-direct-block',
        ],
        labels: {
          for (final order in const [
            'block-direct-proxy',
            'block-proxy-direct',
            'direct-block-proxy',
            'direct-proxy-block',
            'proxy-block-direct',
            'proxy-direct-block',
          ])
            order: order
                .split('-')
                .map(
                  (group) => switch (group) {
                    'block' => l10n.ruleGroupBlock,
                    'direct' => l10n.ruleGroupDirect,
                    _ => l10n.ruleGroupProxy,
                  },
                )
                .join(' → '),
        },
      ),
      _choice(
        'DomainStrategy',
        l10n.resolveDomainsForRouting,
        ['AsIs', 'IPIfNonMatch', 'IPOnDemand'],
        labels: {
          'AsIs': l10n.keepDomainNames,
          'IPIfNonMatch': l10n.resolveIfNoRuleMatches,
          'IPOnDemand': l10n.resolveWhenNeeded,
        },
      ),
      ElarniCheckboxTile(
        contentPadding: EdgeInsets.zero,
        title: ElarniHelpLabel(
          l10n.reduceRoutingDataSize,
          help: l10n.reduceRoutingDataHelp,
        ),
        value: _enabled('UseChunkFiles'),
        onChanged: (value) => setState(() => _profile['UseChunkFiles'] = value),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: widget.initialSection,
    child: AlertDialog(
      title: Text(_profile['Name']?.toString() ?? l10n.routingAndDns),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              onTap: (index) => setState(() => _section = index),
              tabs: [
                Tab(text: l10n.rulesTab),
                Tab(text: 'DNS'),
                Tab(text: l10n.settingsAdvanced),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                key: ValueKey('routing-section:$_section'),
                child: switch (_section) {
                  0 => _rules(),
                  1 => _dns(),
                  _ => _advanced(),
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          // Cancel cannot hide a save that is still being applied.
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(l10n.validateAndSave),
        ),
      ],
    ),
  );
}
