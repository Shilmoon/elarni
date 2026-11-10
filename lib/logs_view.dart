import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'strings.dart';
import 'tunnel_channel.dart';

Map<String, String> get _levelLabels => {
  'none': l10n.logLevelOff,
  'error': l10n.logLevelError,
  'warning': l10n.logLevelWarning,
  'info': l10n.logLevelInfo,
  'debug': l10n.logLevelDebug,
};

Future<void> showLogsDialog(BuildContext context, TunnelControl control) =>
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.logs,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.close,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Flexible(child: LogsView(control: control)),
              ],
            ),
          ),
        ),
      ),
    );

/// The core's log, redacted where it is recorded. It follows new lines while
/// open, sets the level, and copies or saves the text.
class LogsView extends StatefulWidget {
  const LogsView({super.key, required this.control});

  final TunnelControl control;

  @override
  State<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends State<LogsView> {
  static const _kept = 1000;
  final _lines = <Map<String, Object?>>[];
  final _scroll = ScrollController();
  Timer? _timer;
  String? _level;
  String? _status;
  bool _reading = false;
  bool _savingLevel = false;

  @override
  void initState() {
    super.initState();
    _read();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final after = _lines.isEmpty ? 0 : _lines.last['seq']! as int;
      final value = await widget.control.readLogs(after: after);
      // A restarted core numbers its lines from 1 again.
      final restarted = (value['last'] as int? ?? after) < after;
      final entries = restarted
          ? (await widget.control.readLogs())['entries']
          : value['entries'];
      if (!mounted) return;
      final level = _savingLevel ? _level : value['level'] as String? ?? _level;
      // An idle core sends nothing new; the open dialog need not rebuild.
      if (!restarted &&
          (entries as List? ?? const []).isEmpty &&
          level == _level)
        return;
      final follow = !_scroll.hasClients || _scroll.position.extentAfter < 24;
      setState(() {
        _level = level;
        if (restarted) _lines.clear();
        for (final entry in entries as List? ?? const [])
          if (entry is Map && entry['seq'] is int)
            _lines.add(Map<String, Object?>.from(entry));
        if (_lines.length > _kept) _lines.removeRange(0, _lines.length - _kept);
      });
      if (follow)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients)
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
    } on Object {
      // The next tick retries; the lines already shown stay.
    } finally {
      _reading = false;
    }
  }

  Future<void> _setLevel(String level) async {
    final previous = _level;
    setState(() {
      _level = level;
      _savingLevel = true;
      _status = null;
    });
    String? saved = level;
    String? status;
    try {
      final settings = await widget.control.tunnelSettings();
      await widget.control.updateTunnelSettings(
        settings.copyWith(logLevel: level),
      );
      // The Windows and Linux core reads the level when it starts.
      if (Platform.isWindows || Platform.isLinux)
        status = l10n.logLevelAppliesNextConnection;
    } on Object {
      saved = previous;
      status = l10n.logLevelNotSaved;
    }
    _savingLevel = false;
    // Also without a status line: the dropdown is disabled while saving.
    if (mounted)
      setState(() {
        _level = saved;
        _status = status;
      });
  }

  static String _line(Map<String, Object?> line, {bool export = false}) {
    final time = DateTime.fromMillisecondsSinceEpoch(
      line['time'] as int? ?? 0,
      isUtc: export,
    );
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = export
        ? time.toIso8601String()
        : '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    return '$stamp ${(line['level'] as String? ?? '').toUpperCase()} '
        '${line['text'] ?? ''}';
  }

  String _text() => [
    'Elarni log, level ${_level ?? 'warning'}',
    for (final line in _lines) _line(line, export: true),
  ].join('\n');

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text()));
    if (mounted) setState(() => _status = l10n.copied);
  }

  Future<void> _save() async {
    try {
      await widget.control.saveLogs(_text());
      if (mounted) setState(() => _status = l10n.saved);
    } on PlatformException catch (error) {
      if (!mounted ||
          const {'cancelled', 'operation_cancelled'}.contains(error.code))
        return;
      setState(() => _status = l10n.logNotSaved);
    } on Object {
      if (mounted) setState(() => _status = l10n.logNotSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = _level;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(l10n.logLevel),
            DropdownButton<String>(
              key: const ValueKey('logLevel'),
              value: level,
              onChanged: level == null || _savingLevel
                  ? null
                  : (value) {
                      if (value != null && value != level) _setLevel(value);
                    },
              items: [
                for (final entry in _levelLabels.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
            ),
            TextButton(
              onPressed: _lines.isEmpty ? null : _copy,
              child: Text(l10n.copy),
            ),
            TextButton(
              onPressed: _lines.isEmpty ? null : _save,
              child: Text(l10n.saveEllipsis),
            ),
            if (_status != null)
              Text(_status!, style: theme.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 8),
        Flexible(
          child: _lines.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    level == 'none' ? l10n.loggingOff : l10n.noLogLinesYet,
                    textAlign: TextAlign.center,
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    itemCount: _lines.length,
                    itemBuilder: (context, index) => Text(
                      _line(_lines[index]),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
