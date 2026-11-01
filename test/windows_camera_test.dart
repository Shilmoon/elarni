import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:elarni/desktop_camera.dart';

void main() {
  for (final linux in [false, true]) {
    testWidgets(
      '${linux ? 'Linux' : 'Windows'} preview keeps updating while one slow QR decode is pending',
      (tester) async {
        final channel = MethodChannel(
          linux ? 'com.elarni/linux' : 'com.elarni/windows',
        );
        final navigator = GlobalKey<NavigatorState>();
        final camera = DesktopCamera(navigator, linux: linux);
        final bytes = File('test/windows_profile_qr.png').readAsBytesSync();
        final decode = Completer<String>();
        var frames = 0, decodes = 0, stopped = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'cameraStop') {
                stopped++;
                return null;
              }
              frames++;
              return frames == 1 ? null : Uint8List.fromList(bytes);
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Home')),
          ),
        );
        final cancelled = expectLater(
          camera.scan((_) {
            decodes++;
            return decode.future;
          }),
          throwsA(isA<PlatformException>()),
        );
        await tester.pump();
        for (var frame = 0; frame < 35; frame++) {
          await tester.pump(const Duration(milliseconds: 33));
        }
        expect(frames, greaterThanOrEqualTo(25));
        expect(decodes, 1);
        expect(find.bySemanticsLabel('Live camera preview'), findsOneWidget);
        expect(stopped, 0);
        camera.cancel();
        await tester.pumpAndSettle();
        await cancelled;
        decode.complete('late-result');
        await tester.pumpAndSettle();
        expect(stopped, 1);
        expect(find.text('Home'), findsOneWidget);
      },
    );
    testWidgets(
      '${linux ? 'Linux' : 'Windows'} camera waits for previous capture, imports and ignores cancelled late frames',
      (tester) async {
        final channel = MethodChannel(
          linux ? 'com.elarni/linux' : 'com.elarni/windows',
        );
        final navigator = GlobalKey<NavigatorState>();
        final camera = DesktopCamera(navigator, linux: linux);
        final bytes = File('test/windows_profile_qr.png').readAsBytesSync();
        Completer<Uint8List>? pending;
        var stopped = 0, decoded = 0, busy = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'cameraStop') {
                stopped++;
                return null;
              }
              expect(call.method, 'cameraFrame');
              if (busy) {
                busy = false;
                throw PlatformException(code: 'busy');
              }
              return pending == null ? bytes : pending.future;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Home')),
          ),
        );
        final success = camera.scan((frame) async {
          expect(frame, bytes);
          decoded++;
          return 'synthetic-link';
        });
        await tester.pumpAndSettle();
        expect(await success, 'synthetic-link');
        expect(stopped, 1);
        pending = Completer<Uint8List>();
        final cancelled = expectLater(
          camera.scan((_) async {
            decoded++;
            return 'late';
          }),
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Cancel'));
        camera.cancel();
        await tester.pumpAndSettle();
        await cancelled;
        pending.complete(bytes);
        await tester.pumpAndSettle();
        expect(stopped, 2);
        expect(decoded, 1);
        expect(find.text('Home'), findsOneWidget);
      },
    );
  }
}
