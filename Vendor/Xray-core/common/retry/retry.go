package retry // import "github.com/xtls/xray-core/common/retry"

import (
	"context"
	goerrors "errors"
	"net"
	"syscall"
	"time"

	"github.com/xtls/xray-core/common/errors"
)

var ErrRetryFailed = errors.New("all retry attempts failed")

// Strategy is a way to retry on a specific function.
type Strategy interface {
	// On performs a retry on a specific function, until it doesn't return any error.
	On(func() error) error
	// OnContext is On for a dial: it gives up once ctx ends or an attempt fails in a way
	// another attempt cannot fix (see Again), and does not sleep after the last attempt.
	OnContext(ctx context.Context, method func() error) error
}

type retryer struct {
	totalAttempt int
	nextDelay    func() uint32
}

// On implements Strategy.On.
func (r *retryer) On(method func() error) error {
	attempt := 0
	accumulatedError := make([]error, 0, r.totalAttempt)
	for attempt < r.totalAttempt {
		err := method()
		if err == nil {
			return nil
		}
		numErrors := len(accumulatedError)
		if numErrors == 0 || err.Error() != accumulatedError[numErrors-1].Error() {
			accumulatedError = append(accumulatedError, err)
		}
		delay := r.nextDelay()
		time.Sleep(time.Duration(delay) * time.Millisecond)
		attempt++
	}
	return errors.New(accumulatedError).Base(ErrRetryFailed)
}

// OnContext implements Strategy.OnContext.
// Elarni: a blackholed server cost 5 x 16 s per flow, and a refused port 1 s of sleeps.
func (r *retryer) OnContext(ctx context.Context, method func() error) error {
	accumulatedError := make([]error, 0, r.totalAttempt)
	for attempt := 1; ; attempt++ {
		err := method()
		if err == nil {
			return nil
		}
		numErrors := len(accumulatedError)
		if numErrors == 0 || err.Error() != accumulatedError[numErrors-1].Error() {
			accumulatedError = append(accumulatedError, err)
		}
		if attempt >= r.totalAttempt || ctx.Err() != nil || futile(err) {
			break
		}
		timer := time.NewTimer(time.Duration(r.nextDelay()) * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return errors.New(accumulatedError).Base(ErrRetryFailed)
		case <-timer.C:
		}
	}
	return errors.New(accumulatedError).Base(ErrRetryFailed)
}

type again struct{ error }

func (a again) Unwrap() error { return a.error }

// Again marks err as worth another attempt although it looks futile, for a method whose
// next attempt changes what it does (another address, a fresh DNS lookup).
func Again(err error) error {
	return again{err}
}

// futile reports whether repeating the attempt cannot help: it timed out (each try
// already waited its full budget) or the port refused the connection.
func futile(err error) bool {
	if goerrors.As(err, new(again)) {
		return false
	}
	var netErr net.Error
	if goerrors.As(err, &netErr) && netErr.Timeout() {
		return true
	}
	// 10061 is WSAECONNREFUSED: Windows connect errors never match syscall.ECONNREFUSED.
	return goerrors.Is(err, syscall.ECONNREFUSED) || goerrors.Is(err, syscall.Errno(10061))
}

// Timed returns a retry strategy with fixed interval.
func Timed(attempts int, delay uint32) Strategy {
	return &retryer{
		totalAttempt: attempts,
		nextDelay: func() uint32 {
			return delay
		},
	}
}

func ExponentialBackoff(attempts int, delay uint32) Strategy {
	nextDelay := uint32(0)
	return &retryer{
		totalAttempt: attempts,
		nextDelay: func() uint32 {
			r := nextDelay
			nextDelay += delay
			return r
		},
	}
}
