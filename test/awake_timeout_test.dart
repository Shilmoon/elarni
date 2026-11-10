import 'dart:async';

import 'package:elarni/awake_timeout.dart';
import 'package:flutter_test/flutter_test.dart';

/// Timers that end when the test says, with an awake clock the test moves.
class _FakeAwake {
  Duration now = Duration.zero;
  final requested = <Duration>[];
  final _pending = <_FakeTimer>[];

  Duration clock() => now;

  Timer timer(Duration duration, void Function() callback) {
    requested.add(duration);
    final timer = _FakeTimer(callback);
    _pending.add(timer);
    return timer;
  }

  /// Ends the latest timer after [awake] of awake time.
  void fire(Duration awake) {
    now += awake;
    final timer = _pending.removeLast();
    if (timer.isActive) timer.run();
  }

  bool get armed => _pending.any((timer) => timer.isActive);
}

class _FakeTimer implements Timer {
  _FakeTimer(this._callback);
  final void Function() _callback;
  bool _active = true;

  void run() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}

void main() {
  const limit = Duration(seconds: 120);

  test(
    'a reply before the limit is returned and its timer cancelled',
    () async {
      final fake = _FakeAwake();
      final reply = Completer<String>();
      final result = awakeTimeout(
        reply.future,
        limit,
        clock: fake.clock,
        timer: fake.timer,
      );
      reply.complete('ready');
      expect(await result, 'ready');
      expect(fake.armed, isFalse);
    },
  );

  test('a limit without sleep times out after one timer', () async {
    final fake = _FakeAwake();
    final result = awakeTimeout(
      Completer<String>().future,
      limit,
      clock: fake.clock,
      timer: fake.timer,
    );
    fake.fire(limit);
    await expectLater(result, throwsA(isA<TimeoutException>()));
    expect(fake.requested, [limit]);
  });

  test('a timer that ends at resume waits for the awake time left', () async {
    // Windows ends the 120 s timer at resume from a 12 h sleep that began 5 s
    // into the connect; the helper's reply comes 5 s after resume.
    final fake = _FakeAwake();
    final reply = Completer<String>();
    final result = awakeTimeout(
      reply.future,
      limit,
      clock: fake.clock,
      timer: fake.timer,
    );
    fake.fire(const Duration(seconds: 5));
    expect(fake.requested, [limit, const Duration(seconds: 115)]);
    expect(fake.armed, isTrue);
    fake.now += const Duration(seconds: 5);
    reply.complete('ready');
    expect(await result, 'ready');
    expect(fake.armed, isFalse);
  });

  test('awake time over several sleeps still ends at the limit', () async {
    final fake = _FakeAwake();
    final result = awakeTimeout(
      Completer<String>().future,
      limit,
      clock: fake.clock,
      timer: fake.timer,
    );
    fake.fire(const Duration(seconds: 20));
    fake.fire(Duration.zero);
    fake.fire(const Duration(seconds: 100));
    await expectLater(result, throwsA(isA<TimeoutException>()));
    expect(fake.requested, [
      limit,
      const Duration(seconds: 100),
      const Duration(seconds: 100),
    ]);
  });

  test('an error before the limit is passed on', () async {
    final fake = _FakeAwake();
    final reply = Completer<String>();
    final result = awakeTimeout(
      reply.future,
      limit,
      clock: fake.clock,
      timer: fake.timer,
    );
    reply.completeError(StateError('helper exited'));
    await expectLater(result, throwsA(isA<StateError>()));
    expect(fake.armed, isFalse);
  });

  test('the platform clock moves with time while awake', () async {
    final before = awakeNow(), watch = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final moved = awakeNow() - before;
    // The Windows unbiased interrupt time ticks about every 16 ms.
    expect(
      (moved - watch.elapsed).inMilliseconds.abs(),
      lessThan(50),
      reason: 'moved $moved in ${watch.elapsed}',
    );
  });
}
