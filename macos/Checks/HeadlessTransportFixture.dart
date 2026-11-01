import 'dart:async';
import 'dart:io';

import '../../lib/headless_transport.dart';

// Runs the production transport under App Sandbox, without a VPN controller.
Future<void> main(List<String> args) async {
  final done = Completer<void>();
  final server = await HeadlessServer.bind(
    args.single,
    (input) async => {'fixture': true},
    onShutdown: done.complete,
  );
  stdout.writeln('READY');
  await done.future;
  await server.close();
}
