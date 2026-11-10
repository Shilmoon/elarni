import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The time this machine was awake. Dart's Stopwatch and timers on Windows run
/// on QueryPerformanceCounter, which counts sleep and hibernation, so a timeout
/// that straddles a sleep runs out at resume; the unbiased interrupt time leaves
/// both out. CLOCK_MONOTONIC, which Dart uses on Linux, already stops while
/// suspended.
Duration awakeNow() => _awakeNow();

final Duration Function() _awakeNow = Platform.isWindows
    ? _unbiasedInterruptTime()
    : _sinceStart;

final _start = Stopwatch()..start();

Duration _sinceStart() => _start.elapsed;

Duration Function() _unbiasedInterruptTime() {
  final query = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(Pointer<Uint64>),
        int Function(Pointer<Uint64>)
      >('QueryUnbiasedInterruptTime');
  final value = calloc<Uint64>(); // Kept for the process's lifetime.
  return () => query(value) == 0
      ? _start.elapsed
      : Duration(microseconds: value.value ~/ 10); // 100 ns units
}

/// [future] with a [limit] of awake time: a timer that ends early, at resume,
/// is followed by one for the awake time still missing.
Future<T> awakeTimeout<T>(
  Future<T> future,
  Duration limit, {
  Duration Function() clock = awakeNow,
  Timer Function(Duration, void Function()) timer = Timer.new,
}) {
  final result = Completer<T>();
  final deadline = clock() + limit;
  Timer? pending;
  void arm(Duration left) {
    pending = timer(left, () {
      final rest = deadline - clock();
      if (rest > Duration.zero) return arm(rest);
      if (!result.isCompleted)
        result.completeError(TimeoutException(null, limit));
    });
  }

  arm(limit);
  future.then<void>(
    (value) {
      pending?.cancel();
      if (!result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stack) {
      pending?.cancel();
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  return result.future;
}
