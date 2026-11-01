import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'elarni_app.dart';
import 'desktop_proxy.dart';
import 'desktop_camera.dart';
import 'headless.dart';
import 'strings.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final headless = Platform.environment['ELARNI_HEADLESS'] == '1';
  if (!headless)
    SystemChrome.setApplicationSwitcherDescription(
      const ApplicationSwitcherDescription(label: 'Elarni'),
    );
  final navigator = GlobalKey<NavigatorState>();
  final camera = DesktopCamera(navigator, linux: Platform.isLinux);
  final desktop = Platform.isWindows || Platform.isLinux
      ? DesktopProxy(
          unattended: headless,
          cameraScan: camera.scan,
          cancelCamera: camera.cancel,
          confirmLink: headless
              ? null
              : (prompt) => _confirmLink(navigator, prompt),
          corePath: File(Platform.resolvedExecutable).parent.uri
              .resolve(Platform.isLinux ? 'elarni-core' : 'elarni-core.exe')
              .toFilePath(),
          domainPath: File(Platform.resolvedExecutable).parent.uri
              .resolve(
                Platform.isLinux
                    ? 'lib/libelarni_domain.so'
                    : 'elarni_domain.dll',
              )
              .toFilePath(),
        )
      : null;
  final done = Completer<void>();
  // Binding runs a Windows ACL check that can take seconds; the GUI starts first.
  // Future.sync also routes a missing HOME or LOCALAPPDATA to the handler below.
  final control =
      Future.sync(
        () => HeadlessServer.bind(
          headlessSocketPath,
          HeadlessControl(
            desktop != null
                ? desktop.request
                : (method, args) async =>
                      await const MethodChannel(
                        'com.elarni/tunnel',
                      ).invokeMapMethod<String, Object?>(method, args) ??
                      {},
            unattended: headless && desktop != null,
          ).request,
          onShutdown: headless
              ? () {
                  if (!done.isCompleted) done.complete();
                }
              : null,
        ),
      ).then<HeadlessServer?>(
        (server) => server,
        onError: (Object _) {
          // A control endpoint failure must not prevent ordinary GUI startup.
          stderr.writeln('Elarni local control unavailable.');
          return null;
        },
      );
  if (headless) {
    final server = await control;
    try {
      if (server == null) throw StateError('control_unavailable');
      if (desktop != null) {
        await desktop.request('state');
      } else {
        await const MethodChannel(
          'com.elarni/tunnel',
        ).invokeMethod<Object?>('state');
      }
    } on Object {
      if (server != null) stderr.writeln('Elarni local control unavailable.');
      try {
        await server?.close();
      } finally {
        await desktop?.dispose();
        exit(1);
      }
    }
    final signals = [
      for (final signal in [
        ProcessSignal.sigint,
        if (!Platform.isWindows) ProcessSignal.sigterm,
      ])
        signal.watch().listen((_) {
          if (!done.isCompleted) done.complete();
        }),
    ];
    stderr.writeln('Elarni headless control ready.');
    await done.future;
    try {
      await server.close();
    } on Object {
      // A leftover endpoint file must not keep the VPN up.
      exitCode = 1;
    }
    if (desktop != null) {
      await desktop.dispose();
    } else {
      try {
        await const MethodChannel(
          'com.elarni/tunnel',
        ).invokeMethod<void>('disconnect');
      } catch (_) {
        stderr.writeln('Elarni disconnect failed.');
        exitCode = 1;
      }
    }
    for (final signal in signals) {
      await signal.cancel();
    }
    exit(exitCode);
  }
  runApp(
    ElarniApp(
      tunnelControl: desktop?.control,
      navigatorKey: navigator,
      windows: Platform.isWindows,
      linux: Platform.isLinux,
      onDispose: () async {
        try {
          await (await control)?.close();
        } finally {
          await desktop?.dispose();
        }
      },
    ),
  );
  if (desktop != null) unawaited(desktop.handleLinks(arguments));
}

Future<bool> _confirmLink(
  GlobalKey<NavigatorState> navigator,
  String prompt,
) async {
  final (message, action) = switch (prompt) {
    'disconnect' => (l10n.linkAsksDisconnect, l10n.disconnect),
    'importRouting' => (l10n.linkImportsRoutingProfile, l10n.importAction),
    _ => (l10n.linkImportsClientProfile, l10n.importAction),
  };
  // Links passed at launch arrive before the first frame builds the navigator.
  while (navigator.currentContext == null) {
    await WidgetsBinding.instance.endOfFrame;
  }
  return await showDialog<bool>(
        context: navigator.currentContext!,
        builder: (context) => AlertDialog(
          title: Text(l10n.openElarniLink),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;
}
