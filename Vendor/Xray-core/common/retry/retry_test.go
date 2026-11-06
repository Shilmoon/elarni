package retry_test

import (
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/retry"
)

func refusedDialError(t *testing.T) error {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	conn, err := net.Dial("tcp", address)
	if err == nil {
		conn.Close()
		t.Skip("a closed loopback port accepted a connection")
	}
	return err
}

// A dial that timed out or was refused fails the same way again; anything else may not.
func TestOnContextRetriesOnlyErrorsAnotherAttemptCanFix(t *testing.T) {
	refused := refusedDialError(t)
	for _, test := range []struct {
		name     string
		err      error
		attempts int
	}{
		{"refused", refused, 1},
		{"handshake deadline", context.DeadlineExceeded, 1},
		{"connect timeout", &net.OpError{Op: "dial", Net: "tcp", Err: &timeoutError{}}, 1},
		{"reset", io.ErrUnexpectedEOF, 5},
		{"marked again", retry.Again(context.DeadlineExceeded), 5},
	} {
		t.Run(test.name, func(t *testing.T) {
			attempts := 0
			err := retry.ExponentialBackoff(5, 1).OnContext(context.Background(), func() error {
				attempts++
				return test.err
			})
			if !errors.Is(err, retry.ErrRetryFailed) {
				t.Fatalf("err %v, want ErrRetryFailed", err)
			}
			if attempts != test.attempts {
				t.Fatalf("%d attempts, want %d", attempts, test.attempts)
			}
		})
	}
}

// A flow whose app or core went away must not keep dialing or sleeping.
func TestOnContextStopsWhenTheContextEnds(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	attempts := 0
	err := retry.ExponentialBackoff(5, 1000).OnContext(ctx, func() error {
		attempts++
		cancel()
		return io.ErrUnexpectedEOF
	})
	if err == nil || attempts != 1 {
		t.Fatalf("err %v after %d attempts, want a failure after 1", err, attempts)
	}

	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	time.AfterFunc(50*time.Millisecond, cancel)
	started := time.Now()
	attempts = 0
	// The second delay is 1 s: a sleep that ignores ctx would hold the flow that long.
	err = retry.ExponentialBackoff(5, 1000).OnContext(ctx, func() error {
		attempts++
		return io.ErrUnexpectedEOF
	})
	if err == nil || attempts != 2 {
		t.Fatalf("err %v after %d attempts, want a failure after 2", err, attempts)
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("returned %v after the context ended", elapsed)
	}
}

// Nothing follows the last attempt, so its delay only postponed the failure.
func TestOnContextDoesNotSleepAfterTheLastAttempt(t *testing.T) {
	started := time.Now()
	attempts := 0
	err := retry.Timed(2, 400).OnContext(context.Background(), func() error {
		attempts++
		return io.ErrUnexpectedEOF
	})
	if err == nil || attempts != 2 {
		t.Fatalf("err %v after %d attempts, want a failure after 2", err, attempts)
	}
	if elapsed := time.Since(started); elapsed < 400*time.Millisecond || elapsed > 700*time.Millisecond {
		t.Fatalf("took %v, want one 400 ms delay", elapsed)
	}
}

type timeoutError struct{}

func (*timeoutError) Error() string   { return "i/o timeout" }
func (*timeoutError) Timeout() bool   { return true }
func (*timeoutError) Temporary() bool { return true }
