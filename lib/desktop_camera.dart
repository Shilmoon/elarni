import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'strings.dart';

// Frames live only in memory and the native camera closes with the dialog.
final class DesktopCamera {
  DesktopCamera(this.navigator, {this.linux = false});
  final bool linux;
  final GlobalKey<NavigatorState> navigator;
  BuildContext? _dialog;
  bool _active = false, _cancelled = false;

  void cancel() {
    _cancelled = true;
    final context = _dialog;
    if (context != null &&
        context.mounted &&
        ModalRoute.of(context)?.isCurrent == true)
      Navigator.of(context).pop();
  }

  Future<String> scan(Future<String> Function(Uint8List) decode) async {
    if (_active) throw PlatformException(code: 'busy');
    final context = navigator.currentContext;
    if (context == null) throw PlatformException(code: 'camera_unavailable');
    _active = true;
    _cancelled = false;
    try {
      final value = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          _dialog = context;
          if (_cancelled) scheduleMicrotask(cancel);
          return _CameraDialog(decode, linux: linux);
        },
      );
      if (value == null) throw PlatformException(code: 'cancelled');
      return value;
    } finally {
      _dialog = null;
      _active = false;
    }
  }
}

class _CameraDialog extends StatefulWidget {
  const _CameraDialog(this.decode, {required this.linux});
  final bool linux;
  final Future<String> Function(Uint8List) decode;
  @override
  State<_CameraDialog> createState() => _CameraDialogState();
}

class _CameraDialogState extends State<_CameraDialog> {
  late final _channel = MethodChannel(
    widget.linux ? 'com.elarni/linux' : 'com.elarni/windows',
  );
  Uint8List? _frame;
  String? _error;
  bool _decoding = false, _done = false;
  DateTime _nextDecode = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    var readyBy = DateTime.now().add(const Duration(seconds: 10));
    while (mounted && !_done) {
      final started = Stopwatch()..start();
      try {
        Uint8List? frame;
        try {
          frame = await _channel
              .invokeMethod<Uint8List>('cameraFrame', {})
              .timeout(const Duration(seconds: 10));
        } on PlatformException catch (error) {
          if (error.code != 'busy' || DateTime.now().isAfter(readyBy)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 33));
          continue;
        }
        if (!mounted || _done) return;
        if (frame != null) {
          if (frame.isEmpty || frame.length > 8 * 1024 * 1024)
            throw PlatformException(code: 'camera_unavailable');
          readyBy = DateTime.now().add(const Duration(seconds: 10));
          final previous = _frame;
          setState(() => _frame = frame);
          if (previous != null)
            PaintingBinding.instance.imageCache.evict(MemoryImage(previous));
          // QR work can take longer than a video frame. Keep one decode in
          // flight, at most four per second, without delaying the preview.
          if (!_decoding && !DateTime.now().isBefore(_nextDecode)) {
            _nextDecode = DateTime.now().add(const Duration(milliseconds: 250));
            unawaited(_decode(frame));
          }
        } else if (DateTime.now().isAfter(readyBy)) {
          throw PlatformException(code: 'camera_unavailable');
        }
      } on Object {
        _fail();
        return;
      }
      final remaining = 33 - started.elapsedMilliseconds;
      await Future<void>.delayed(
        Duration(milliseconds: remaining > 0 ? remaining : 1),
      );
    }
  }

  Future<void> _decode(Uint8List frame) async {
    _decoding = true;
    try {
      final text = await widget.decode(frame);
      if (mounted && !_done && ModalRoute.of(context)?.isCurrent == true) {
        _done = true;
        Navigator.of(context).pop(text);
      }
    } on PlatformException catch (error) {
      if (error.code != 'invalid_qr_image' && mounted && !_done) _fail();
    } on Object {
      if (mounted && !_done) _fail();
    } finally {
      _decoding = false;
    }
  }

  void _fail() {
    _done = true;
    unawaited(
      _channel.invokeMethod<void>('cameraStop', {}).catchError((Object _) {}),
    );
    if (mounted) setState(() => _error = l10n.cameraUnavailable);
  }

  @override
  void dispose() {
    _done = true;
    unawaited(
      _channel.invokeMethod<void>('cameraStop', {}).catchError((Object _) {}),
    );
    if (_frame != null)
      PaintingBinding.instance.imageCache.evict(MemoryImage(_frame!));
    _frame = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(l10n.scanQrCode),
    content: SizedBox(
      width: 480,
      height: 360,
      child: _error != null
          ? Center(child: Text(_error!))
          : _frame == null
          ? const Center(child: CircularProgressIndicator())
          : Image.memory(
              _frame!,
              gaplessPlayback: true,
              fit: BoxFit.contain,
              semanticLabel: l10n.liveCameraPreview,
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.cancel),
      ),
    ],
  );
}
