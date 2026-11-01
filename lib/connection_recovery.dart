import 'package:flutter/material.dart';

import 'connection_support.dart';
import 'elarni_widgets.dart';
import 'server_locations.dart';
import 'tunnel_channel.dart';
import 'strings.dart';

class ConnectionRecoveryDialog extends StatefulWidget {
  const ConnectionRecoveryDialog({
    super.key,
    required this.groups,
    required this.selectedId,
    required this.snapshot,
    required this.save,
  });
  final List<SubscriptionGroup> groups;
  final String selectedId;
  final Map<String, Object?> snapshot;
  final Future<void> Function(AutomationConfiguration) save;

  @override
  State<ConnectionRecoveryDialog> createState() =>
      _ConnectionRecoveryDialogState();
}

class _ConnectionRecoveryDialogState extends State<ConnectionRecoveryDialog> {
  late String _mode;
  late final List<String> _nodes;
  late final List<TextEditingController> _urls, _statuses, _bodies;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = widget.snapshot['configuration'] as Map? ?? {};
    _mode = config['enabled'] != true
        ? 'off'
        : const {'fixed', 'lowestLatency'}.contains(config['policy'])
        ? config['policy'] as String
        : 'orderedFallback';
    final available = {
      for (final group in widget.groups) ...group.nodes.map((n) => n.id),
    };
    _nodes = [
      widget.selectedId,
      ...((config['nodeIDs'] as List?) ?? []).whereType<String>().where(
        (id) => id != widget.selectedId && available.contains(id),
      ),
    ];
    final targets = ((config['targets'] as List?) ?? [])
        .whereType<Map>()
        .toList();
    _urls = List.generate(
      2,
      (i) => TextEditingController(
        text: i < targets.length
            ? targets[i]['url'] as String? ?? ''
            : i == 0
            ? 'https://www.gstatic.com/generate_204'
            : '',
      ),
    );
    _statuses = List.generate(
      2,
      (i) => TextEditingController(
        text: i < targets.length
            ? '${targets[i]['expectedStatus'] ?? 204}'
            : '204',
      ),
    );
    _bodies = List.generate(
      2,
      (i) => TextEditingController(
        text: i < targets.length
            ? targets[i]['expectedBody'] as String? ?? ''
            : '',
      ),
    );
  }

  @override
  void dispose() {
    for (final controller in [..._urls, ..._statuses, ..._bodies]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final targets = <AutomationTarget>[];
    if (_mode != 'off') {
      for (var i = 0; i < 2; i++) {
        final text = _urls[i].text.trim();
        if (text.isEmpty && i == 1 && _mode == 'fixed') continue;
        final url = Uri.tryParse(text);
        final status = int.tryParse(_statuses[i].text);
        if (url == null ||
            !{'https', 'http'}.contains(url.scheme) ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty ||
            url.hasFragment ||
            status == null ||
            status < 200 ||
            status > 299) {
          setState(() => _error = l10n.recoveryTargetInvalid(i + 1));
          return;
        }
        if (targets.any(
          (target) =>
              Uri.parse(target.url).host.toLowerCase() ==
              url.host.toLowerCase(),
        )) {
          setState(() => _error = l10n.recoveryTargetsSameHost);
          return;
        }
        targets.add(
          AutomationTarget(
            id: 'target${i + 1}',
            url: text,
            expectedStatus: status,
            expectedBody: _bodies[i].text,
          ),
        );
      }
      if (_mode != 'fixed' && _nodes.length < 2) {
        setState(() => _error = l10n.recoveryChooseBackup);
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final nodeIds = _mode == 'fixed' || _mode == 'off'
        ? [widget.selectedId]
        : List.of(_nodes);
    final names = {
      for (final group in widget.groups)
        for (final node in group.nodes) node.id: node.name,
    };
    try {
      await widget.save(
        AutomationConfiguration(
          enabled: _mode != 'off',
          policy: AutomationSelectionPolicy.values.byName(
            _mode == 'off' ? 'fixed' : _mode,
          ),
          subscriptionId: widget.groups
              .firstWhere(
                (group) => group.nodes.any((n) => n.id == widget.selectedId),
                orElse: () => widget.groups.first,
              )
              .id,
          nodeIds: nodeIds,
          russianEntryNodeIds: [
            for (final id in nodeIds)
              if (ServerLocation.russianEntry(names[id] ?? '')) id,
          ],
          targets: targets,
        ),
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted)
        setState(() => _error = ConnectionIssue.from(error).description);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(l10n.connectionRecovery),
    scrollable: true,
    content: SizedBox(
      width: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.recoveryIntro),
          const SizedBox(height: 16),
          ElarniSelect<String>(
            key: const Key('recovery-mode'),
            value: _mode,
            isExpanded: true,
            label: l10n.recovery,
            items: [
              DropdownMenuItem(value: 'off', child: Text(l10n.off)),
              DropdownMenuItem(
                value: 'fixed',
                child: Text(l10n.recoveryReconnectThisServer),
              ),
              DropdownMenuItem(
                value: 'orderedFallback',
                child: Text(l10n.recoveryUseAllowedBackups),
              ),
              DropdownMenuItem(
                value: 'lowestLatency',
                child: Text(l10n.lowestLatency),
              ),
            ],
            onChanged: _saving
                ? null
                : (value) => setState(() => _mode = value!),
          ),
          if (widget.snapshot['policySupported'] == false) ...[
            const SizedBox(height: 12),
            Text(ConnectionIssue.forCode('unsupportedPolicy').description),
          ],
          if (_mode == 'orderedFallback' || _mode == 'lowestLatency') ...[
            const SizedBox(height: 16),
            Text(
              _mode == 'orderedFallback'
                  ? l10n.recoveryOrderedHelp
                  : l10n.recoveryLatencyHelp,
            ),
            for (final group in widget.groups)
              // Recovery runs VPN servers only; a Telegram proxy fails on save.
              if (group.nodes
                      .where((n) => n.id != widget.selectedId && n.isVPN)
                      .toList()
                  case final nodes when nodes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(group.name, style: Theme.of(context).textTheme.labelLarge),
                for (final node in nodes)
                  CheckboxListTile(
                    key: ValueKey('backup:${node.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(node.name),
                    subtitle: _nodes.contains(node.id)
                        ? Text(
                            l10n.recoveryBackupNumber(_nodes.indexOf(node.id)),
                          )
                        : null,
                    value: _nodes.contains(node.id),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              _nodes.add(node.id);
                            } else {
                              _nodes.remove(node.id);
                            }
                          }),
                  ),
              ],
            const SizedBox(height: 8),
            Text(
              l10n.recoveryTcpFirstHelp,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_mode != 'off') ...[
            const SizedBox(height: 16),
            Text(l10n.recoveryChecksHelp),
            for (var i = 0; i < 2; i++) ...[
              const SizedBox(height: 12),
              TextField(
                key: ValueKey('recovery-url:$i'),
                controller: _urls[i],
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: i == 0 ? l10n.checkUrl : l10n.secondCheckUrl,
                  helperText: i == 1 ? l10n.recoverySecondUrlOptional : null,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _statuses[i],
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l10n.expectedHttpStatus),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _bodies[i],
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: l10n.expectedResponseBodyOptional,
                ),
              ),
            ],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(l10n.cancel),
      ),
      FilledButton(
        onPressed:
            _saving ||
                (_mode != 'off' &&
                    _mode != 'fixed' &&
                    widget.snapshot['policySupported'] == false)
            ? null
            : _save,
        child: Text(_saving ? l10n.savingEllipsis : l10n.save),
      ),
    ],
  );
}
